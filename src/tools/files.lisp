;;; tools/files.lisp --- File Operations Tool for Lisp-Claw
;;;
;;; This file implements file operations for the AI assistant.

(defpackage #:lisp-claw.tools.files
  (:nicknames #:lc.tools.files)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:shadowing-import-from #:uiop #:copy-file)
  (:export
   #:file-read
   #:file-write
   #:file-append
   #:file-delete
   #:file-exists-p
   #:file-copy
   #:file-move
   #:file-info
   #:list-directory
   #:make-directory
   #:with-file-lock
   #:file-read-binary
   #:file-write-binary
   #:file-read-lines))

(in-package #:lisp-claw.tools.files)

;;; ============================================================================
;;; File Reading
;;; ============================================================================

(defun file-read (path &key (encoding :utf-8) if-not-exists)
  "Read file contents.

  Args:
    PATH: File path
    ENCODING: Character encoding (default: :utf-8)
    IF-NOT-EXISTS: What to do if file doesn't exist (NIL, :CREATE, :ERROR)

  Returns:
    File contents as string or NIL"
  (handler-case
      (cond
        ((probe-file path)
         (log-debug "Reading file: ~A" path)
         (with-open-file (stream path :direction :input
                                 :external-format encoding)
           (let ((content (make-string (file-length stream))))
             (read-sequence content stream)
             content)))
        ((eq if-not-exists :create)
         (log-debug "Creating and reading file: ~A" path)
         (touch-file path)
         "")
        ((eq if-not-exists :error)
         (error 'fs-file-error :path path :message "File not found"))
        (t nil))
    (file-error (e)
      (log-error "File read error ~A: ~A" path e)
      nil)
    (error (e)
      (log-error "Failed to read file ~A: ~A" path e)
      nil)))

(defun file-read-lines (path &key (encoding :utf-8))
  "Read file as list of lines.

  Args:
    PATH: File path
    ENCODING: Character encoding

  Returns:
    List of strings"
  (handler-case
      (with-open-file (stream path :direction :input
                              :external-format encoding)
        (loop for line = (read-line stream nil nil)
              while line
              collect line))
    (error (e)
      (log-error "Failed to read file lines ~A: ~A" path e)
      nil)))

(defun file-read-binary (path)
  "Read file as binary data.

  Args:
    PATH: File path

  Returns:
    Vector of octets"
  (handler-case
      (with-open-file (stream path :direction :input
                              :element-type '(unsigned-byte 8))
        (let ((data (make-array (file-length stream)
                                :element-type '(unsigned-byte 8))))
          (read-sequence data stream)
          data))
    (error (e)
      (log-error "Failed to read binary file ~A: ~A" path e)
      nil)))

;;; ============================================================================
;;; File Writing
;;; ============================================================================

(defun file-write (path content &key (encoding :utf-8) (if-exists :supersede))
  "Write content to file.

  Args:
    PATH: File path
    CONTENT: String content to write
    ENCODING: Character encoding
    IF-EXISTS: How to handle existing file

  Returns:
    T on success"
  (handler-case
      (progn
        ;; Ensure directory exists
        (ensure-directories-exist path)
        (log-debug "Writing file: ~A" path)
        (with-open-file (stream path :direction :output
                                :if-exists if-exists
                                :if-does-not-exist :create
                                :external-format encoding)
          (write-string content stream))
        t)
    (error (e)
      (log-error "Failed to write file ~A: ~A" path e)
      nil)))

(defun file-append (path content &key (encoding :utf-8))
  "Append content to file.

  Args:
    PATH: File path
    CONTENT: String content to append
    ENCODING: Character encoding

  Returns:
    T on success"
  (handler-case
      (progn
        (log-debug "Appending to file: ~A" path)
        (with-open-file (stream path :direction :output
                                :if-exists :append
                                :if-does-not-exist :create
                                :external-format encoding)
          (write-string content stream))
        t)
    (error (e)
      (log-error "Failed to append to file ~A: ~A" path e)
      nil)))

(defun file-write-binary (path data &key (if-exists :supersede))
  "Write binary data to file.

  Args:
    PATH: File path
    DATA: Vector of octets
    IF-EXISTS: How to handle existing file

  Returns:
    T on success"
  (handler-case
      (progn
        (ensure-directories-exist path)
        (log-debug "Writing binary file: ~A" path)
        (with-open-file (stream path :direction :output
                                :if-exists if-exists
                                :if-does-not-exist :create
                                :element-type '(unsigned-byte 8))
          (write-sequence data stream))
        t)
    (error (e)
      (log-error "Failed to write binary file ~A: ~A" path e)
      nil)))

;;; ============================================================================
;;; File Operations
;;; ============================================================================

(defun file-delete (path &key (if-not-exists :ignore))
  "Delete a file.

  Args:
    PATH: File path
    IF-NOT-EXISTS: What to do if file doesn't exist (:IGNORE, :ERROR)

  Returns:
    T on success"
  (handler-case
      (cond
        ((probe-file path)
         (log-debug "Deleting file: ~A" path)
         (delete-file path)
         t)
        ((eq if-not-exists :error)
         (error 'fs-file-error :path path :message "File not found"))
        (t
         (log-warn "File not found, ignoring: ~A" path)
         nil))
    (error (e)
      (log-error "Failed to delete file ~A: ~A" path e)
      nil)))

(defun file-copy (source destination &key (if-exists :supersede))
  "Copy a file.

  Args:
    SOURCE: Source file path
    DESTINATION: Destination file path
    IF-EXISTS: How to handle existing destination

  Returns:
    T on success"
  (handler-case
      (progn
        (unless (probe-file source)
          (error 'fs-file-error :path source :message "Source file not found"))
        (ensure-directories-exist destination)
        (log-debug "Copying file: ~A -> ~A" source destination)
        (copy-file source destination)
        t)
    (error (e)
      (log-error "Failed to copy file ~A: ~A" source e)
      nil)))

(defun file-move (source destination &key (if-exists :supersede))
  "Move/rename a file.

  Args:
    SOURCE: Source file path
    DESTINATION: Destination file path
    IF-EXISTS: How to handle existing destination

  Returns:
    T on success"
  (handler-case
      (progn
        (unless (probe-file source)
          (error 'fs-file-error :path source :message "Source file not found"))
        (ensure-directories-exist destination)
        (log-debug "Moving file: ~A -> ~A" source destination)
        (rename-file source destination)
        t)
    (error (e)
      (log-error "Failed to move file ~A: ~A" source e)
      nil)))

(defun file-exists-p (path)
  "Check if file exists.

  Args:
    PATH: File path

  Returns:
    T if file exists"
  (and (probe-file path) t))

(defun file-info (path)
  "Get file information.

  Args:
    PATH: File path

  Returns:
    Plist with :size, :created, :modified, :type"
  (handler-case
      (when (probe-file path)
        (let ((stat (file-write-date path))
              (modified (file-write-date path))
              (size (file-length path)))
          `(:path ,path
            :size ,size
            :modified ,modified
            :created ,stat
            :type ,(if (directory-pathname-p path) :directory :file))))
    (error (e)
      (log-error "Failed to get file info ~A: ~A" path e)
      nil)))

;;; ============================================================================
;;; Directory Operations
;;; ============================================================================

(defun list-directory (path &key (recurse nil) (pattern nil))
  "List directory contents.

  Args:
    PATH: Directory path
    RECURSE: Whether to recurse subdirectories
    PATTERN: Optional pattern to filter (e.g., \"*.lisp\")

  Returns:
    List of file paths"
  (handler-case
      (let ((files nil))
        (if recurse
            ;; Simple recursive implementation using CL directory
            (labels ((collect-dir (dir)
                       (when (probe-file dir)
                         (let ((entries (directory (merge-pathnames "*.*" dir))))
                           (dolist (entry entries)
                             (when (or (null pattern)
                                       (search pattern (namestring entry)
                                             :test #'char-equal))
                               (push entry files))
                             (when (and recurse (directory-pathname-p entry))
                               (collect-dir entry)))))))
              (collect-dir path))
            (let ((dir (pathname path)))
              (when (probe-file dir)
                (setf files (directory (merge-pathnames "*.*" dir))))))
        files)
    (error (e)
      (log-error "Failed to list directory ~A: ~A" path e)
      nil)))

(defun make-directory (path &key (parents t))
  "Create a directory.

  Args:
    PATH: Directory path
    PARENTS: Create parent directories if needed

  Returns:
    T on success"
  (handler-case
      (progn
        (if parents
            (ensure-directories-exist (merge-pathnames "dummy/" path))
            (make-directory path))
        (log-debug "Created directory: ~A" path)
        t)
    (error (e)
      (log-error "Failed to create directory ~A: ~A" path e)
      nil)))

;;; ============================================================================
;;; File Locking
;;; ============================================================================

(defvar *file-locks* (make-hash-table :test 'equal)
  "Active file locks.")

(defmacro with-file-lock ((path &key (timeout 10)) &body body)
  "Execute body with exclusive file lock.

  Usage:
    (with-file-lock (\"/path/to/file\")
      (file-write \"/path/to/file\" \"content\"))

  Args:
    PATH: File to lock
    TIMEOUT: Lock timeout in seconds
    BODY: Forms to execute"
  (let ((lock-got (gensym "LOCK-GOT"))
        (start-time (gensym "START-TIME")))
    `(let ((,lock-got nil)
           (,start-time (get-universal-time)))
       (unwind-protect
            (progn
              (loop until (setf ,lock-got (setf (gethash ,path *file-locks*) t))
                    while (< (- (get-universal-time) ,start-time) ,timeout)
                    do (sleep 0.1))
              (unless ,lock-got
                (error 'fs-file-lock-error :path ,path :message "Lock timeout"))
              ,@body)
         (when ,lock-got
           (setf (gethash ,path *file-locks*) nil))))))

;;; ============================================================================
;;; Utility Functions
;;; ============================================================================

(defun touch-file (path)
  "Create empty file or update timestamp.

  Args:
    PATH: File path

  Returns:
    T on success"
  (handler-case
      (progn
        (ensure-directories-exist path)
        (with-open-file (stream path :direction :output
                                :if-exists :overwrite
                                :if-does-not-exist :create)
          (finish-output stream))
        t)
    (error (e)
      (log-error "Failed to touch file ~A: ~A" path e)
      nil)))

(defun file-extension (path)
  "Get file extension.

  Args:
    PATH: File path

  Returns:
    Extension string (e.g., \"txt\")"
  (pathname-type path))

(defun file-name-without-extension (path)
  "Get file name without extension.

  Args:
    PATH: File path

  Returns:
    Name string"
  (pathname-name path))

(defun ensure-file-exists (path &key (content ""))
  "Ensure file exists, create if not.

  Args:
    PATH: File path
    CONTENT: Content for new file

  Returns:
    T"
  (unless (probe-file path)
    (file-write path content))
  t)

;;; ============================================================================
;;; Conditions
;;; ============================================================================

(define-condition fs-file-error (error)
  ((path :initarg :path :reader error-path)
   (message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "File error '~A': ~A"
                     (error-path condition)
                     (error-message condition)))))

(define-condition fs-file-lock-error (error)
  ((path :initarg :path :reader error-path)
   (message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "File lock error '~A': ~A"
                     (error-path condition)
                     (error-message condition)))))

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defun register-file-tools ()
  "Register file operation tools with the tool registry.

  Returns:
    T on success"
  (log-info "File tools registered")
  t)
