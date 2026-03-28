;;; test-runner.lisp --- Lisp-Claw Test Runner
;;;
;;; This file loads Lisp-Claw and runs all tests.
;;; Usage: sbcl --load test-runner.lisp

(setf *standard-output* (make-synonym-stream '*terminal-io*))
(setf *error-output* (make-synonym-stream '*terminal-io*))

(format t "~%")
(format t "========================================~%")
(format t "Lisp-Claw Test Suite~%")
(format t "========================================~%")
(format t "~%")

(format t "SBCL Version: ~A~%" (lisp-implementation-version))
(format t "Platform: ~A~%" (machine-type))
(format t "~%")

;; Load Quicklisp
(format t "Loading Quicklisp...~%")
(handler-case
    (load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
  (error (e)
    (format t "ERROR: Quicklisp not found. Please install Quicklisp first.~%")
    (format t "Error: ~A~%" e)
    (finish-output)
    (sb-ext:exit :code 1)))

;; Add project to ASDF registry
(push #p"D:/Claude/LISP-Claw/LISP-Claw/" asdf:*central-registry*)

;; Load Lisp-Claw
(format t "Loading Lisp-Claw...~%")
(handler-case
    (ql:quickload :lisp-claw :verbose t)
  (error (e)
    (format t "ERROR: Failed to load Lisp-Claw.~%")
    (format t "Error: ~A~%" e)
    (finish-output)
    (sb-ext:exit :code 1)))

(format t "~%")
(format t "========================================~%")
(format t "Running Tests...~%")
(format t "========================================~%")
(format t "~%")

;; Run tests
(handler-case
    (progn
      (ql:quickload :lisp-claw-tests)
      (asdf:test-system :lisp-claw)
      (format t "~%")
      (format t "========================================~%")
      (format t "All Tests Passed!~%")
      (format t "========================================~%"))
  (error (e)
    (format t "~%")
    (format t "========================================~%")
    (format t "Test Failure~%")
    (format t "========================================~%")
    (format t "Error: ~A~%" e)
    (finish-output)
    (sb-ext:exit :code 1)))

(finish-output)
(sb-ext:exit :code 0)
