;;; gptel-org-system-subtree-tests.el --- Tests for Org system-message subtree  -*- lexical-binding: t -*-

(require 'ert)
(require 'org)
(require 'gptel-request)
(require 'gptel-org)

(defvar gptel-org-system-subtree--test-buffer nil
  "Shared Org buffer for subtree tests (org-mode only initialized once).")

(defun gptel-org-system-subtree--with-org-buffer (contents fn)
  "Run FN in an Org buffer containing CONTENTS."
  (unless gptel-org-system-subtree--test-buffer
    (setq gptel-org-system-subtree--test-buffer
          (generate-new-buffer " *gptel-org-system-subtree-test*"))
    (with-current-buffer gptel-org-system-subtree--test-buffer
      (let ((org-mode-hook nil))
        (org-mode))))
  (with-current-buffer gptel-org-system-subtree--test-buffer
    (erase-buffer)
    (insert contents)
    (goto-char (point-min))
    (funcall fn)))

(ert-deftest gptel-org-system-subtree-bounds-at-eof ()
  (gptel-org-system-subtree--with-org-buffer
   "* Chat\n\n** User\nHi\n\n* System\n:GPTEL_SYSTEM_MESSAGE_SUBTREE: t\nBe helpful.\n"
   (lambda ()
     (let ((bounds (gptel-org--system-subtree-bounds)))
       (should bounds)
       (save-excursion
         (goto-char (car bounds))
         (should (looking-at "\\* System")))))))

(ert-deftest gptel-org-system-subtree-message-text ()
  (gptel-org-system-subtree--with-org-buffer
   "* Chat\n\n** User\nHi\n\n* System\n:GPTEL_SYSTEM_MESSAGE_SUBTREE: t\nBe helpful.\n"
   (lambda ()
     (should (string= "Be helpful."
                      (gptel-org--system-subtree-message))))))

(ert-deftest gptel-org-system-subtree-prompt-excludes-subtree ()
  (gptel-org-system-subtree--with-org-buffer
   "* Chat\n\n** User\nHi\n\n* System\n:GPTEL_SYSTEM_MESSAGE_SUBTREE: t\nBe helpful.\n"
   (lambda ()
     (goto-char (save-excursion
                  (goto-char (point-min))
                  (search-forward "Hi\n")
                  (point)))
     (let ((prompt (gptel-org--create-prompt-buffer)))
       (unwind-protect
           (with-current-buffer prompt
             (should (not (string-match-p "Be helpful" (buffer-string)))))
         (kill-buffer prompt))))))

(ert-deftest gptel-org-system-subtree-send-system ()
  (gptel-org-system-subtree--with-org-buffer
   "* Chat\n\n** User\nHi\n\n* System\n:GPTEL_SYSTEM_MESSAGE_SUBTREE: t\nBe helpful.\n"
   (lambda ()
     (goto-char (save-excursion
                  (goto-char (point-min))
                  (search-forward "Hi")
                  (forward-line 1)
                  (point)))
     (should (string= "Be helpful."
                      (gptel-org--system-subtree-message-for-send))))))

(ert-deftest gptel-org-system-subtree-cursor-inside-errors ()
  (gptel-org-system-subtree--with-org-buffer
   "* Chat\n\n* System\n:GPTEL_SYSTEM_MESSAGE_SUBTREE: t\nBe helpful.\n"
   (lambda ()
     (goto-char (save-excursion
                  (search-forward "Be helpful")))
     (should-error (gptel-org--system-subtree-message-for-send)))))

(ert-deftest gptel-org-system-subtree-overrides-heading-property ()
  (gptel-org-system-subtree--with-org-buffer
   "* Chat\n:GPTEL_SYSTEM: From heading\n\n** User\nHi\n\n* System\n:GPTEL_SYSTEM_MESSAGE_SUBTREE: t\nFrom subtree.\n"
   (lambda ()
     (goto-char (save-excursion
                  (goto-char (point-min))
                  (search-forward "Hi\n")
                  (point)))
     (let ((gptel--system-message "Buffer default"))
       (gptel-org--apply-buffer-system-message)
       (should (string= "From subtree." gptel--system-message))))))

(ert-deftest gptel-org-system-subtree-not-at-eof-ignored ()
  (gptel-org-system-subtree--with-org-buffer
   "* System\n:GPTEL_SYSTEM_MESSAGE_SUBTREE: t\nBe helpful.\n\n* Chat\nHi\n"
   (lambda ()
     (should (null (gptel-org--system-subtree-bounds))))))

;;;###autoload
(defun gptel-org-system-subtree-test-run ()
  "Run system-subtree tests and exit with an appropriate status."
  (ert-run-tests-batch-and-exit
   '(member gptel-org-system-subtree-bounds-at-eof
            gptel-org-system-subtree-message-text
            gptel-org-system-subtree-prompt-excludes-subtree
            gptel-org-system-subtree-send-system
            gptel-org-system-subtree-cursor-inside-errors
            gptel-org-system-subtree-overrides-heading-property
            gptel-org-system-subtree-not-at-eof-ignored)))

(provide 'gptel-org-system-subtree-tests)

;;; gptel-org-system-subtree-tests.el ends here
