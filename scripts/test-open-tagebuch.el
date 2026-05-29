;;; test-open-tagebuch.el -*- lexical-binding: t -*-
(require 'gptel)
(let ((f "/run/user/1000/gvfs/smb-share:server=nas-tailscale.glip.market,share=home/exicloud/Privat/media/org/Tagebuch.org"))
  (unless (file-readable-p f) (error "unreadable: %s" f))
  (condition-case err
      (progn
        (find-file f)
        (princ (format "OK major=%S gptel-model=%S\n" major-mode gptel-model)))
    (error (princ (format "ERR: %S\n" err)))))
