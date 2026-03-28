;;; load-system.lisp --- Load Lisp-Claw System
;;;
;;; This file loads the Lisp-Claw system for testing.

(format t "~%========================================~%")
(format t "Loading Lisp-Claw System~%")
(format t "========================================~%~%")

(format t "SBCL Version: ~A~%~%" (lisp-implementation-version))

;; Initialize ASDF source registry
(format t "Initializing ASDF source registry...~%")
(asdf:initialize-source-registry '(:source-registry (:tree #p"D:/Claude/LISP-Claw/LISP-Claw/") :inherit-configuration))

(format t "Loading Lisp-Claw system...~%")
(handler-case
    (progn
      (asdf:load-system :lisp-claw :verbose t)
      (format t "~%========================================~%")
      (format t "Lisp-Claw loaded successfully!~%")
      (format t "========================================~%"))
  (error (e)
    (format t "~%========================================~%")
    (format t "ERROR: Failed to load Lisp-Claw~%")
    (format t "========================================~%")
    (format t "Error: ~A~%" e)
    (finish-output)
    (sb-ext:exit :code 1)))

(finish-output)
