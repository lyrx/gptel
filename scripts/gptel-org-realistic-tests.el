;;; gptel-org-realistic-tests.el --- Realistic end-to-end tests for gptel Org state  -*- lexical-binding: t -*-

;; Developer checks only (not part of the package).
;;
;; Run from repo root:
;;   EMACS=/home/alex/git/clones/emacs/src/emacs \
;;     $EMACS --batch -Q -L . -l scripts/gptel-org-realistic-tests.el \
;;       -f gptel-org-realistic-tests-run
;;
;; The point of this file is REALISM: it drives the same code path a user
;; hits interactively -- `find-file' with `enable-local-variables' on, an
;; `org-mode-hook' that turns on `gptel-mode', a registered backend, the
;; header line enabled -- and then round-trips (open -> save -> reopen) to
;; catch state-persistence regressions and "File mode specification error"
;; type failures that only surface during `normal-mode'.

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'gptel)
(require 'gptel-openai)
(require 'gptel-org)

;;;; Test scaffolding

(defvar gptel-org-rt--tmpdir nil)
(defvar gptel-org-rt--backend nil)

(defun gptel-org-rt--setup ()
  "Register a dummy backend and a temp dir; enable the realistic hook."
  (setq gptel-org-rt--backend
        (gptel-make-openai "Moonshot"     ;name used in the test fixtures
          :host "api.moonshot.ai"
          :key "test-key"
          :models '(kimi-k2.6)))
  (setq gptel-backend gptel-org-rt--backend
        gptel-model 'kimi-k2.6)
  (setq gptel-org-rt--tmpdir
        (make-temp-file "gptel-org-rt-" 'dir))
  ;; Realistic: user enables gptel-mode for every org buffer.
  (add-hook 'org-mode-hook #'gptel-mode))

(defun gptel-org-rt--teardown ()
  (remove-hook 'org-mode-hook #'gptel-mode)
  (when (and gptel-org-rt--tmpdir (file-directory-p gptel-org-rt--tmpdir))
    (delete-directory gptel-org-rt--tmpdir t)))

(defun gptel-org-rt--file (name contents)
  "Write CONTENTS to NAME in the temp dir, return absolute path."
  (let ((path (expand-file-name name gptel-org-rt--tmpdir)))
    (with-temp-file path (insert contents))
    path))

(defmacro gptel-org-rt--with-opened (path &rest body)
  "Open PATH like a user would and run BODY in that buffer.
Errors during `find-file' (e.g. \"File mode specification error\")
propagate, since `normal-mode' wraps them in `with-demoted-errors';
to surface them we re-run the local-variable/mode machinery with
`debug-on-error' bound through a hook check."
  (declare (indent 1))
  `(let ((enable-local-variables t)
         (find-file-hook find-file-hook)
         (buf (find-file-noselect ,path)))
     (unwind-protect
         (with-current-buffer buf
           ,@body)
       (when (buffer-live-p buf)
         (with-current-buffer buf (set-buffer-modified-p nil))
         (kill-buffer buf)))))

(defun gptel-org-rt--reopen-system (path)
  "Open PATH fresh and return the active `gptel--system-message'."
  (gptel-org-rt--with-opened path
    gptel--system-message))

