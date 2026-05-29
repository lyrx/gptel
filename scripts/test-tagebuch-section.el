;;; test-tagebuch-section.el --- Smoke test for Tagebuch.org section markers  -*- lexical-binding: t -*-

(require 'org)
(require 'gptel-request)
(require 'gptel-org)

(defvar test-tagebuch-section--file
  "/run/user/1000/gvfs/smb-share:server=nas-tailscale.glip.market,share=home/exicloud/Privat/media/org/Tagebuch.org")

(defun test-tagebuch-section-run ()
  "Load Tagebuch.org and verify system-section detection."
  (unless (file-readable-p test-tagebuch-section--file)
    (error "Cannot read %s" test-tagebuch-section--file))
  (with-current-buffer (find-file-noselect test-tagebuch-section--file)
    (setq gptel-org--system-section-cache nil)
    (goto-char (save-excursion
                 (goto-char (point-min))
                 (search-forward "Nochn Versuch")
                 (forward-line 1)
                 (point)))
    (let ((bounds (gptel-org--system-section-bounds))
          (msg (gptel-org--system-section-message))
          (applied nil))
      (unless bounds
        (error "No system section bounds (check begin/end markers and EOF)"))
      (unless (string-match-p "wacher Begleiter für Tagebuch" msg)
        (error "Unexpected system message: %s" msg))
      (when (string-match-p "Nochn Versuch" msg)
        (error "Chat text leaked into system message"))
      (unless (gptel-org--apply-buffer-system-message)
        (error "apply-buffer-system-message returned nil"))
      (unless (string-match-p "wacher Begleiter" gptel--system-message)
        (error "gptel--system-message not set from section: %s"
                gptel--system-message))
      (setq applied t)
      (message "OK Tagebuch.org: bounds=%S message=%d chars apply=%s"
               bounds (length msg) applied)
      (kill-emacs 0))))

(test-tagebuch-section-run)

;;; test-tagebuch-section.el ends here
