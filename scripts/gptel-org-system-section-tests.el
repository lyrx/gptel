;;; gptel-org-system-section-tests.el --- Tests for buffer system-message section  -*- lexical-binding: t -*-

(require 'ert)
(require 'org)
(require 'gptel-request)
(require 'gptel-org)
;; gptel-rewrite pulls in transient; load it so the rewrite UI helper can be
;; tested.  Guard against environments where transient is unavailable.
(require 'gptel-rewrite nil t)

(defvar gptel-org-system-section--test-buffer nil
  "Shared Org buffer for section tests (org-mode initialized once).")

(defconst gptel-org-system-section--begin ":GPTEL_SYSTEM_MESSAGE: t\n")
(defconst gptel-org-system-section--end ":GPTEL_SYSTEM_MESSAGE_END: t\n")

(defun gptel-org-system-section--section (body)
  "Return a delimited Org-property system section containing BODY."
  (concat gptel-org-system-section--begin body "\n" gptel-org-system-section--end))

(defun gptel-org-system-section--comment-section (prefix body)
  "Return a section with comment PREFIX (#, ;;, …) before marker names."
  (concat prefix "GPTEL_SYSTEM_MESSAGE\n" body "\n"
          prefix "GPTEL_SYSTEM_MESSAGE_END\n"))

(defun gptel-org-system-section--chat-and-section (chat body)
  (concat chat "\n\n* System\n" (gptel-org-system-section--section body)))

(defconst gptel-org-system-section--standard-buffer
  (gptel-org-system-section--chat-and-section "* Chat\n\n** User\nHi" "Be helpful."))

(defun gptel-org-system-section--with-org-buffer (contents fn)
  "Run FN in an Org buffer containing CONTENTS."
  (unless gptel-org-system-section--test-buffer
    (setq gptel-org-system-section--test-buffer
          (generate-new-buffer " *gptel-org-system-section-test*"))
    (with-current-buffer gptel-org-system-section--test-buffer
      (let ((org-mode-hook nil))
        (org-mode))))
  (with-current-buffer gptel-org-system-section--test-buffer
    (erase-buffer)
    (insert contents)
    (goto-char (point-min))
    (setq gptel-org--system-section-cache nil)
    (funcall fn)))

(defun gptel-org-system-section--goto-chat ()
  (goto-char (save-excursion
               (goto-char (point-min))
               (search-forward "Hi\n")
               (point))))

(ert-deftest gptel-org-system-section-bounds ()
  (gptel-org-system-section--with-org-buffer gptel-org-system-section--standard-buffer
   (lambda ()
     (let ((bounds (gptel-org--system-section-bounds)))
       (should bounds)
       (goto-char (car bounds))
       (should (looking-at ":GPTEL_SYSTEM_MESSAGE:"))))))

(ert-deftest gptel-org-system-section-message-text ()
  (gptel-org-system-section--with-org-buffer gptel-org-system-section--standard-buffer
   (lambda ()
     (should (string= "Be helpful." (gptel-org--system-section-message))))))

(ert-deftest gptel-org-system-section-prompt-excludes-section ()
  (gptel-org-system-section--with-org-buffer gptel-org-system-section--standard-buffer
   (lambda ()
     (gptel-org-system-section--goto-chat)
     (let ((prompt (gptel-org--create-prompt-buffer)))
       (unwind-protect
           (with-current-buffer prompt
             (should (not (string-match-p "Be helpful" (buffer-string)))))
         (kill-buffer prompt))))))

(ert-deftest gptel-org-system-section-send-system ()
  (gptel-org-system-section--with-org-buffer gptel-org-system-section--standard-buffer
   (lambda ()
     (goto-char (save-excursion (search-forward "Hi") (forward-line 1) (point)))
     (should (string= "Be helpful."
                      (gptel-org--system-section-message-for-send))))))

(ert-deftest gptel-org-system-section-cursor-inside-errors ()
  (gptel-org-system-section--with-org-buffer
   (gptel-org-system-section--chat-and-section "* Chat" "Be helpful.")
   (lambda ()
     (goto-char (save-excursion (search-forward "Be helpful")))
     (should-error (gptel-org--system-section-message-for-send)))))

(ert-deftest gptel-org-system-section-region-overlap-errors ()
  (gptel-org-system-section--with-org-buffer gptel-org-system-section--standard-buffer
   (lambda ()
     (gptel-org-system-section--goto-chat)
     (push-mark (point-max) t)
     (goto-char (point-min))
     (activate-mark)
     (should-error (gptel-org--cap-prompt-end-for-system-section nil)))))

(ert-deftest gptel-org-system-section-save-preserves-local-variables-trailer ()
  "Saving an Org buffer must NOT touch a Local Variables trailer.

gptel persists Org state in properties, never in a file-local-variables
block.  Auto-deleting such a block on save was destructive (it dropped
unrelated locals like `mode:') and never fixed any real problem, so the
trailer is left untouched."
  (gptel-org-system-section--with-org-buffer
   (concat "* Chat\nHi\n\n* System\n"
           (gptel-org-system-section--section "Section prompt.")
           "\n\n;; Local Variables:\n"
           ";; mode: org\n"
           ";; gptel-model: kimi-k2.6\n"
           ";; End:\n")
   (lambda ()
     (require 'gptel-openai nil t)
     (setq-local gptel--preset nil
                 gptel-backend (or (default-value 'gptel-backend)
                                   (gptel-make-openai "Test" :key "test")))
     (gptel-org--save-state)
     (goto-char (point-min))
     (should (search-forward ";; Local Variables:" nil t))
     (should (search-forward ";; mode: org" nil t)))))

(ert-deftest gptel-org-system-section-save-deletes-stale-gptel-system ()
  "Saving with a buffer section removes stale GPTEL_SYSTEM property."
  (gptel-org-system-section--with-org-buffer
   (concat ":PROPERTIES:\n:GPTEL_SYSTEM: Old property prompt.\n:END:\n\n"
           "* Chat\nHi\n\n* System\n"
           (gptel-org-system-section--section "New section prompt."))
   (lambda ()
     (require 'gptel-openai nil t)
     (setq-local gptel--system-message "Old property prompt."
                 gptel--preset nil
                 gptel-backend (or (default-value 'gptel-backend)
                                   (gptel-make-openai "Test" :key "test")))
     (goto-char (point-min))
     (gptel-org-set-properties (point-min) nil)
     (should (null (org-entry-get (point-min) "GPTEL_SYSTEM" 'selective))))))

(ert-deftest gptel-org-system-section-restore-prefers-section ()
  "Restoring state uses the buffer section over GPTEL_SYSTEM."
  (gptel-org-system-section--with-org-buffer
   (concat ":PROPERTIES:\n:GPTEL_SYSTEM: Old property prompt.\n:END:\n\n"
           "* Chat\nHi\n\n* System\n"
           (gptel-org-system-section--section "New section prompt."))
   (lambda ()
     (setq buffer-file-name "gptel-org-system-section-test.org")
     (gptel-org--restore-state)
     (should (string= "New section prompt." gptel--system-message)))))

(ert-deftest gptel-org-system-section-overrides-heading-property ()
  (gptel-org-system-section--with-org-buffer
   (concat "* Chat\n:GPTEL_SYSTEM: From heading\n\n** User\nHi\n\n* System\n"
           (gptel-org-system-section--section "From subtree."))
   (lambda ()
     (gptel-org-system-section--goto-chat)
     (let ((gptel--system-message "Buffer default"))
       (gptel-org--apply-buffer-system-message)
       (should (string= "From subtree." gptel--system-message))))))

(ert-deftest gptel-org-system-section-last-section-wins ()
  (gptel-org-system-section--with-org-buffer
   (concat (gptel-org-system-section--section "Old.")
           "\n* Chat\nHi\n\n* System\n"
           (gptel-org-system-section--section "New."))
   (lambda ()
     (should (string= "New." (gptel-org--system-section-message)))
     (goto-char (car (gptel-org--system-section-bounds)))
     (should (search-forward "New" nil t)))))

(ert-deftest gptel-org-system-section-nested-outline-ok ()
  (gptel-org-system-section--with-org-buffer
   (gptel-org-system-section--chat-and-section "* Chat\n\n** User\nHi"
                                               "Be helpful.")
   (lambda ()
     (should (gptel-org--system-section-bounds))
     (should (string= "Be helpful." (gptel-org--system-section-message))))))

(ert-deftest gptel-org-system-section-bounds-cached ()
  (gptel-org-system-section--with-org-buffer gptel-org-system-section--standard-buffer
   (lambda ()
     (let ((b1 (gptel-org--system-section-bounds))
           (b2 (gptel-org--system-section-bounds)))
       (should (equal b1 b2))
       (should (eq (cadr gptel-org--system-section-cache)
                   (buffer-modified-tick)))))))

(ert-deftest gptel-org-system-section-text-after-end-ignored ()
  (gptel-org-system-section--with-org-buffer
   (concat "* System\n" (gptel-org-system-section--section "Be helpful.")
           "\n* Chat\nHi\n")
   (lambda ()
     (should (null (gptel-org--system-section-bounds))))))

(ert-deftest gptel-org-system-section-text-after-end-allowed ()
  (gptel-org-system-section--with-org-buffer
   (concat "* System\n" (gptel-org-system-section--section "Be helpful.")
           "\n* Chat\nHi\n")
   (lambda ()
     (let ((gptel-org-require-system-section-at-eof nil))
       (should (string= "Be helpful." (gptel-org--system-section-message)))))))

(ert-deftest gptel-org-system-section-missing-end-ignored ()
  (gptel-org-system-section--with-org-buffer
   (concat "* System\n" gptel-org-system-section--begin "Be helpful.\n")
   (lambda ()
     (should (null (gptel-org--system-section-bounds))))))

(ert-deftest gptel-org-system-section-missing-begin-ignored ()
  (gptel-org-system-section--with-org-buffer
   (concat "* System\n" gptel-org-system-section--end "Be helpful.\n")
   (lambda ()
     (should (null (gptel-org--system-section-bounds))))))

(ert-deftest gptel-org-system-section-begin-after-end-ignored ()
  (gptel-org-system-section--with-org-buffer
   (concat gptel-org-system-section--end "\nTrailing.\n"
           gptel-org-system-section--begin "Never used.\n")
   (lambda ()
     (should (null (gptel-org--system-section-bounds))))))

(ert-deftest gptel-org-system-section-comment-markers-hash ()
  (gptel-org-system-section--with-org-buffer
   (concat "* Chat\nHi\n\n"
           (gptel-org-system-section--comment-section "# " "Portable prompt."))
   (lambda ()
     (should (string= "Portable prompt."
                      (gptel-org--system-section-message))))))

(ert-deftest gptel-org-system-section-comment-markers-semicolon ()
  (gptel-org-system-section--with-org-buffer
   (concat "* Chat\nHi\n\n"
           (gptel-org-system-section--comment-section ";; "
                                                      "Elisp-style prompt."))
   (lambda ()
     (should (string= "Elisp-style prompt."
                      (gptel-org--system-section-message))))))

(ert-deftest gptel-org-system-section-rewrite-system-combined ()
  (gptel-org-system-section--with-org-buffer
   (concat "#+begin_src emacs-lisp\n(defun foo () 1)\n#+end_src\n\n* System\n"
           (gptel-org-system-section--section "Be helpful."))
   (lambda ()
     (goto-char (save-excursion (search-forward "emacs-lisp") (point)))
     (setq gptel--rewrite-directive "Rewrite instruction.")
     (gptel-org--apply-buffer-system-message)
     (should (string= "Be helpful.\n\nRewrite instruction."
                      (gptel-org--system-message-with-rewrite-directive
                       gptel--rewrite-directive)))
     (should (string= "Be helpful.\n\nRewrite instruction."
                      (gptel-org--rewrite-request-system))))))

(ert-deftest gptel-org-system-section-rewrite-display-preview ()
  (gptel-org-system-section--with-org-buffer
   (concat "#+begin_src emacs-lisp\n(defun foo () 1)\n#+end_src\n\n* System\n"
           (gptel-org-system-section--section "Be helpful."))
   (lambda ()
     (goto-char (save-excursion (search-forward "emacs-lisp") (point)))
     (setq gptel--rewrite-directive "Rewrite instruction.")
     (should (string= (gptel-org--rewrite-request-system)
                      (gptel-org--rewrite-system-for-display))))))

(ert-deftest gptel-org-system-section-rewrite-region-overlap-skips-section ()
  "A rewrite region overlapping the section falls back to the directive."
  (gptel-org-system-section--with-org-buffer
   (concat "#+begin_src emacs-lisp\n(defun foo () 1)\n#+end_src\n\n* System\n"
           (gptel-org-system-section--section "Be helpful."))
   (lambda ()
     (setq gptel--rewrite-directive "Rewrite instruction.")
     (let ((gptel--system-message "previous"))
       (goto-char (point-min))
       (push-mark (point-max) t)
       (activate-mark)
       (should (null (gptel-org--rewrite-request-system)))
       (should (string= "previous" gptel--system-message))
       (should (string= "Rewrite instruction."
                        (gptel-org--rewrite-system-for-display)))))))

(ert-deftest gptel-org-system-section-rewrite-ignores-stale-region ()
  "A pending rewrite overlay wins over an unrelated active region."
  (gptel-org-system-section--with-org-buffer
   (concat "#+begin_src emacs-lisp\n(defun foo () 1)\n#+end_src\n\n* System\n"
           (gptel-org-system-section--section "Be helpful."))
   (lambda ()
     (setq gptel--rewrite-directive "Rewrite instruction.")
     (goto-char (save-excursion (search-forward "emacs-lisp") (point)))
     (let ((ov (make-overlay (point) (progn (search-forward "#+end_src") (point)))))
       (overlay-put ov 'gptel-rewrite "old response")
       (goto-char (point-min))
       (push-mark (point-max) t)
       (goto-char (overlay-start ov))
       (activate-mark)
       (should (string= "Be helpful.\n\nRewrite instruction."
                        (gptel-org--rewrite-request-system)))
       (delete-overlay ov)))))

(ert-deftest gptel-org-system-section-rewrite-no-section-uses-directive ()
  "Without a section, rewrite uses only `gptel--rewrite-directive'."
  (gptel-org-system-section--with-org-buffer
   "#+begin_src emacs-lisp\n(defun foo () 1)\n#+end_src\n"
   (lambda ()
     (setq gptel--rewrite-directive "Rewrite instruction.")
     (goto-char (point-min))
     (should (null (gptel-org--rewrite-request-system)))
     (should (string= "Rewrite instruction."
                      (gptel-org--rewrite-system-for-display))))))

(ert-deftest gptel-org-system-section-rewrite-point-in-section-uses-directive ()
  "Point inside the section falls back to the directive, no error."
  (gptel-org-system-section--with-org-buffer
   (concat "#+begin_src emacs-lisp\n(defun foo () 1)\n#+end_src\n\n* System\n"
           (gptel-org-system-section--section "Be helpful."))
   (lambda ()
     (setq gptel--rewrite-directive "Rewrite instruction.")
     (goto-char (car (gptel-org--system-section-bounds)))
     (should (null (gptel-org--rewrite-request-system)))
     (should (string= "Rewrite instruction."
                      (gptel-org--rewrite-system-for-display))))))

(ert-deftest gptel-org-system-section-rewrite-ui-effective-directive ()
  "The rewrite UI helper shows the section in Org and falls back otherwise.
This guards the minibuffer/transient surfaces against drifting apart."
  (skip-unless (fboundp 'gptel-rewrite--effective-directive))
  (gptel-org-system-section--with-org-buffer
   (concat "#+begin_src emacs-lisp\n(defun foo () 1)\n#+end_src\n\n* System\n"
           (gptel-org-system-section--section "Be helpful."))
   (lambda ()
     (setq gptel--rewrite-directive "Rewrite instruction.")
     ;; Point above the section: helper includes the section.
     (goto-char (save-excursion (search-forward "emacs-lisp") (point)))
     (should (string= (gptel-org--rewrite-system-for-display)
                      (gptel-rewrite--effective-directive)))
     (should (string-prefix-p "Be helpful."
                              (gptel-rewrite--effective-directive)))
     ;; Region overlapping the section: helper falls back to the directive.
     (goto-char (point-min))
     (push-mark (point-max) t)
     (activate-mark)
     (should (string= "Rewrite instruction."
                      (gptel-rewrite--effective-directive))))))

(ert-deftest gptel-org-system-section-rewrite-read-message-shows-section ()
  "The actual rewrite minibuffer path must surface the section, not only
`gptel--rewrite-directive'.  This drives `gptel--rewrite-read-message' end to
end (with the minibuffer mocked) so a regression in that function is caught."
  (skip-unless (fboundp 'gptel--rewrite-read-message))
  (gptel-org-system-section--with-org-buffer
   (concat "#+begin_src emacs-lisp\n(defun foo () 1)\n#+end_src\n\n* System\n"
           (gptel-org-system-section--section "Be helpful."))
   (lambda ()
     (setq gptel--rewrite-directive "Rewrite instruction.")
     (goto-char (save-excursion (search-forward "emacs-lisp") (point)))
     (let ((captured nil))
       (cl-letf (((symbol-function 'gptel--read-with-prefix)
                  (lambda (directive &rest _) (setq captured directive)))
                 ((symbol-function 'read-string)
                  (lambda (&rest _) (run-hooks 'minibuffer-setup-hook) "")))
         (gptel--rewrite-read-message "Instructions: "))
       (should captured)
       (should (string-prefix-p "Be helpful." captured))
       (should (string-search "Rewrite instruction." captured))))))

(ert-deftest gptel-org-system-section-rewrite-advice-fallback-keeps-system ()
  "The request advice keeps :system during a rewrite without usable section.
Point inside the section must not raise an error in this path."
  (gptel-org-system-section--with-org-buffer
   (concat "#+begin_src emacs-lisp\n(defun foo () 1)\n#+end_src\n\n* System\n"
           (gptel-org-system-section--section "Be helpful."))
   (lambda ()
     (goto-char (car (gptel-org--system-section-bounds)))
     (let* ((gptel-org--in-rewrite t)
            (gptel-org--rewrite-merged-system nil)
            (captured nil)
            (orig (lambda (_prompt &rest args) (setq captured args))))
       (gptel-org--request-with-system-section
        orig nil :system "Rewrite instruction.")
       (should (string= "Rewrite instruction."
                        (plist-get captured :system)))))))

(defconst gptel-org-system-section--test-names
  '(gptel-org-system-section-bounds
    gptel-org-system-section-message-text
    gptel-org-system-section-prompt-excludes-section
    gptel-org-system-section-send-system
    gptel-org-system-section-cursor-inside-errors
    gptel-org-system-section-region-overlap-errors
    gptel-org-system-section-overrides-heading-property
    gptel-org-system-section-save-preserves-local-variables-trailer
    gptel-org-system-section-save-deletes-stale-gptel-system
    gptel-org-system-section-restore-prefers-section
    gptel-org-system-section-last-section-wins
    gptel-org-system-section-nested-outline-ok
    gptel-org-system-section-bounds-cached
    gptel-org-system-section-text-after-end-ignored
    gptel-org-system-section-text-after-end-allowed
    gptel-org-system-section-missing-end-ignored
    gptel-org-system-section-missing-begin-ignored
    gptel-org-system-section-begin-after-end-ignored
    gptel-org-system-section-comment-markers-hash
    gptel-org-system-section-comment-markers-semicolon
    gptel-org-system-section-rewrite-system-combined
    gptel-org-system-section-rewrite-display-preview
    gptel-org-system-section-rewrite-region-overlap-skips-section
    gptel-org-system-section-rewrite-ignores-stale-region
    gptel-org-system-section-rewrite-no-section-uses-directive
    gptel-org-system-section-rewrite-point-in-section-uses-directive
    gptel-org-system-section-rewrite-ui-effective-directive
    gptel-org-system-section-rewrite-read-message-shows-section
    gptel-org-system-section-rewrite-advice-fallback-keeps-system)
  "Names of all system-section ERT tests in this file.")

;;;###autoload
(defun gptel-org-system-section-test-run ()
  "Run system-section tests and exit with an appropriate status."
  (ert-run-tests-batch-and-exit `(member ,@gptel-org-system-section--test-names)))

(provide 'gptel-org-system-section-tests)

;;; gptel-org-system-section-tests.el ends here
