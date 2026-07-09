;;; gptel-org.el --- Org functions for gptel         -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026  Karthik Chikmagalur

;; Author: Karthik Chikmagalur <karthikchikmagalur@gmail.com>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:
(require 'cl-lib)
(require 'org-element)
(require 'outline)
(require 'mailcap)                    ;FIXME Avoid this somehow
(eval-when-compile (require 'gptel-request))

;; Functions used for saving/restoring gptel state in Org buffers
(defvar gptel--num-messages-to-send)
(defvar org-entry-property-inherited-from)
(defvar gptel-backend)
(defvar gptel--known-backends)
(defvar gptel-system-prompt)
(defvar gptel-model)
(defvar gptel-temperature)
(defvar gptel-max-tokens)
(defvar gptel--link-type-cache)
(defvar gptel--preset)

(defvar org-link-angle-re)
(defvar org-link-bracket-re)
(declare-function mailcap-file-name-to-mime-type "mailcap")
(declare-function gptel--model-capable-p "gptel-request")
(declare-function gptel--model-mime-capable-p "gptel-request")
(declare-function gptel--model-name "gptel-request")
(declare-function gptel--to-string "gptel-request")
(declare-function gptel--to-number "gptel-request")
(declare-function gptel--intern "gptel-request")
(declare-function gptel-backend-name "gptel-request")
(declare-function gptel--parse-buffer "gptel-request")
(declare-function gptel--parse-directive "gptel-request")
(declare-function gptel--log "gptel-request")
(declare-function gptel--with-buffer-copy "gptel-request")
(declare-function gptel--file-binary-p "gptel-request")
(declare-function gptel--get-buffer-bounds "gptel")
(declare-function gptel--restore-props "gptel")
(declare-function gptel--suffix-rewrite "gptel-rewrite")
(defvar gptel--rewrite-directive)
(defvar gptel-org--rewrite-merged-system nil
  "Merged system message for the current `gptel--suffix-rewrite' request.")
(defvar gptel-org--in-rewrite nil
  "Non-nil while a `gptel--suffix-rewrite' request is being assembled.
Tells `gptel-org--request-with-system-section' to leave the explicit rewrite
directive untouched instead of reapplying the buffer system section.")
(declare-function org-entry-get "org")
(declare-function org-entry-put "org")
(declare-function org-with-wide-buffer "org-macs")
(declare-function org-set-property "org")
(declare-function org-property-values "org")
(declare-function org-open-line "org")
(declare-function org-at-heading-p "org")
(declare-function org-get-heading "org")
(declare-function org-at-heading-p "org")
(declare-function org-map-entries "org")
(declare-function org-back-to-heading "org")
(declare-function org-end-of-subtree "org")
(declare-function org-element-at-point "org-element")
(declare-function org-element-property "org-element")

;; Bundle `org-element-lineage-map' if it's not available (for Org 9.67 or older)
(eval-and-compile
  (if (fboundp 'org-element-lineage-map)
      (progn (declare-function org-element-lineage-map "org-element-ast")
             (defalias 'gptel-org--element-lineage-map 'org-element-lineage-map))
    (defun gptel-org--element-lineage-map (datum fun &optional types with-self first-match)
      "Map FUN across ancestors of DATUM, from closest to furthest.

DATUM is an object or element.  For TYPES, WITH-SELF and
FIRST-MATCH see `org-element-lineage-map'.

This function is provided for compatibility with older versions
of Org."
      (declare (indent 2))
      (setq fun (if (functionp fun) fun `(lambda (node) ,fun)))
      (let ((up (if with-self datum (org-element-parent datum)))
	    acc rtn)
        (catch :--first-match
          (while up
            (when (or (not types) (org-element-type-p up types))
              (setq rtn (funcall fun up))
              (if (and first-match rtn)
                  (throw :--first-match rtn)
                (when rtn (push rtn acc))))
            (setq up (org-element-parent up)))
          (nreverse acc)))))
  (if (fboundp 'org-element-begin)
      (progn (declare-function org-element-begin "org-element")
             (declare-function org-element-end "org-element")
             (declare-function org-element-parent "org-element")
             (defalias 'gptel-org--element-begin 'org-element-begin)
             (defalias 'gptel-org--element-end 'org-element-end)
             (defalias 'gptel-org--element-parent 'org-element-parent))
    (defsubst gptel-org--element-begin (node)
      "Get `:begin' property of NODE."
      (org-element-property :begin node))
    (defsubst gptel-org--element-end (node)
      "Get `:end' property of NODE."
      (org-element-property :end node))
    (defsubst gptel-org--element-parent (node)
      "Return `:parent' property of NODE."
      (org-element-property :parent node))))


;;; User options
(defcustom gptel-org-branching-context nil
  "Use the lineage of the current heading as the context for gptel in Org buffers.

This makes each same level heading a separate conversation
branch.

By default, gptel uses a linear context: all the text up to the
cursor is sent to the LLM.  Enabling this option makes the
context the hierarchical lineage of the current Org heading.  In
this example:

-----
Top level text

* Heading 1
heading 1 text

* Heading 2
heading 2 text

** Heading 2.1
heading 2.1 text
** Heading 2.2
heading 2.2 text
-----

With the cursor at the end of the buffer, the text sent to the
LLM will be limited to

-----
Top level text

* Heading 2
heading 2 text

** Heading 2.2
heading 2.2 text
-----

This makes it feasible to have multiple conversation branches."
  :type 'boolean
  :group 'gptel)

(defcustom gptel-org-ignore-elements '(property-drawer)
  "Types of Org elements to be stripped from the prompt before sending.

By default gptel will remove Org property drawers from the
prompt.  For the full list of available elements, please see
`org-element-all-elements'.

Please note: Removing property-drawer elements is fast, but
adding elements to this list can significantly slow down
`gptel-send'."
  :group 'gptel
  :type '(repeat symbol))

(defcustom gptel-org-validate-link #'always
  "Validate links to be sent as context with gptel queries.

When `gptel-track-media' is enabled, this option determines if a
supported link will be followed and its source included with gptel
queries from Org buffers.  Currently only \"file\" and \"attachment\"
link types are supported (along with web URLs if the model supports
them).

It should be a function that accepts an Org link object and return
non-nil if the link should be followed.

By default, all links are considered valid.

Set this to `gptel-org--link-standalone-p' to only follow links placed
on a line by themselves, separated from surrounding text."
  :group 'gptel
  :type '(choice
          (const :tag "All links" always)
          (const :tag "Standalone links" gptel-org--link-standalone-p)
          (function :tag "Function")))

(defconst gptel-org--link-regex
  (concat "\\(?:" org-link-bracket-re "\\|" org-link-angle-re "\\)")
  "Link regex for `gptel-mode' in Org mode.")

(defcustom gptel-org-use-system-section t
  "When non-nil, use a delimited system-message section in the buffer.

The section is found by plain-text search for begin/end marker lines, not Org
structure; see `gptel-org-system-section-property' and
`gptel-org-system-section-end-property'."
  :group 'gptel
  :type 'boolean)

(defcustom gptel-org-system-section-property "GPTEL_SYSTEM_MESSAGE_BEGIN"
  "Marker name for the start of the system-message section.

Matched at line beginning as an Org property (`:NAME:') or after a comment
prefix (`#', `;', `;;', `%'); see `gptel-org--system-section-marker-regexp'."
  :group 'gptel
  :type 'string)

(defcustom gptel-org-system-section-end-property "GPTEL_SYSTEM_MESSAGE_END"
  "Marker name for the end of the system-message section.

Same line syntax as `gptel-org-system-section-property'.  Text between the
begin and end marker lines is the system message; the marker lines themselves
are excluded."
  :group 'gptel
  :type 'string)

(defcustom gptel-org-require-system-section-at-eof t
  "When non-nil, ignore a system section with non-whitespace after the end marker.

Only lines after the end marker line up to `point-max' may be whitespace.
This keeps the section at the file end without relying on Org structure."
  :group 'gptel
  :type 'boolean)


;;; Buffer system-message section (plain-text begin/end markers; see defcustoms above)

(defun gptel-org--system-section-at-file-end-p (pos)
  "Non-nil if POS is followed only by whitespace or a `Local Variables' trailer."
  (save-excursion
    (goto-char pos)
    (skip-chars-forward " \t\n\r")
    (cond
     ((= (point) (point-max)) t)
     ((looking-at-p ";;\\s-*Local Variables:")
      (goto-char (point-max))
      (when (re-search-backward "^;; End:" nil t)
        (goto-char (match-end 0))
        (skip-chars-forward " \t\n\r")
        (= (point) (point-max))))
     (t nil))))

(defvar-local gptel-org--system-section-cache nil
  "Cache for `gptel-org--system-section-bounds': (BOUNDS MODIFIED-TICK).")

(defconst gptel-org--system-section-marker-line-fmt
  "^\\(?:\\(?:;;\\|[:;#%%]\\)\\s-*%s\\b\\|:%s:\\s-*\\)"
  "Line template for `gptel-org--system-section-marker-regexp'.
Org :MARKER: or comment prefix (# ; ;; %).  Plain-text only.")

(defun gptel-org--system-section-marker-regexp (marker)
  "Return a regexp for a line marking MARKER.
See `gptel-org--system-section-marker-line-fmt'."
  (let ((q (regexp-quote marker)))
    (format gptel-org--system-section-marker-line-fmt q q)))

(defun gptel-org--system-section-line-end (pos)
  "Return position after the line starting at POS."
  (save-excursion (goto-char pos) (end-of-line 1) (point)))

(defun gptel-org--system-section-search-marker (marker &optional limit)
  "Search backward from point for MARKER line; return match-beginning or nil."
  (when (re-search-backward (gptel-org--system-section-marker-regexp marker)
                            limit t)
    (match-beginning 0)))

(defun gptel-org--system-section-warn-ignore (message)
  "Display MESSAGE as gptel warning and return nil."
  (progn (display-warning 'gptel message :warning) nil))

(defun gptel-org--system-section-content-bounds (section-bounds)
  "Return (TEXT-BEG . TEXT-END) between marker lines in SECTION-BOUNDS."
  (cons (gptel-org--system-section-line-end (car section-bounds))
        (save-excursion
          (goto-char (cdr section-bounds))
          (beginning-of-line 1)
          (point))))

(defun gptel-org--point-in-system-section-p (pos bounds)
  "Non-nil if POS lies inside system section BOUNDS (marker lines included)."
  (and bounds (>= pos (car bounds)) (< pos (cdr bounds))))

(defun gptel-org--system-section-bounds--find ()
  "Find (BEG . END) of the last begin/end marker pair; END is end of end line."
  (save-excursion
    (save-restriction (widen)
      (goto-char (point-max))
      (when-let* ((end-beg (gptel-org--system-section-search-marker
                            gptel-org-system-section-end-property))
                  (end-end (gptel-org--system-section-line-end end-beg))
                  (_ (or (not gptel-org-require-system-section-at-eof)
                         (gptel-org--system-section-at-file-end-p end-end)
                         (gptel-org--system-section-warn-ignore
                          "System-message section has text after the end marker; ignoring")))
                  (beg-beg (progn (goto-char end-beg)
                                  (gptel-org--system-section-search-marker
                                   gptel-org-system-section-property))))
        (if (>= beg-beg end-beg)
            (gptel-org--system-section-warn-ignore
             "System-message begin marker is not before end marker; ignoring")
          (cons beg-beg end-end))))))

(defun gptel-org--system-section-bounds ()
  "Return (BEG . END) of the buffer system-message section, or nil.

Searches backward from `point-max' for the last end marker, then the last begin
marker before it.  Results are cached until the buffer is modified."
  (when gptel-org-use-system-section
    (let ((tick (buffer-modified-tick)))
      (if (and gptel-org--system-section-cache
               (eq (cadr gptel-org--system-section-cache) tick))
          (car gptel-org--system-section-cache)
        (let ((bounds (gptel-org--system-section-bounds--find)))
          (setq gptel-org--system-section-cache (list bounds tick))
          bounds)))))

(defun gptel-org--system-section-message (&optional bounds)
  "Return the system-message text for system section BOUNDS."
  (setq bounds (or bounds (gptel-org--system-section-bounds)))
  (when bounds
    (pcase-let ((`(,text-beg . ,text-end)
                 (gptel-org--system-section-content-bounds bounds))
                (org-buf (current-buffer)))
      ;; `gptel--with-buffer-copy' creates a temp buffer but never kills it --
      ;; request code paths reuse and kill it later.  Here we only need the
      ;; text, so kill the copy ourselves.  Otherwise a pseudo `org-mode'
      ;; buffer (major-mode set, no keymap installed) leaks on every section
      ;; parse and later trips `org-install-agenda-files-menu', which signals
      ;; "(wrong-type-argument keymapp nil)" when the next Org file is opened.
      (let ((copy (gptel--with-buffer-copy org-buf text-beg text-end
                    (when-let* ((gptel-org-ignore-elements
                                 (buffer-local-value 'gptel-org-ignore-elements org-buf)))
                      (gptel-org--strip-elements))
                    (gptel-org--strip-block-headers)
                    (current-buffer))))
        (unwind-protect
            (with-current-buffer copy (string-trim (buffer-string)))
          (when (buffer-live-p copy) (kill-buffer copy)))))))

(defun gptel-org--bounds-overlap-p (a-beg a-end b-beg b-end)
  "Non-nil if ranges [A-BEG,A-END) and [B-BEG,B-END) overlap."
  (and (< a-beg b-end) (> a-end b-beg)))

(defun gptel-org--rewrite-target-bounds ()
  "Return (BEG . END) for the text `gptel--suffix-rewrite' will rewrite.

When continuing an existing rewrite, use the rewrite overlay bounds and
ignore any unrelated active region (e.g. from Isearch)."
  (if-let* ((ov (cdr-safe (get-char-property-and-overlay (point) 'gptel-rewrite))))
      (cons (overlay-start ov) (overlay-end ov))
    (when (use-region-p)
      (let ((rb (region-beginning))
            (re (region-end)))
        (when (< rb re)
          (cons rb re))))))

(defun gptel-org--use-section-system-message (text)
  "Set `gptel-system-prompt' to section TEXT, log it, and return t."
  (setq gptel-system-prompt text)
  (message "gptel: System message from buffer section (%d chars)" (length text))
  (when gptel-log-level
    (gptel--log (format "System message from buffer section in %s:\n%s"
                        (buffer-name (current-buffer)) text)
                "system-section" t))
  t)

(defun gptel-org--apply-buffer-system-message ()
  "If this buffer has a system-message section, set `gptel-system-prompt'.

Signal an error if point is inside the section.  Overlap with a rewrite
region is handled separately in `gptel-org--rewrite-request-system'; for
`gptel-send' the prompt end is capped in
`gptel-org--cap-prompt-end-for-system-section'.  Return t when the section
was used, nil otherwise."
  (when-let* ((bounds (gptel-org--system-section-bounds)))
    (if (gptel-org--point-in-system-section-p (point) bounds)
        (user-error
         "Cursor is inside the system-message section; move above it")
      (gptel-org--use-section-system-message
       (gptel-org--system-section-message bounds)))))

(defun gptel-org--system-section-message-for-send ()
  "Return the buffer system-message section text when one is defined.

Signal an error if point is inside the section.  For use in tests."
  (when (gptel-org--apply-buffer-system-message)
    gptel-system-prompt))

(defun gptel-org--cap-prompt-end-for-system-section (prompt-end)
  "Adjust PROMPT-END so a trailing system-message section is not sent."
  (when-let* ((bounds (gptel-org--system-section-bounds)))
    (when (use-region-p)
      (unless (or (>= (region-beginning) (cdr bounds))
                  (<= (region-end) (car bounds)))
        (user-error "Region overlaps system-message section")))
    (let ((pt (or prompt-end (point))))
      (when (gptel-org--point-in-system-section-p pt bounds)
        (user-error
         "Cursor is inside the system-message section; move above it"))
      (when (< pt (car bounds))
        (setq prompt-end (min pt (car bounds))))))
  prompt-end)


;;; Setting context and creating queries

(defun gptel-org--get-topic-start ()
  "If a conversation topic is set, return it."
  (when (org-entry-get (point) "GPTEL_TOPIC" 'inherit)
    (marker-position org-entry-property-inherited-from)))

(defun gptel-org-set-topic (topic)
  "Set a TOPIC and limit this conversation to the current heading.

This limits the context sent to the LLM to the text between the current
heading (i.e. the heading with the topic set) and the cursor position."
  (interactive
   (list
    (progn
      (or (derived-mode-p 'org-mode)
          (user-error "Support for multiple topics per buffer is only implemented for `org-mode'"))
      (completing-read "Set topic as: "
                       (org-property-values "GPTEL_TOPIC")
                       nil nil (downcase
                                (truncate-string-to-width
                                 (substring-no-properties
                                  (replace-regexp-in-string
                                   "\\s-+" "-"
                                   (org-entry-get nil "ITEM")))
                                 50))))))
  (when (stringp topic) (org-set-property "GPTEL_TOPIC" topic)))

;; NOTE: This can be converted to a cl-defmethod for
;; `gptel--create-prompt-buffer' (conceptually cleaner), but will cause
;; load-order issues in gptel.el and might be harder to debug.
(defun gptel-org--create-prompt-buffer (&optional prompt-end)
  "Return a buffer with the conversation prompt to be sent.

If the region is active limit the prompt text to the region contents.
Otherwise the prompt text is constructed from the contents of the
current buffer up to point, or PROMPT-END if provided.  Its contents
depend on the value of `gptel-org-branching-context', which see."
  (when (use-region-p)
    (narrow-to-region (region-beginning) (region-end))
    (setq prompt-end (point-max)))
  (setq prompt-end (gptel-org--cap-prompt-end-for-system-section prompt-end))
  (goto-char (or prompt-end (setq prompt-end (point))))
  (let ((topic-start (gptel-org--get-topic-start)))
    (when topic-start
      ;; narrow to GPTEL_TOPIC property scope
      (narrow-to-region topic-start prompt-end))
    (if (and gptel-org-branching-context
             (or (fboundp 'org-element-lineage-map)
                 (prog1 nil
                   (display-warning
                    '(gptel org)
                    "Using `gptel-org-branching-context' requires Org version 9.7 or higher, it will be ignored."))))
        ;; Create prompt from direct ancestors of point
        (save-excursion
          (let* ((org-buf (current-buffer))
                 ;; Collect all heading start positions in the lineage
                 (full-bounds (gptel-org--element-lineage-map
                                  (org-element-at-point) #'gptel-org--element-begin
                                '(headline) 'with-self) )
                 ;; lineage-map returns the full lineage in the unnarrowed
                 ;; buffer.  Remove heading start positions before (point-min)
                 ;; that are invalid due to narrowing, and add (point-min) if
                 ;; it's not already included in the lineage
                 (start-bounds
                  (nconc (cl-delete-if (lambda (p) (< p (point-min)))
                                       full-bounds)
                         (unless (save-excursion (goto-char (point-min))
                                                 (looking-at-p outline-regexp))
                           (list (point-min)))))
                 (end-bounds
                  (cl-loop
                   ;; (car start-bounds) is the begining of the current element,
                   ;; not relevant
                   for pos in (cdr start-bounds)
                   do (goto-char pos) (outline-next-heading)
                   collect (point) into ends
                   finally return (cons prompt-end ends))))
            (gptel--with-buffer-copy org-buf nil nil
              (cl-loop for start in start-bounds
                       for end in end-bounds
                       do (insert-buffer-substring org-buf start end)
                       (goto-char (point-min)))
              (goto-char (point-max))
              (gptel-org--unescape-tool-results)
              (gptel-org--strip-block-headers)
              (when-let* ((gptel-org-ignore-elements ;not copied by -with-buffer-copy
                           (buffer-local-value 'gptel-org-ignore-elements
                                               org-buf)))
                (gptel-org--strip-elements))
              (setq org-complex-heading-regexp ;For org-element-context to run
                    (buffer-local-value 'org-complex-heading-regexp org-buf))
              (setq tab-width      ;Match source indentation for list parsing
                    (buffer-local-value 'tab-width org-buf))
              (current-buffer))))
      ;; Create prompt the usual way
      (let ((org-buf (current-buffer))
            (beg (point-min)))
        (gptel--with-buffer-copy org-buf beg prompt-end
          (gptel-org--unescape-tool-results)
          (gptel-org--strip-block-headers)
          (when-let* ((gptel-org-ignore-elements ;not copied by -with-buffer-copy
                       (buffer-local-value 'gptel-org-ignore-elements
                                           org-buf)))
                (gptel-org--strip-elements))
          (setq org-complex-heading-regexp ;For org-element-context to run
                (buffer-local-value 'org-complex-heading-regexp org-buf))
          (setq tab-width      ;Match source indentation for list parsing
                (buffer-local-value 'tab-width org-buf))
          (current-buffer))))))

(defun gptel-org--strip-elements ()
  "Remove all elements in `gptel-org-ignore-elements' from the prompt."
  (let ((major-mode 'org-mode) element-markers)
    (if (equal '(property-drawer) gptel-org-ignore-elements)
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward org-property-drawer-re nil t)
            ;; ;; Slower but accurate
            ;; (let ((drawer (org-element-at-point)))
            ;;   (when (org-element-type-p drawer 'property-drawer)
            ;;     (delete-region (org-element-begin drawer) (org-element-end drawer))))

            ;; Fast but inexact, can have false positives
            (delete-region (match-beginning 0) (match-end 0))))
      ;; NOTE: Parsing the buffer is extremely slow.  Avoid this path unless
      ;; required.
      ;; NOTE: `org-element-map' takes a third KEEP-DEFERRED argument in newer
      ;; Org versions
      (org-element-map (org-element-parse-buffer 'element nil)
          gptel-org-ignore-elements
        (lambda (node)
          (push (list (gptel-org--element-begin node)
                      (gptel-org--element-end node))
                element-markers)))
      (dolist (bounds element-markers)
        (apply #'delete-region bounds)))))

(defun gptel-org--strip-block-headers ()
  "Remove all gptel-specific block headers and footers.
Every line that matches will be removed entirely.

This removal is necessary to avoid auto-mimicry by LLMs."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward
            (rx line-start (literal "#+")
                (or (literal "begin") (literal "end"))
                (or (literal "_tool") (literal "_reasoning")))
            nil t)
      (delete-region (match-beginning 0)
                     (min (point-max) (1+ (line-end-position)))))))

(defun gptel-org--unescape-tool-results ()
  "Undo escapes done to keep results from escaping blocks.
Scans backward for gptel tool text property, then unescapes the block
contents."
  (save-excursion
    (goto-char (point-max))
    (let ((prev-pt (point)))
      (while (> prev-pt (point-min))
        (goto-char
         (previous-single-char-property-change (point) 'gptel))
        (let ((prop (get-text-property (point) 'gptel))
              (backward-progress (point)))
          (when (eq (car-safe prop) 'tool)
            ;; User edits to clean up can potentially insert a tool-call header
            ;; that is propertized.  Tool call headers should not be
            ;; propertized.
            (when (looking-at-p "[[:space:]]*#\\+begin_tool")
              (goto-char (match-end 0)))
            ;; TODO this code is able to put the point behind prev-pt, which
            ;; makes the region inverted.  The `max' catches this, but really
            ;; `read' and `looking-at' are the culprits.  Badly formed tool
            ;; blocks can lead to this being necessary.
            (org-unescape-code-in-region
             (min prev-pt (point)) prev-pt))
          (goto-char (setq prev-pt backward-progress)))))))

(defun gptel-org--link-standalone-p (object)
  "Check if link OBJECT is on a line by itself."
  (when-let* ((par (gptel-org--element-parent object))
              ((eq (org-element-type par) 'paragraph)))
    (and (= (gptel-org--element-begin object)
            (save-excursion
              (goto-char (org-element-property :contents-begin par))
              (skip-chars-forward "\t ")
              (point)))                 ;account for leading space before object
         (<= (- (org-element-property :contents-end par)
                (org-element-property :end object))
             1))))

(defsubst gptel-org--validate-link (link)
  "Validate an Org LINK as sendable under the current gptel settings.

Return a form (validp link-type path . REST), where REST is a list
explaining why sending the link is not supported by gptel.  Only the
first nil value in REST is guaranteed to be correct."
  (let ((mime))
    (if-let* ((link-type (org-element-property :type link))
              (resource-type
               (or (and (member link-type '("attachment" "file")) 'file)
                   (and (gptel--model-capable-p 'url)
                        (member link-type '("http" "https" "ftp")) 'url)))
              (path (org-element-property :path link))
              (user-check (funcall gptel-org-validate-link link))
              (readablep (or (eq resource-type 'url)
                             (file-remote-p default-directory)
                             (file-remote-p path)
                             (file-readable-p path)))
              (mime-valid
               (or (eq resource-type 'url)
                   (and (with-memoization
                            (alist-get (expand-file-name path)
                                       gptel--link-type-cache
                                       nil nil #'string=)
                          (if (gptel--file-binary-p path) t))
                        (setq mime (mailcap-file-name-to-mime-type path))
                        (gptel--model-mime-capable-p mime))
                   t)))
        (list t link-type path resource-type user-check readablep mime-valid mime)
      (list nil link-type path resource-type user-check readablep mime-valid mime))))

(cl-defmethod gptel--parse-media-links ((_mode (eql 'org-mode)) beg end)
  "Parse text and actionable links between BEG and END.

Return a list of the form
 ((:text \"some text\")
  (:media \"/path/to/media.png\" :mime \"image/png\")
  (:text \"More text\"))
for inclusion into the user prompt for the gptel request."
  (let ((parts) (from-pt))
    (save-excursion
      (setq from-pt (goto-char beg))
      (while (re-search-forward gptel-org--link-regex end t)
        (let* ((link (org-element-context))
               (link-status (gptel-org--validate-link link)))
          (cl-destructuring-bind
              (valid type path resource-type user-check readablep mime-valid mime)
              link-status
            (cond
             ((and valid (member type '("file" "attachment")))
              ;; Text file or supported binary file: collect text up to link
              (when-let* ((text (buffer-substring-no-properties
                                 from-pt (gptel-org--element-begin link))))
                (unless (string-blank-p text) (push (list :text text) parts)))
              ;; collect link
              (push (if mime (list :media path :mime mime) (list :textfile path))
                    parts)
              (setq from-pt (point)))
             ((and valid (member type '("http" "https" "ftp")))
              ;; Collect text up to this image, and collect this image url
              (when-let* ((text (buffer-substring-no-properties
                                 from-pt (gptel-org--element-begin link))))
                (unless (string-blank-p text) (push (list :text text) parts)))
              (push (list :url (org-element-property :raw-link link) :mime mime) parts)
              (setq from-pt (point)))
             ((not resource-type)
              (message "Link source not followed for unsupported link type \"%s\"." type))
             ((not user-check)
              (message (if (eq gptel-org-validate-link 'gptel--link-standalone-p)
                           "Ignoring non-standalone link \"%s\"."
                         "Link %s failed to validate, see `gptel-org-validate-link'.")
                       path))
             ((not readablep)
              (message "Ignoring inaccessible file \"%s\"." path))
             ((and (not mime-valid) (eq resource-type 'file))
              (message "Ignoring unsupported binary file \"%s\"." path))))))
      (unless (= from-pt end)
        (push (list :text (buffer-substring-no-properties from-pt end)) parts)))
    (nreverse parts)))

(defun gptel-org--annotate-links (beg end)
  "Annotate Org links whose sources will be sent with `gptel-send'.

Search between BEG and END."
  (when gptel-track-media
    (save-excursion
      (goto-char beg) (forward-line -1)
      (let ((link-ovs (cl-loop for o in (overlays-in (point) end)
                               if (overlay-get o 'gptel-track-media)
                               collect o into os finally return os)))
        (while (re-search-forward gptel-org--link-regex end t)
          (unless (gptel--in-response-p (1- (point)))
            (let* ((link (org-element-context))
                   (from (org-element-begin link))
                   (to (org-element-end link))
                   (link-status (gptel-org--validate-link link))
                   (ov (cl-loop for o in (overlays-in from to)
                                if (overlay-get o 'gptel-track-media)
                                return o)))
              (if ov                    ; Ensure overlay over each link
                  (progn (move-overlay ov from to)
                         (setq link-ovs (delq ov link-ovs)))
                (setq ov (make-overlay from to nil t))
                (overlay-put ov 'gptel-track-media t)
                (overlay-put ov 'evaporate t)
                (overlay-put ov 'priority -80))
              ;; Check if link will be sent, and annotate accordingly
              (gptel--annotate-link ov link-status))))
        (and link-ovs (mapc #'delete-overlay link-ovs))))
    `(jit-lock-bounds ,beg . ,end)))

(defvar-local gptel-org--send-system-state nil
  "Cache for `gptel-org--merge-system-message': (ORG-CANON . BUF-CANON).")

(defun gptel-org--merge-system-message (org-system buf-directive)
  "Return the system directive to use for one send in Org mode.

ORG-SYSTEM is the GPTEL_SYSTEM entry string (already unescaped) or nil.
BUF-DIRECTIVE is `gptel-system-prompt'.

When both are set but differ, prefer the side that changed since the last
send (`gptel-org--send-system-state'); otherwise prefer ORG-SYSTEM."
  (let* ((org-canon (and org-system
                         (car-safe (gptel--parse-directive org-system))))
         (buf-canon (car-safe (gptel--parse-directive buf-directive)))
         (last (or gptel-org--send-system-state '(nil . nil)))
         (last-org (car last))
         (last-buf (cdr last)))
    (prog1
        (cond
         ((null org-system) buf-directive)
         ((null buf-directive) org-system)
         ((equal org-canon buf-canon) buf-directive)
         ((and last-org (not (equal org-canon last-org)))
          org-system)
         ((and last-buf (not (equal buf-canon last-buf)))
          buf-directive)
         (t org-system))
      (setq gptel-org--send-system-state (cons org-canon buf-canon)))))

(defun gptel-org--send-with-props (send-fun &rest args)
  "Conditionally modify SEND-FUN's calling environment.

If in an Org buffer under a heading containing a stored gptel
configuration, use that for requests instead.  This includes the
system message, model and provider (backend), among other
parameters.

When a buffer system-message section is present, it takes precedence
over `GPTEL_SYSTEM' and over `gptel-org--merge-system-message'.
Otherwise the heading property and buffer prompt are merged via
`gptel-org--merge-system-message'.

ARGS are the original function call arguments."
  (if (derived-mode-p 'org-mode)
      (let* ((buf-system gptel-system-prompt)
             (from-section (gptel-org--apply-buffer-system-message)))
        (pcase-let ((`( ,prop-preset ,prop-system ,prop-backend ,prop-model
                        ,prop-temp ,prop-tokens ,prop-num ,prop-tools)
                     (gptel-org--entry-properties)))
          (setq gptel--preset (or prop-preset gptel--preset)
                gptel-backend (or prop-backend gptel-backend)
                gptel-model (or prop-model gptel-model)
                gptel-temperature (or prop-temp gptel-temperature)
                gptel-max-tokens (or prop-tokens gptel-max-tokens)
                gptel--num-messages-to-send (or prop-num gptel--num-messages-to-send)
                gptel-tools (or prop-tools gptel-tools))
          (unless from-section
            (setq gptel-system-prompt
                  (gptel-org--merge-system-message prop-system buf-system)))
          (apply send-fun args)))
    (apply send-fun args)))

(defun gptel-org--system-message-with-rewrite-directive (rewrite-directive
                                                         &optional section-text)
  "Merge SECTION-TEXT or buffer system message with REWRITE-DIRECTIVE.
SECTION-TEXT defaults to `gptel-system-prompt'.  Used for `gptel-rewrite'."
  (let ((buffer-msg (or section-text
                        (car (gptel--parse-directive gptel-system-prompt 'raw))))
        (rewrite-msg (car (gptel--parse-directive rewrite-directive 'raw))))
    (cond
     ((and buffer-msg rewrite-msg (not (string-empty-p buffer-msg)))
      (concat buffer-msg "\n\n" rewrite-msg))
     (t (or buffer-msg rewrite-msg)))))

(defun gptel-org--system-section-usable-for-rewrite-p (bounds &optional target-bounds)
  "Non-nil when system section BOUNDS may be used for `gptel-rewrite'.
TARGET-BOUNDS is (BEG . END) of the rewrite region, or nil."
  (and bounds
       (not (and target-bounds
                 (pcase-let ((`(,tbeg . ,tend) target-bounds))
                   (gptel-org--bounds-overlap-p tbeg tend (car bounds) (cdr bounds)))))
       (not (gptel-org--point-in-system-section-p (point) bounds))))

(defun gptel-org--rewrite-request-system (&optional announce)
  "Return the :system value for `gptel-rewrite' in the current Org buffer.

When ANNOUNCE is non-nil, set `gptel-system-prompt' from the section and
show the usual log message.  Return nil when only `gptel--rewrite-directive'
should be used (no section or rewrite region overlaps the section)."
  (when (and gptel-org-use-system-section (derived-mode-p 'org-mode))
    (when-let* ((bounds (gptel-org--system-section-bounds))
                (_ (gptel-org--system-section-usable-for-rewrite-p
                    bounds (gptel-org--rewrite-target-bounds)))
                (section (gptel-org--system-section-message bounds)))
      (when announce
        (gptel-org--use-section-system-message section))
      (gptel-org--system-message-with-rewrite-directive
       gptel--rewrite-directive section))))

(defun gptel-org--rewrite-system-for-display ()
  "System message to show in the `gptel-rewrite' transient (preview only)."
  (or (gptel-org--rewrite-request-system)
      gptel--rewrite-directive))

(defun gptel-org--suffix-rewrite-with-system-section (orig &optional rewrite-message dry-run)
  "Attach buffer system section to the upcoming `gptel--suffix-rewrite' request."
  (let ((gptel-org--in-rewrite t))
    (when-let* ((system (gptel-org--rewrite-request-system t)))
      (setq gptel-org--rewrite-merged-system system))
    (unwind-protect
        (apply orig rewrite-message dry-run)
      (setq gptel-org--rewrite-merged-system nil))))

(defun gptel-org--request-with-system-section (orig &optional prompt &rest args)
  "Apply system-message section when calling `gptel-request' in Org."
  (cond
   (gptel-org--rewrite-merged-system
    (apply orig prompt
           (plist-put args :system gptel-org--rewrite-merged-system)))
   ;; During a rewrite without a usable section, keep the explicit :system
   ;; directive rather than reapplying (and possibly erroring on) the section.
   (gptel-org--in-rewrite
    (apply orig prompt args))
   ((derived-mode-p 'org-mode)
    (gptel-org--apply-buffer-system-message)
    (apply orig prompt args))
   (t (apply orig prompt args))))

(advice-add 'gptel-send :around #'gptel-org--send-with-props)
(advice-add 'gptel--suffix-send :around #'gptel-org--send-with-props)
(advice-add 'gptel--suffix-rewrite :around #'gptel-org--suffix-rewrite-with-system-section)
(advice-add 'gptel-request :around #'gptel-org--request-with-system-section)


;;; Saving and restoring state
(defun gptel-org--entry-properties (&optional pt)
  "Find gptel configuration properties stored at PT."
  (pcase-let
      ((`(,preset ,system ,backend ,model ,temperature ,tokens ,num ,tools)
         (mapcar
          (lambda (prop) (org-entry-get (or pt (point)) prop 'selective))
          '("GPTEL_PRESET" "GPTEL_SYSTEM" "GPTEL_BACKEND"
            "GPTEL_MODEL" "GPTEL_TEMPERATURE" "GPTEL_MAX_TOKENS"
            "GPTEL_NUM_MESSAGES_TO_SEND" "GPTEL_TOOLS"))))
    (when preset (setq preset (gptel--intern preset)))
    (when system
      (setq system (string-replace "\\n" "\n" system)))
    (when backend
      (setq backend (alist-get backend gptel--known-backends
                               nil nil #'equal)))
    (when model (setq model (gptel--intern model)))
    (when temperature
      (setq temperature (gptel--to-number temperature)))
    (when tokens (setq tokens (gptel--to-number tokens)))
    (when num (setq num (gptel--to-number num)))
    (when tools
      (setq tools (cl-loop
                   for tname in (split-string tools)
                   for tool = (with-demoted-errors "gptel: %S"
                                (gptel-get-tool tname))
                   if tool collect tool else do
                   (display-warning
                    '(gptel org tools)
                    (format "Tool %s not found, ignoring" tname)))))
    (list preset system backend model temperature tokens num tools)))

(defun gptel-org--restore-state ()
  "Restore gptel state for Org buffers when turning on `gptel-mode'."
  (save-restriction
    (widen)
    (condition-case status
        (progn
          (when-let* ((bounds (org-entry-get (point-min) "GPTEL_BOUNDS")))
            (gptel--restore-props (read bounds)))
          (pcase-let ((`(,preset ,system ,backend ,model ,temperature ,tokens ,num ,tools)
                       (gptel-org--entry-properties (point-min))))
            (when preset
              (if (gptel-get-preset preset)
                  (progn (gptel--apply-preset
                          preset (lambda (sym val) (set (make-local-variable sym) val)))
                         (setq gptel--preset preset))
                (display-warning
                 '(gptel presets)
                 (format "Could not activate gptel preset `%s' in buffer \"%s\""
                         preset (buffer-name)))))
            (when system (setq-local gptel-system-prompt system))
            (when-let* ((section (and gptel-org-use-system-section
                                      (gptel-org--system-section-message))))
              (setq-local gptel-system-prompt section))
            (if backend (setq-local gptel-backend backend)
              (message
               (substitute-command-keys
                (concat
                 "Could not activate gptel backend \"%s\"!  "
                 "Switch backends with \\[universal-argument] \\[gptel-send]"
                 " before using gptel."))
               backend))
            (when model (setq-local gptel-model model))
            (when temperature (setq-local gptel-temperature temperature))
            (when tokens (setq-local gptel-max-tokens tokens))
            (when num (setq-local gptel--num-messages-to-send num))
            (when tools (setq-local gptel-tools tools))))
      (:success (message "gptel chat restored."))
      (error (message "Could not restore gptel state, sorry! Error: %s" status)))))

(defun gptel-org-set-properties (pt &optional msg)
  "Store the active gptel configuration under the current heading.

PT is the cursor position by default.  If MSG is non-nil (default),
display a message afterwards.

If a gptel preset has been applied in this buffer, a reference to it is
saved.

Additional metadata is stored only if no preset was applied or if it
differs from the preset specification.  This is limited to the active
gptel model and backend names, the system message, active tools, the
response temperature, max tokens and number of conversation turns to
send in queries.  (See `gptel--num-messages-to-send' for the last one.)"
  (interactive (list (point) t))
  (require 'gptel)
  (let ((preset-spec (and gptel--preset (gptel-get-preset gptel--preset))))
    (if preset-spec
        (org-entry-put pt "GPTEL_PRESET" (gptel--to-string gptel--preset))
      (org-entry-delete pt "GPTEL_PRESET"))

    ;; FIXME: nil can mean "no value was explicitly set by the user" as well as
    ;; "this setting has been set to nil".  We are not yet distinguishing
    ;; between the two when saving Org properties.  This is particularly
    ;; relevant for the system message, whose explicit nil value will not be
    ;; captured when saving Org buffers.

    ;; Model and backend
    (if (gptel--preset-mismatch-value preset-spec :model gptel-model)
        (org-entry-put pt "GPTEL_MODEL" (gptel--model-name gptel-model)))
    (if (gptel--preset-mismatch-value preset-spec :backend gptel-backend)
        (org-entry-put pt "GPTEL_BACKEND" (gptel-backend-name gptel-backend)))
    ;; System message
    (if-let* ((section (and gptel-org-use-system-section
                           (gptel-org--system-section-message))))
        ;; The buffer section is authoritative; drop stale GPTEL_SYSTEM.
        (org-entry-delete pt "GPTEL_SYSTEM")
      (let ((parsed (car-safe (gptel--parse-directive gptel-system-prompt))))
        (if (gptel--preset-mismatch-value preset-spec :system parsed)
            (when parsed
              (org-entry-put pt "GPTEL_SYSTEM"
                             (string-replace "\n" "\\n" parsed)))
          (org-entry-delete pt "GPTEL_SYSTEM"))))
    ;; Tools
    (let ((tool-names (mapcar #'gptel-tool-name gptel-tools)))
      (if (gptel--preset-mismatch-value preset-spec :tools tool-names)
          (org-entry-put pt "GPTEL_TOOLS" (string-join tool-names " "))
        (org-entry-delete pt "GPTEL_TOOLS")))
    ;; Temperature, max tokens and cutoff
    (if (and (gptel--preset-mismatch-value preset-spec :temperature gptel-temperature)
             (not (equal (default-value 'gptel-temperature) gptel-temperature)))
        (org-entry-put pt "GPTEL_TEMPERATURE" (number-to-string gptel-temperature))
      (org-entry-delete pt "GPTEL_TEMPERATURE"))
    (if (and (gptel--preset-mismatch-value preset-spec :max-tokens gptel-max-tokens)
             gptel-max-tokens)
        (org-entry-put pt "GPTEL_MAX_TOKENS" (number-to-string gptel-max-tokens))
      (org-entry-delete pt "GPTEL_MAX_TOKENS"))
    (if (and (gptel--preset-mismatch-value
              preset-spec :num-messages-to-send gptel--num-messages-to-send)
             (natnump gptel--num-messages-to-send))
        (org-entry-put pt "GPTEL_NUM_MESSAGES_TO_SEND"
                       (number-to-string gptel--num-messages-to-send))
      (org-entry-delete pt "GPTEL_NUM_MESSAGES_TO_SEND")))
  (when msg
    (message "Added gptel configuration to current headline.")))

(defun gptel-org--save-state ()
  "Write the gptel state to the Org buffer as Org properties."
  (org-with-wide-buffer
   (goto-char (point-min))
   (when (org-at-heading-p)
     (org-open-line 1))
   (gptel-org-set-properties (point-min))
   ;; Save response boundaries
   (letrec ((write-bounds
             (lambda (attempts)
               (when-let* ((bounds (gptel--get-buffer-bounds))
                           ;; first value of ((prop . ((beg end val)...))...)
                           (offset (caadar bounds))
                           (offset-marker (set-marker (make-marker) offset)))
                 (org-entry-put (point-min) "GPTEL_BOUNDS"
                                (prin1-to-string (gptel--get-buffer-bounds)))
                 (when (and (not (= (marker-position offset-marker) offset))
                            (> attempts 0))
                   (funcall write-bounds (1- attempts)))))))
     (funcall write-bounds 6))))


;;; Transforming responses
;;;###autoload
(defun gptel--convert-markdown->org (str)
  "Convert string STR from markdown to org markup.

This is a very basic converter that handles only a few markup
elements."
  (with-temp-buffer
    (insert str)
    (goto-char (point-min))
    (while (re-search-forward "`+\\|\\*\\{1,2\\}\\|_\\|^#+" nil t)
      (pcase (match-string 0)
        ;; Handle backticks
        ((and (guard (eq (char-before) ?`)) ticks)
         (gptel--replace-source-marker (length ticks))
         (save-match-data
           (catch 'block-end
             (while (search-forward ticks nil t)
               (unless (or (eq (char-before (match-beginning 0)) ?`)
                           (eq (char-after) ?`))
                 (gptel--replace-source-marker (length ticks) 'end)
                 (throw 'block-end nil))))))
        ;; Handle headings
        ((and (guard (eq (char-before) ?#)) heading)
         (cond
          ((looking-at "[[:space:]]")   ;Handle headings
           (delete-region (line-beginning-position) (point))
           (insert (make-string (length heading) ?*)))
          ((looking-at "\\+begin_src") ;Overeager LLM switched to using Org src blocks
           (save-match-data (re-search-forward "^#\\+end_src" nil t)))))
        ;; Handle emphasis
        ("**" (cond
               ;; ((looking-at "\\*\\(?:[[:word:]]\\|\s\\)")
               ;;  (delete-char 1))
               ((looking-back "\\(?:[[:word:][:punct:]\n]\\|\s\\)\\*\\{2\\}"
                              (max (- (point) 3) (point-min)))
                (delete-char -1))))
        ("*"
         (cond
          ((save-match-data
             (and (or (= (point) 2)
                      (looking-back "\\(?:[[:space:]]\\|\s\\)\\(?:_\\|\\*\\)"
                                    (max (- (point) 2) (point-min))))
                  (not (looking-at "[[:space:]]\\|\s"))))
           ;; Possible beginning of emphasis
           (and
            (save-excursion
              (when (and (re-search-forward (regexp-quote (match-string 0))
                                            (line-end-position) t)
                         (looking-at "[[:space:][:punct:]]\\|\s")
                         (not (looking-back "\\(?:[[:space]]\\|\s\\)\\(?:_\\|\\*\\)"
                                            (max (- (point) 2) (point-min)))))
                (delete-char -1) (insert "/") t))
            (progn (delete-char -1) (insert "/"))))
          ((save-excursion
             (ignore-errors (backward-char 2))
             (or (and (bobp) (looking-at "\\*[[:space:]]"))
                 (looking-at "\\(?:$\\|\\`\\)\n\\*[[:space:]]")))
           ;; Bullet point, replace with hyphen
           (delete-char -1) (insert "-"))))))
    (buffer-string)))

(defun gptel--replace-source-marker (num-ticks &optional end)
  "Replace markdown style backticks with Org equivalents.

NUM-TICKS is the number of backticks being replaced.  If END is
true these are \"ending\" backticks.

This is intended for use in the markdown to org stream converter."
  (let ((from (match-beginning 0)))
    (delete-region from (point))
    (if (and (= num-ticks 3)
             (save-excursion (beginning-of-line)
                             (skip-chars-forward " \t")
                             (eq (point) from)))
        (insert (if end "#+end_src" "#+begin_src "))
      (insert "="))))

;;;###autoload
(defun gptel--stream-convert-markdown->org (start-marker)
  "Return a Markdown to Org converter.

This function parses a stream of Markdown text to Org
continuously when it is called with successive chunks of the
text stream.

START-MARKER is used to identify the corresponding process when
cleaning up after."
  (letrec ((in-src-block nil)           ;explicit nil to address BUG #183
           (in-org-src-block nil)
           (temp-buf ; NOTE: Switch to `generate-new-buffer' after we drop Emacs 27.1
            (gptel--temp-buffer " *gptel-temp*"))
           (start-pt (make-marker))
           (ticks-total 0)      ;MAYBE should we let-bind case-fold-search here?
           (cleanup-fn
            (lambda (beg _)
              (when (and (equal beg (marker-position start-marker))
                         (eq (current-buffer) (marker-buffer start-marker)))
                (when (buffer-live-p (get-buffer temp-buf))
                  (set-marker start-pt nil)
                  (kill-buffer temp-buf))
                (remove-hook 'gptel-post-response-functions cleanup-fn)))))
    (add-hook 'gptel-post-response-functions cleanup-fn)
    (lambda (str)
      (let ((noop-p) (ticks 0))
        (with-current-buffer (get-buffer temp-buf)
          (save-excursion (goto-char (point-max)) (insert str))
          (when (marker-position start-pt) (goto-char start-pt))
          (when in-src-block (setq ticks ticks-total))
          (save-excursion
            (while (re-search-forward "`\\|\\*\\{1,2\\}\\|_\\|^#+" nil t)
              (pcase (match-string 0)
                ("`"
                 ;; Count number of consecutive backticks
                 (backward-char)
                 (while (and (char-after) (eq (char-after) ?`))
                   (forward-char)
                   (if in-src-block (cl-decf ticks) (cl-incf ticks)))
                 ;; Set the verbatim state of the parser
                 (if (and (eobp)
                          ;; Special case heuristic: If the response ends with
                          ;; ^``` we don't wait for more input.
                          ;; FIXME: This can have false positives.
                          (not (save-excursion (beginning-of-line)
                                               (looking-at "^```$"))))
                     ;; End of input => there could be more backticks coming,
                     ;; so we wait for more input
                     (progn (setq noop-p t) (set-marker start-pt (match-beginning 0)))
                   ;; We reached a character other than a backtick
                   (cond
                    ;; Ticks balanced, end src block
                    ((= ticks 0)
                     (progn (setq in-src-block nil)
                            (gptel--replace-source-marker ticks-total 'end)))
                    ;; Positive number of ticks, start an src block
                    ((and (> ticks 0) (not in-src-block))
                     (setq ticks-total ticks
                           in-src-block t)
                     (gptel--replace-source-marker ticks-total))
                    ;; Negative number of ticks or in a src block already,
                    ;; reset ticks
                    (t (setq ticks ticks-total)))))
                ;; Handle headings and misguided #+begin_src text
                ((and (guard (and (eq (char-before) ?#) (or (not in-src-block) in-org-src-block)))
                      heading)
                 (if in-org-src-block
                     ;; If we are inside an Org-style src block, look for #+end_src
                     (cond
                      ((< (- (point-max) (point)) 8) ;not enough information to close Org src block
                       (setq noop-p t) (set-marker start-pt (match-beginning 0)))
                      ((looking-at "\\+end_src") ;Close Org src block
                       (setq in-src-block nil in-org-src-block nil)))
                   ;; Otherwise check for Markdown headings, or for #+begin_src
                   (cond
                    ((eobp)       ; Not enough information about the heading yet
                     (setq noop-p t) (set-marker start-pt (match-beginning 0)))
                    ((looking-at "[[:space:]]") ; Convert markdown heading to Org heading
                     (delete-region (line-beginning-position) (point))
                     (insert (make-string (length heading) ?*)))
                    ((< (- (point-max) (point)) 11) ;Not enough information to check if Org src block
                     (setq noop-p t) (set-marker start-pt (match-beginning 0)))
                    ((looking-at "\\+begin_src ") ;Overeager LLM switched to using Org src blocks
                     (setq in-src-block t in-org-src-block t)))))
                ;; Handle other chars: emphasis, bold and bullet items
                ((and "**" (guard (not in-src-block)))
                 (cond
                  ;; TODO Not sure why this branch was needed
                  ;; ((looking-at "\\*\\(?:[[:word:]]\\|\s\\)") (delete-char 1))

                  ;; Looking back at "w**" or " **"
                  ((looking-back "\\(?:[[:word:][:punct:]\n]\\|\s\\)\\*\\{2\\}"
                                 (max (- (point) 3) (point-min)))
                   (delete-char -1))))
                ((and "*" (guard (not in-src-block)))
                 (if (eobp)
                     ;; Not enough information about the "*" yet
                     (progn (setq noop-p t) (set-marker start-pt (match-beginning 0)))
                   ;; "*" is either emphasis or a bullet point
                   (save-match-data
                     (save-excursion
                       (ignore-errors (backward-char 2))
                       (cond
                        ((and     ; At bob, underscore/asterisk followed by word
                          (or (and (bobp) (looking-at "\\(?:_\\|\\*\\)\\([^[:space:][:punct:]]\\|$\\)"))
                              (looking-at ; word followed by underscore/asterisk
                               "[^[:space:]\n]\\(?:_\\|\\*\\)\\(?:[[:space:][:punct:]]\\|$\\)")
                              (looking-at ; underscore/asterisk followed by word
                               "\\(?:[[:space:]]\\)\\(?:_\\|\\*\\)\\([^[:space:]]\\|$\\)"))
                          (not (looking-at "[[:punct:]]\\(?:_\\|\\*\\)[[:punct:]]")))
                         ;; Emphasis, replace with slashes
                         (forward-char (if (bobp) 1 2)) (delete-char -1) (insert "/"))
                        ((or (and (bobp) (looking-at "\\*[[:space:]]"))
                             (looking-at "\\(?:$\\|\\`\\)\n\\*[[:space:]]"))
                         ;; Bullet point, replace with hyphen
                         (forward-char (if (bobp) 1 2)) (delete-char -1) (insert "-"))))))))))
          (if noop-p
              (buffer-substring (point) start-pt)
            (prog1 (buffer-substring (point) (point-max))
                   (set-marker start-pt (point-max)))))))))

(provide 'gptel-org)
;;; gptel-org.el ends here

;; Silence warnings about `org-element-type-p' and `org-element-parent', see #294.
;; Local Variables:
;; byte-compile-warnings: (not unresolved)
;; End:
