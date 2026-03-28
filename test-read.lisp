;;; test-read.lisp --- Test reading package.lisp

(setf *default-pathname-defaults* #p"D:/Claude/LISP-Claw/LISP-Claw/")

(format t "Current directory: ~A~%~%" *default-pathname-defaults*)

(handler-case
    (with-open-file (s "package.lisp"
                       :direction :input
                       :external-format :utf-8)
      (format t "File opened successfully~%")

      ;; Try to read first form
      (let ((form (read s nil 'eof)))
        (format t "First form read successfully: ~S~%" form)))
  (error (c)
    (format t "ERROR: ~A~%" c)
    (finish-output)
    (sb-ext:quit :code 1)))

(finish-output)
(sb-ext:quit)
