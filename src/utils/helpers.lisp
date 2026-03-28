;;; helpers.lisp --- General Utility Helpers for Lisp-Claw
;;;
;;; This file provides general utility functions and helpers
;;; used throughout the Lisp-Claw system.

(defpackage #:lisp-claw.utils.helpers
  (:nicknames #:lc.utils.helpers)
  (:use #:cl
        #:alexandria
        #:serapeum)
  (:export
   ;; Time utilities
   #:now
   #:timestamp
   #:parse-timestamp
   #:format-duration
   #:timeout-wrap

   ;; String utilities
   #:trim
   #:empty-string-p
   #:non-empty-string-p
   #:truncate-string
   #:safe-subseq

   ;; Sequence utilities
   #:safe-first
   #:safe-rest
   #:ensure-list
   #:ensure-array

   ;; Path utilities
   #:ensure-directory
   #:file-exists-p
   #:read-file-contents
   #:write-file-contents

   ;; Error handling
   #:ignore-errors*
   #:retry-on-error
   #:defcondition

   ;; Misc utilities
   #:callable-p
   #:symbol-function-value
   #:deep-copy))

(in-package #:lisp-claw.utils.helpers)

;;; ============================================================================
;;; Time Utilities
;;; ============================================================================

(defun now ()
  "Get the current universal time.

  Returns:
    Current universal time (integer)"
  (get-universal-time))

(defun timestamp ()
  "Get a formatted timestamp string.

  Returns:
    ISO 8601 formatted timestamp string"
  (multiple-value-bind (second minute hour day month year)
      (get-decoded-time)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour minute second)))

(defun parse-timestamp (timestamp-string)
  "Parse an ISO 8601 timestamp string to universal time.

  Args:
    TIMESTAMP-STRING: ISO 8601 formatted string

  Returns:
    Universal time (integer) or NIL if parsing fails"
  (handler-case
      ;; Simple ISO 8601 parser
      (let* ((parts (split-sequence:split-sequence #\T timestamp-string))
             (date-parts (split-sequence:split-sequence #\- (first parts)))
             (time-parts (when (second parts)
                           (split-sequence:split-sequence #\: (second parts))))
             (year (parse-integer (first date-parts)))
             (month (parse-integer (second date-parts)))
             (day (parse-integer (third date-parts)))
             (hour (if time-parts (parse-integer (first time-parts)) 0))
             (minute (if time-parts (parse-integer (second time-parts)) 0))
             (second (if (and time-parts (third time-parts))
                         (parse-integer (third time-parts))
                         0)))
        (encode-universal-time second minute hour day month year 0))
    (error () nil)))

(defun format-duration (seconds)
  "Format a duration in seconds to a human-readable string.

  Args:
    SECONDS: Duration in seconds

  Returns:
    Formatted string (e.g., \"1h 23m 45s\")"
  (let* ((hours (floor seconds 3600))
         (minutes (floor (mod seconds 3600) 60))
         (secs (mod seconds 60)))
    (cond
      ((>= hours 1)
       (format nil "~Ah ~Am ~As" hours minutes secs))
      ((>= minutes 1)
       (format nil "~Am ~As" minutes secs))
      (t
       (format nil "~As" secs)))))

(defmacro timeout-wrap (timeout-seconds &body body)
  "Wrap body execution with a timeout.

  Args:
    TIMEOUT-SECONDS: Maximum execution time in seconds
    BODY: Forms to execute

  Returns:
    Result of body or signals TIMEOUT-ERROR"
  `(let ((deadline (+ (get-universal-time) ,timeout-seconds)))
     (flet ((check-timeout ()
              (when (> (get-universal-time) deadline)
                (error 'timeout-error :message "Operation timed out"))))
       (macrolet ((with-timeout-check (&body forms)
                    `(progn (check-timeout) ,@forms)))
         ,@body))))

(define-condition timeout-error (error)
  ((message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "Timeout: ~A" (error-message condition)))))

;;; ============================================================================
;;; String Utilities
;;; ============================================================================

(defun trim (string &key (chars '(#\Space #\Tab #\Newline #\Return)))
  "Trim whitespace or specified characters from a string.

  Args:
    STRING: The string to trim
    CHARS: List of characters to trim (default: whitespace)

  Returns:
    Trimmed string"
  (string-trim chars string))

(defun empty-string-p (string)
  "Check if a string is empty or contains only whitespace.

  Args:
    STRING: The string to check

  Returns:
    T if empty, NIL otherwise"
  (or (null string)
      (and (stringp string)
           (zerop (length (trim string))))))

(defun non-empty-string-p (string)
  "Check if a string is non-empty.

  Args:
    STRING: The string to check

  Returns:
    T if non-empty, NIL otherwise"
  (and (stringp string)
       (not (empty-string-p string))))

(defun truncate-string (string max-length &optional (suffix "..."))
  "Truncate a string to a maximum length.

  Args:
    STRING: The string to truncate
    MAX-LENGTH: Maximum length
    SUFFIX: Suffix to add if truncated (default \"...\")

  Returns:
    Truncated string"
  (if (<= (length string) max-length)
      string
      (concatenate 'string
                   (subseq string 0 (- max-length (length suffix)))
                   suffix)))

(defun safe-subseq (sequence start &optional end)
  "Safely get a subsequence, handling out-of-bounds indices.

  Args:
    SEQUENCE: The sequence to extract from
    START: Start index
    END: End index (optional)

  Returns:
    Subsequence or NIL if indices are invalid"
  (handler-case
      (if end
          (subseq sequence start end)
          (subseq sequence start))
    (error () nil)))

;;; ============================================================================
;;; Sequence Utilities
;;; ============================================================================

(defun safe-first (list)
  "Safely get the first element of a list.

  Args:
    LIST: The list

  Returns:
    First element or NIL if list is empty"
  (car list))

(defun safe-rest (list)
  "Safely get the rest of a list.

  Args:
    LIST: The list

  Returns:
    Rest of list or NIL"
  (cdr list))

(defun ensure-list (x)
  "Ensure X is a list.

  Args:
    X: Any object

  Returns:
    X if it's a list, otherwise (list X)"
  (if (listp x)
      x
      (list x)))

(defun ensure-array (x)
  "Ensure X is a vector.

  Args:
    X: Any object

  Returns:
    X if it's a vector, otherwise a vector containing X"
  (if (vectorp x)
      x
      (coerce (list x) 'vector)))

;;; ============================================================================
;;; Path Utilities
;;; ============================================================================

(defun ensure-directory (path)
  "Ensure a directory exists, creating it if necessary.

  Args:
    PATH: Directory path

  Returns:
    The directory pathname"
  (let ((dir (if (pathnamep path) path (pathname path))))
    (uiop:ensure-directory-pathname dir)
    (uiop:ensure-directories-exist dir)
    dir))

(defun file-exists-p (path)
  "Check if a file exists.

  Args:
    PATH: File path

  Returns:
    T if file exists, NIL otherwise"
  (and (probe-file path) t))

(defun read-file-contents (path &key (external-format :utf-8))
  "Read the entire contents of a file.

  Args:
    PATH: File path
    EXTERNAL-FORMAT: Character encoding (default :utf-8)

  Returns:
    File contents as string"
  (uiop:read-file-string path :external-format external-format))

(defun write-file-contents (path contents &key (external-format :utf-8))
  "Write contents to a file.

  Args:
    PATH: File path
    CONTENTS: String contents to write
    EXTERNAL-FORMAT: Character encoding (default :utf-8)

  Returns:
    NIL"
  (ensure-directory (directory-namestring path))
  (uiop:write-string-file contents path :external-format external-format))

;;; ============================================================================
;;; Error Handling
;;; ============================================================================

(defmacro ignore-errors* (&body body)
  "Like ignore-errors but returns NIL on error.

  Args:
    BODY: Forms to execute

  Returns:
    Result of body or NIL on error"
  `(handler-case
       (progn ,@body)
     (error (e)
       (declare (ignore e))
       nil)))

(defmacro retry-on-error (max-retries delay-seconds &body body)
  "Retry body on error up to MAX-RETRIES times.

  Args:
    MAX-RETRIES: Maximum number of retry attempts
    DELAY-SECONDS: Delay between retries
    BODY: Forms to execute

  Returns:
    Result of body or signals last error"
  `(let ((attempt 0)
         (last-error nil))
     (loop
       (handler-case
           (return ,@body)
         (error (e)
           (setf last-error e)
           (incf attempt)
           (when (>= attempt ,max-retries)
             (error last-error))
           (sleep ,delay-seconds))))))

;;; ============================================================================
;;; Misc Utilities
;;; ============================================================================

(defun callable-p (x)
  "Check if X is callable as a function.

  Args:
    X: Any object

  Returns:
    T if X is a function, symbol with function, or lambda"
  (or (functionp x)
      (and (symbolp x)
           (fboundp x))))

(defun symbol-function-value (x)
  "Get the function value of a symbol or function.

  Args:
    X: Symbol or function

  Returns:
    Function object"
  (if (functionp x)
      x
      (symbol-function x)))

(defun deep-copy (object)
  "Create a deep copy of an object.

  Args:
    OBJECT: Object to copy

  Returns:
    Deep copy of object"
  (cond
    ((consp object)
     (cons (deep-copy (car object))
           (deep-copy (cdr object))))
    ((vectorp object)
     (map 'vector #'deep-copy object))
    ((hash-table-p object)
     (let ((new-ht (make-hash-table :test (hash-table-test object))))
       (maphash (lambda (k v)
                  (setf (gethash k new-ht) (deep-copy v)))
                object)
       new-ht))
    (t object)))