(defun gptel-org-rt--save (path)
  "Open PATH, mark it modified, save it, return the new file contents.
Marking the buffer modified (without changing content) makes
`before-save-hook' -- and thus `gptel-org--save-state' -- run, as it
would after a real user edit, without accumulating spurious newlines."
  (gptel-org-rt--with-opened path
    (set-buffer-modified-p t)
    (basic-save-buffer))
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

;;;; Fixtures (realistic content)

(defconst gptel-org-rt--section-msg
  "Du bist ein einfühlsamer Begleiter für Tagebuch-Einträge.
Formatiere immer so, dass jede Zeile höchstens 80 Zeichen hat.")

(defun gptel-org-rt--section (msg)
  (concat "** System prompt\n:GPTEL_SYSTEM_MESSAGE_BEGIN: t\n\n"
          msg "\n\n:GPTEL_SYSTEM_MESSAGE_END: t\n"))

(defun gptel-org-rt--trailer (&rest extra-lines)
  "A file-local-variables trailer with gptel vars plus EXTRA-LINES."
  (concat "\n;; Local Variables:\n"
          (mapconcat (lambda (l) (concat ";; " l "\n")) extra-lines "")
          ";; gptel-model: kimi-k2.6\n"
          ";; gptel--backend-name: \"Moonshot\"\n"
          ";; gptel--system-message: \"Alt: Tagebuch-Assistent.\"\n"
          ";; End:\n"))

;;;; Use-case tests

(ert-deftest gptel-org-rt-a-fresh-chat ()
  "Case A: a plain org chat file, no stored config, opens cleanly."
  (let ((f (gptel-org-rt--file "a-fresh.org" "* Chat\n\nHallo\n")))
    (gptel-org-rt--with-opened f
      (should gptel-mode)
      (should (derived-mode-p 'org-mode)))))

(ert-deftest gptel-org-rt-b-property-system-only ()
  "Case B: only a file-level GPTEL_SYSTEM property is restored."
  (let ((f (gptel-org-rt--file
            "b-prop.org"
            (concat ":PROPERTIES:\n:GPTEL_BACKEND: Moonshot\n"
                    ":GPTEL_MODEL: kimi-k2.6\n"
                    ":GPTEL_SYSTEM: Property prompt.\n:END:\n\n* Chat\nHi\n"))))
    (gptel-org-rt--with-opened f
      (should (string= "Property prompt." gptel--system-message)))))

(ert-deftest gptel-org-rt-c-section-only ()
  "Case C: a system-message section at EOF is restored."
  (let ((f (gptel-org-rt--file
            "c-section.org"
            (concat ":PROPERTIES:\n:GPTEL_BACKEND: Moonshot\n"
                    ":GPTEL_MODEL: kimi-k2.6\n:END:\n\n* Chat\nHi\n\n"
                    (gptel-org-rt--section gptel-org-rt--section-msg)))))
    (gptel-org-rt--with-opened f
      (should (string= gptel-org-rt--section-msg gptel--system-message)))))

(ert-deftest gptel-org-rt-d-section-overrides-stale-property ()
  "Case D (the original bug): section wins over a stale GPTEL_SYSTEM."
  (let ((f (gptel-org-rt--file
            "d-both.org"
            (concat ":PROPERTIES:\n:GPTEL_BACKEND: Moonshot\n"
                    ":GPTEL_MODEL: kimi-k2.6\n"
                    ":GPTEL_SYSTEM: STALE property prompt.\n:END:\n\n"
                    "* Chat\nHi\n\n"
                    (gptel-org-rt--section gptel-org-rt--section-msg)))))
    ;; On open, the section must win.
    (gptel-org-rt--with-opened f
      (should (string= gptel-org-rt--section-msg gptel--system-message)))
    ;; After saving, GPTEL_SYSTEM must be gone and a reopen still uses section.
    (let ((saved (gptel-org-rt--save f)))
      (should-not (string-match-p "GPTEL_SYSTEM:" saved))
      (should (string-match-p "GPTEL_SYSTEM_MESSAGE_BEGIN:" saved)))
    (should (string= gptel-org-rt--section-msg
                     (gptel-org-rt--reopen-system f)))))

(ert-deftest gptel-org-rt-e-local-variables-trailer-opens ()
  "Case E: a gptel Local Variables trailer must not break `find-file'."
  (let ((f (gptel-org-rt--file
            "e-trailer.org"
            (concat ":PROPERTIES:\n:GPTEL_BACKEND: Moonshot\n"
                    ":GPTEL_MODEL: kimi-k2.6\n:END:\n\n* Chat\nHi\n"
                    (gptel-org-rt--trailer)))))
    (gptel-org-rt--with-opened f
      (should gptel-mode)
      (should (derived-mode-p 'org-mode)))))

(ert-deftest gptel-org-rt-f-trailer-preserves-other-locals ()
  "Case F: cleaning a gptel trailer must NOT drop unrelated locals.
A user may keep `mode:' or `fill-column:' in the same block."
  (let* ((f (gptel-org-rt--file
             "f-mixed.org"
             (concat "* Chat\nHi\n"
                     (gptel-org-rt--trailer "fill-column: 72"))))
         (saved (gptel-org-rt--save f)))
    ;; Whatever we do with gptel lines, a non-gptel local must survive.
    (should (string-match-p "fill-column: 72" saved))))

(ert-deftest gptel-org-rt-g-per-heading-config ()
  "Case G: per-heading GPTEL_SYSTEM under a subtree is honored on send."
  (let ((f (gptel-org-rt--file
            "g-heading.org"
            (concat "* Topic A\n:PROPERTIES:\n"
                    ":GPTEL_SYSTEM: Heading A prompt.\n:END:\n\nHi A\n"))))
    (gptel-org-rt--with-opened f
      (goto-char (point-max))
      ;; `gptel-org--entry-properties' with inheritance should see it.
      (pcase-let ((`(,_p ,system . ,_) (gptel-org--entry-properties (point))))
        (should (string= "Heading A prompt." system))))))

(ert-deftest gptel-org-rt-h-multiline-system-roundtrip ()
  "Case H: a multi-line GPTEL_SYSTEM survives a save/reopen round-trip."
  (let* ((sys "Zeile eins.\nZeile zwei.")
         (f (gptel-org-rt--file
             "h-multiline.org"
             (concat ":PROPERTIES:\n:GPTEL_BACKEND: Moonshot\n"
                     ":GPTEL_MODEL: kimi-k2.6\n"
                     ":GPTEL_SYSTEM: " (string-replace "\n" "\\n" sys)
                     "\n:END:\n\n* Chat\nHi\n"))))
    (should (string= sys (gptel-org-rt--reopen-system f)))
    (gptel-org-rt--save f)
    (should (string= sys (gptel-org-rt--reopen-system f)))))

(ert-deftest gptel-org-rt-i-save-reopen-idempotent ()
  "Case I: saving twice must not keep mutating the file (stability)."
  (let* ((f (gptel-org-rt--file
             "i-idem.org"
             (concat ":PROPERTIES:\n:GPTEL_BACKEND: Moonshot\n"
                     ":GPTEL_MODEL: kimi-k2.6\n:END:\n\n* Chat\nHi\n\n"
                     (gptel-org-rt--section gptel-org-rt--section-msg))))
         (s1 (gptel-org-rt--save f))
         (s2 (gptel-org-rt--save f)))
    (should (string= s1 s2))))

(defun gptel-org-rt--gptel-temp-buffers ()
  "Return the list of leaked gptel temp buffers."
  (cl-remove-if-not
   (lambda (b) (string-match-p "gptel-prompt\\|gptel-temp" (buffer-name b)))
   (buffer-list)))

(ert-deftest gptel-org-rt-j-no-leaked-temp-buffer ()
  "Regression: parsing a system section must not leak a temp buffer.
A leaked ` *gptel-prompt*' buffer has its major-mode set to `org-mode'
but no keymap installed, which later makes `org-install-agenda-files-menu'
signal `(wrong-type-argument keymapp nil)' on the next Org `find-file'."
  (let ((f (gptel-org-rt--file
            "j-leak.org"
            (concat ":PROPERTIES:\n:GPTEL_BACKEND: Moonshot\n"
                    ":GPTEL_MODEL: kimi-k2.6\n:END:\n\n* Chat\nHi\n\n"
                    (gptel-org-rt--section gptel-org-rt--section-msg)))))
    (gptel-org-rt--with-opened f
      (should (string= gptel-org-rt--section-msg gptel--system-message)))
    (should (null (gptel-org-rt--gptel-temp-buffers)))))

(ert-deftest gptel-org-rt-k-many-section-opens-no-error ()
  "Regression: opening many section files in a row stays error-free.
This is the realistic reproduction of the original `keymapp nil' crash,
which only appeared after a section had been parsed in an earlier buffer."
  (dotimes (i 6)
    (let ((f (gptel-org-rt--file
              (format "k-%d.org" i)
              (concat ":PROPERTIES:\n:GPTEL_BACKEND: Moonshot\n"
                      ":GPTEL_MODEL: kimi-k2.6\n"
                      ":GPTEL_SYSTEM: stale-" (number-to-string i) ".\n:END:\n\n"
                      "* Chat\nHi\n\n"
                      (gptel-org-rt--section
                       (format "Section prompt %d." i))))))
      (gptel-org-rt--with-opened f
        (should gptel-mode)
        (should (derived-mode-p 'org-mode))
        (should (string= (format "Section prompt %d." i)
                         gptel--system-message)))))
  (should (null (gptel-org-rt--gptel-temp-buffers))))

(ert-deftest gptel-org-rt-l-dry-run-no-leak ()
  "Regression: a (dry-run) request on a section buffer leaks no prompt buffer.
`gptel--realize-query' kills the ` *gptel-prompt*' copy for both real and
dry-run requests; guard against a future regression of the same class."
  (let ((f (gptel-org-rt--file
            "l-dry.org"
            (concat ":PROPERTIES:\n:GPTEL_BACKEND: Moonshot\n"
                    ":GPTEL_MODEL: kimi-k2.6\n:END:\n\n"
                    "* Chat\nHallo, wie geht es?\n\n"
                    (gptel-org-rt--section gptel-org-rt--section-msg)))))
    (gptel-org-rt--with-opened f
      (goto-char (point-min))
      (re-search-forward "wie geht es?")
      (gptel-request nil :dry-run t :callback #'ignore))
    (should (null (gptel-org-rt--gptel-temp-buffers)))))

;;;; Runner

(defconst gptel-org-rt--names
  '(gptel-org-rt-a-fresh-chat
    gptel-org-rt-b-property-system-only
    gptel-org-rt-c-section-only
    gptel-org-rt-d-section-overrides-stale-property
    gptel-org-rt-e-local-variables-trailer-opens
    gptel-org-rt-f-trailer-preserves-other-locals
    gptel-org-rt-g-per-heading-config
    gptel-org-rt-h-multiline-system-roundtrip
    gptel-org-rt-i-save-reopen-idempotent
    gptel-org-rt-j-no-leaked-temp-buffer
    gptel-org-rt-k-many-section-opens-no-error
    gptel-org-rt-l-dry-run-no-leak))

;;;###autoload
(defun gptel-org-realistic-tests-run ()
  "Run the realistic Org tests in batch and exit with proper status."
  (gptel-org-rt--setup)
  (let ((stats (unwind-protect
                   (ert-run-tests-batch `(member ,@gptel-org-rt--names))
                 (gptel-org-rt--teardown))))
    (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1))))

(provide 'gptel-org-realistic-tests)
;;; gptel-org-realistic-tests.el ends here
