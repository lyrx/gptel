;;; test-open-tagebuch-full.el -*- lexical-binding: t -*-
(require 'gptel)
(require 'gptel-transient)
(require 'gptel-openai)
(setq gptel-backend (gptel-make-openai "Moonshot"
                      :host "api.moonshot.ai"
                      :key "test"
                      :models '(kimi-k2.6)))
(let ((debug-on-error t)
      (f "/run/user/1000/gvfs/smb-share:server=nas-tailscale.glip.market,share=home/exicloud/Privat/media/org/Tagebuch.org"))
  (find-file f)
  (princ (format "opened major=%S\n" major-mode))
  (princ (format "local gptel--bounds=%S\n" gptel--bounds))
  (princ (format "local gptel-model=%S\n" gptel-model))
  (gptel-mode 1)
  (princ (format "gptel-mode=%S system-len=%d\n"
                 gptel-mode (length (or gptel--system-message "")))))
