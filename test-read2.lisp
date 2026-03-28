;;; test-read2.lisp --- Test reading package.lisp step by step

(setf *default-pathname-defaults* #p"D:/Claude/LISP-Claw/LISP-Claw/")

(format t "Testing package.lisp read...~%")

(let ((path "package.lisp"))
  (format t "Path: ~A~%" path)
  (format t "Full path: ~A~%" (merge-pathnames path))

  (with-open-file (s path :direction :input)
    (format t "File opened~%")
    (force-output)

    ;; Read char by char to see where it fails
    (loop for i from 1 to 200
          for ch = (read-char s nil 'eof)
          until (eq ch 'eof)
          do (format t "~A~A" i ch)
          finally (format t "~%Read ~A chars successfully~%" i)))

(finish-output)
(sb-ext:quit)
