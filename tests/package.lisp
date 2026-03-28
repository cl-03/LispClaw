;;; package.lisp --- Lisp-Claw Tests Package
;;;
;;; This file defines the test package for Lisp-Claw.

(defpackage #:lisp-claw-tests
  (:nicknames #:lc-tests)
  (:use #:cl
        #:prove
        #:lisp-claw
        #:lisp-claw.utils.json
        #:lisp-claw.utils.helpers
        #:lisp-claw.gateway.protocol))
