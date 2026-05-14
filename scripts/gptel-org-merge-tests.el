;;; gptel-org-merge-tests.el --- Batch tests for Org system prompt merge -*- lexical-binding: t -*-

;; Not part of the installed package; developer checks only.
;;
;; From repo root (remove stale `gptel-org.elc' if it is newer than `gptel-org.el'):
;;   emacs -Q --batch -L . -l scripts/gptel-org-merge-tests.el -f gptel-org-merge-tests-run
;;
;; Parent vs current `gptel-org.el' (expects fail then pass; script checks out
;; the parent of the commit that introduced `gptel-org--merge-system-message'):
;;   ./scripts/run-gptel-org-merge-regression.sh
;;
;; Automated tests for gptel also live in the optional submodule `test/'
;; (https://github.com/karthink/gptel-test); this file covers the Org merge fix.

(require 'cl-lib)
(require 'gptel-request)
(require 'gptel-org)

(defun gptel-org-merge-tests--assert (name got expected)
  (unless (equal got expected)
    (error "FAIL %s: got %S expected %S" name got expected))
  (message "PASS %s" name))

(defun gptel-org-merge-tests-run ()
  "Exercise `gptel-org--merge-system-message' and send advice merge."
  (when (fboundp 'gptel-org--merge-system-message)
    (with-temp-buffer
      (org-mode)
      (setq gptel-org--send-system-state nil)
      (gptel-org-merge-tests--assert "first: org wins over different buffer"
        (gptel-org--merge-system-message "org-a" "buf-g") "org-a")
      (unless (and (equal (car gptel-org--send-system-state) "org-a")
                   (equal (cdr gptel-org--send-system-state) "buf-g"))
        (error "FAIL state after first: %S" gptel-org--send-system-state))
      (message "PASS state snapshot after first send")
      (gptel-org-merge-tests--assert "equal canonical strings keep buffer value"
        (gptel-org--merge-system-message "org-a" "org-a") "org-a")
      (gptel-org-merge-tests--assert "buffer-only change uses buffer"
        (gptel-org--merge-system-message "org-a" "buf-new") "buf-new")
      (gptel-org-merge-tests--assert "org-only change uses org"
        (gptel-org--merge-system-message "org-c" "buf-new") "org-c")
      (gptel-org-merge-tests--assert "org changes again while buffer unchanged"
        (gptel-org--merge-system-message "org-d" "buf-new") "org-d")
      (setq gptel-org--send-system-state nil)
      (gptel-org-merge-tests--assert "no GPTEL_SYSTEM uses buffer"
        (gptel-org--merge-system-message nil "only-buf") "only-buf")
      (setq gptel-org--send-system-state nil)
      (gptel-org-merge-tests--assert "no buffer uses org string"
        (gptel-org--merge-system-message "org-only" nil) "org-only")))

  ;; Integration: stub heading props; `gptel-org--send-with-props' must see real
  ;; buffer system before merge (not pre-merged via `or').
  (let (captured)
    (cl-letf (((symbol-function 'gptel-org--entry-properties)
               (lambda (&optional _pt)
                 (list nil "from-org" nil nil nil nil nil nil))))
      (with-temp-buffer
        (org-mode)
        (setq-local gptel--system-message "from-buf")
        (setq-local gptel--preset nil)
        (setq-local gptel-backend nil)
        (setq-local gptel-model nil)
        (setq-local gptel-temperature nil)
        (setq-local gptel-max-tokens nil)
        (setq-local gptel--num-messages-to-send nil)
        (setq-local gptel-tools nil)
        (setq gptel-org--send-system-state nil)
        (gptel-org--send-with-props
         (lambda (&rest _)
           (setq captured gptel--system-message)))
        (gptel-org-merge-tests--assert "send-with-props first org vs buf"
          captured "from-org")))
    (cl-letf (((symbol-function 'gptel-org--entry-properties)
               (lambda (&optional _pt)
                 (list nil "from-org" nil nil nil nil nil nil))))
      (with-temp-buffer
        (org-mode)
        (setq-local gptel--system-message "from-buf")
        (setq-local gptel--preset nil)
        (setq-local gptel-backend nil)
        (setq-local gptel-model nil)
        (setq-local gptel-temperature nil)
        (setq-local gptel-max-tokens nil)
        (setq-local gptel--num-messages-to-send nil)
        (setq-local gptel-tools nil)
        (setq gptel-org--send-system-state nil)
        (gptel-org--send-with-props (lambda (&rest _) nil))
        (setq-local gptel--system-message "edited-buf")
        (gptel-org--send-with-props
         (lambda (&rest _)
           (setq captured gptel--system-message)))
        (gptel-org-merge-tests--assert "send-with-props buffer edit wins"
          captured "edited-buf"))))

  ;; Regression / "negative" control: the pre-fix rule was `(or org-system
  ;; buffer-system)' for the system slot, so a non-nil GPTEL_SYSTEM always
  ;; shadowed `gptel--system-message'.  We assert that plain `or' and a stubbed
  ;; merge reproduce that stale value; the real `gptel-org--merge-system-message'
  ;; must not (see "send-with-props buffer edit wins" above).
  (gptel-org-merge-tests--assert "regression: plain `or' ignores edited buffer"
    (or "from-org" "edited-buf") "from-org")
  (let (captured)
    (cl-letf (((symbol-function 'gptel-org--entry-properties)
               (lambda (&optional _pt)
                 (list nil "from-org" nil nil nil nil nil nil)))
              ((symbol-function 'gptel-org--merge-system-message)
               (lambda (org-system buf-directive)
                 (or org-system buf-directive))))
      (with-temp-buffer
        (org-mode)
        (setq-local gptel--system-message "from-buf")
        (setq-local gptel--preset nil)
        (setq-local gptel-backend nil)
        (setq-local gptel-model nil)
        (setq-local gptel-temperature nil)
        (setq-local gptel-max-tokens nil)
        (setq-local gptel--num-messages-to-send nil)
        (setq-local gptel-tools nil)
        (setq gptel-org--send-system-state nil)
        (gptel-org--send-with-props (lambda (&rest _) nil))
        (setq-local gptel--system-message "edited-buf")
        (gptel-org--send-with-props
         (lambda (&rest _)
           (setq captured gptel--system-message)))
        (gptel-org-merge-tests--assert
            "regression: simulated pre-fix merge still yields stale org (not edited-buf)"
          captured "from-org"))))

  (message "All gptel-org merge tests passed."))

(provide 'gptel-org-merge-tests)
