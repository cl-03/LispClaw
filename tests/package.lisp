;;; package.lisp --- Lisp-Claw Tests Package
;;;
;;; This file defines the test package for Lisp-Claw.

(defpackage #:lisp-claw-tests
  (:nicknames #:lc-tests)
  (:use #:cl
        #:prove)
  (:export
   #:test-gateway
   #:test-protocol
   #:test-tools
   #:test-channels
   #:test-automation
   #:run-all-tests))
