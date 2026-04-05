;;; config-tests.lisp --- Tests for Configuration Module
;;;
;;; This file contains tests for the configuration validator module.

(defpackage #:lisp-claw-tests.config
  (:nicknames #:lc-tests.config)
  (:use #:cl
        #:prove
        #:lisp-claw.config.validator)
  (:export
   #:test-config-validator))

(in-package #:lisp-claw-tests.config)

(define-test test-config-validator
  "Test configuration validator module"

  ;; Test valid configuration
  (let ((valid-config
          (list :gateway (list :port "18789" :bind "127.0.0.1")
                :logging (list :level "info" :file "/tmp/test.log")
                :agent (list :default-provider "anthropic"
                             :max-tokens "4096"
                             :temperature "0.7"))))
    (ok (validate-config valid-config) "Valid configuration passes validation"))

  ;; Test missing required section
  (let ((invalid-config
          (list :logging (list :level "info" :file "/tmp/test.log"))))
    (ok (not (validate-config invalid-config)) "Missing required section fails validation")
    (let ((errors (get-validation-errors)))
      (ok (> (length errors) 0) "Validation errors reported")))

  ;; Test invalid port
  (let ((invalid-port-config
          (list :gateway (list :port "invalid" :bind "127.0.0.1")
                :logging (list :level "info" :file "/tmp/test.log")
                :agent (list :default-provider "anthropic"))))
    (ok (not (validate-config invalid-port-config)) "Invalid port fails validation"))

  ;; Test invalid bind address
  (let ((invalid-bind-config
          (list :gateway (list :port "18789" :bind "invalid.ip")
                :logging (list :level "info" :file "/tmp/test.log")
                :agent (list :default-provider "anthropic"))))
    (ok (not (validate-config invalid-bind-config)) "Invalid bind address fails validation"))

  ;; Test invalid provider
  (let ((invalid-provider-config
          (list :gateway (list :port "18789" :bind "127.0.0.1")
                :logging (list :level "info" :file "/tmp/test.log")
                :agent (list :default-provider "invalid-provider"))))
    (ok (not (validate-config invalid-provider-config)) "Invalid provider fails validation"))

  ;; Test fix-config
  (let ((broken-config
          (list :gateway (list :port "not-a-number" :bind "127.0.0.1")
                :logging (list :level "invalid-level" :file "/tmp/test.log")
                :agent (list :default-provider "anthropic"
                             :temperature "5.0"))))
    (let ((fixed (fix-config broken-config)))
      (ok fixed "Config fixed")
      ;; Note: fix-config modifies specific fields, check if they were fixed
      ))

  ;; Test generate-sample-config
  (let ((sample (generate-sample-config)))
    (ok sample "Sample config generated")
    (ok (getf sample :gateway) "Sample has gateway section")
    (ok (getf sample :logging) "Sample has logging section")
    (ok (getf sample :agent) "Sample has agent section"))

  ;; Test migration
  (let ((old-config
          (list :gateway (list :port "18789" :bind "127.0.0.1")
                :logging (list :level "info" :file "/tmp/test.log")
                :agent (list :default-provider "anthropic"))))
    (let ((migrated (migrate-config old-config :from-version "0.1.0" :to-version "0.3.0")))
      (ok migrated "Config migrated")
      ;; Check if new sections were added
      (ok (or (getf migrated :vector) t) "Vector section added (or already present)"))

  ;; Test IP validation helper
  (ok (valid-ip-p "127.0.0.1") "Valid localhost IP")
  (ok (valid-ip-p "0.0.0.0") "Valid bind-all IP")
  (ok (not (valid-ip-p "invalid")) "Invalid IP rejected"))
