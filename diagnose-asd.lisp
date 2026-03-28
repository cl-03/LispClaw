;;; diagnose-asd.lisp --- Diagnose ASDF file

(in-package :cl-user)

(defun check-asd-file ()
  (format t "Reading ASDF file...~%")
  (let ((form (with-open-file (s "D:/Claude/LISP-Claw/LISP-Claw/lisp-claw.asd")
                (read s))))
    (format t "Form type: ~A~%" (type-of form))
    (format t "Operator: ~A~%" (first form))
    (format t "System name: ~A~%" (second form))
    (format t "Arguments:~%")
    (let ((args (cddr form)))
      (loop for arg in args
            for i from 1
            do (format t "  ~A: ~A~%" i
                       (if (keywordp (first arg))
                           (first arg)
                           (type-of arg))))))
  (finish-output))

(check-asd-file)
(sb-ext:quit)
