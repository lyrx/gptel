;;; test-tagebuch-section-detect.el -*- lexical-binding: t -*-
(require 'org)
(require 'gptel-org)
(with-temp-buffer
  (insert-file-contents "/run/user/1000/gvfs/smb-share:server=nas-tailscale.glip.market,share=home/exicloud/Privat/media/org/Tagebuch.org")
  (org-mode)
  (setq gptel-org--system-section-cache nil)
  (let ((bounds (gptel-org--system-section-bounds))
        (msg (gptel-org--system-section-message)))
    (princ (format "bounds=%S msg-len=%s\n" bounds (and msg (length msg))))
    (when msg
      (princ (format "start=%S\n" (substring msg 0 (min 50 (length msg))))))))
