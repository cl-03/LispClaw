;;; test-package-read.lisp --- Test reading package.lisp

(format t "Reading package.lisp...~%")

(with-open-file (s "package.lisp" :direction :input)
  (let ((forms '())
        (count 0))
    (loop for form = (read s nil 'eof)
          until (eq form 'eof)
          do (progn
               (incf count)
               (push form forms)
               (format t "Form ~A: ~A~%" count (type-of form))))
    (format t "Total forms read: ~A~%" count)
    (dolist (form (nreverse forms))
      (format t "  Form: ~A~%" (car form)))))

(finish-output)
(sb-ext:quit)
