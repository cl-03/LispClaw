;;; parse-asd.lisp --- Parse and validate ASDF file

(format t "Parsing ASDF file...~%")

(let* ((path #p"D:/Claude/LISP-Claw/LISP-Claw/lisp-claw.asd")
       (content (with-open-file (s path)
                  (let ((all-content (make-string (file-length s))))
                    (read-sequence all-content s)
                    all-content))))

  (format t "File content length: ~A~%" (length content))

  ;; Try to read the first form
  (let ((form (read-from-string content)))
    (format t "Form type: ~A~%" (type-of form))
    (format t "Form car: ~A~%" (car form))
    (format t "Form length: ~A~%" (length form))

    ;; Check keyword arguments
    (let ((args (cddr form)))
      (format t "Arguments count: ~A~%" (length args))
      (loop for arg in args
            for i from 1
            do (format t "  ~A: ~A (~A)~%" i arg (type-of arg)))))

  (finish-output))

(sb-ext:quit)
