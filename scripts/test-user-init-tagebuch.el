;;; test-user-init-tagebuch.el -*- lexical-binding: t -*-
(load-file "/home/alex/.emacs.d/lisp/gptel-init.el")
(let ((debug-on-error t))
  (find-file "/run/user/1000/gvfs/smb-share:server=nas-tailscale.glip.market,share=home/exicloud/Privat/media/org/Tagebuch.org")
  (princ (format "OK major=%S gptel-mode=%S\n" major-mode gptel-mode)))
