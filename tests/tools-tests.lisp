;;; tools-tests.lisp --- Tools Tests for Lisp-Claw
;;;
;;; This file contains tests for the Lisp-Claw tools system.

(defpackage #:lisp-claw-tests.tools
  (:nicknames #:lc-tests.tools)
  (:use #:cl
        #:prove
        #:lisp-claw.tools.files
        #:lisp-claw.tools.system)
  (:export #:run-tools-tests))

(in-package #:lisp-claw-tests.tools)

;;; ============================================================================
;;; Run Tools Tests
;;; ============================================================================

(defun run-tools-tests ()
  "Run all tools tests.

  Returns:
    Test results"
  (prove:run
   (subtest "File operations"
     (let* ((test-file #P"/tmp/lisp-claw-test-file.txt")
            (test-content "Hello, Lisp-Claw!"))
       (unwind-protect
            (progn
              (ok (file-write test-file test-content) "File write")
              (let ((content (file-read test-file)))
                (is content test-content "File read"))
              (ok (file-exists-p test-file) "File exists"))
         (when (probe-file test-file)
           (delete-file test-file)))))

   (subtest "File append"
     (let* ((test-file #P"/tmp/lisp-claw-test-append.txt")
            (content1 "Line 1")
            (content2 "Line 2")
            (expected "Line 1Line 2"))
       (unwind-protect
            (progn
              (file-write test-file content1)
              (ok (file-append test-file content2) "Append")
              (let ((content (file-read test-file)))
                (is content expected "Content match")))
         (when (probe-file test-file)
           (delete-file test-file)))))

   (subtest "File delete"
     (let* ((test-file #P"/tmp/lisp-claw-delete.txt"))
       (file-write test-file "to delete")
       (ok (file-exists-p test-file) "Exists before")
       (ok (file-delete test-file) "Delete")
       (ok (not (file-exists-p test-file)) "Not exists after")))

   (subtest "Command exists"
     #+linux
     (progn
       (ok (command-exists-p "ls") "ls")
       (ok (command-exists-p "echo") "echo"))
     #+windows
     (progn
       (ok (command-exists-p "cmd") "cmd")
       (ok (command-exists-p "echo") "echo")))

   (subtest "Current directory"
     (let ((dir (get-current-directory)))
       (ok dir "Not nil")
       (ok (typep dir 'pathname) "Is pathname")))))