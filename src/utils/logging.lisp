;;; logging.lisp --- Logging System for Lisp-Claw
;;;
;;; This file implements a simple logging system without external dependencies.
;;; Provides debug, info, warn, and error level logging with timestamps.

(defpackage #:lisp-claw.utils.logging
  (:nicknames #:lc.utils.logging)
  (:use #:cl
        #:alexandria)
  (:export
   #:*log-level*
   #:*log-stream*
   #:setup-logging
   #:log-debug
   #:log-info
   #:log-warn
   #:log-error
   #:log-format-message))

(in-package #:lisp-claw.utils.logging)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *log-level* :info
  "Current log level. One of: :debug, :info, :warn, :error.")

(defvar *log-stream* nil
  "Log output stream. If NIL, logs go to *error-output*.")

(defvar *log-file* nil
  "Path to the log file.")

;;; ============================================================================
;;; Setup
;;; ============================================================================

(defun setup-logging (&key (level :info)
                         (file nil)
                         (prefix "LISP-CLAW"))
  "Initialize the logging system.

  Args:
    LEVEL: Log level keyword (:debug, :info, :warn, :error)
    FILE: Optional path to log file
    PREFIX: Log message prefix

  Returns:
    T on success"
  (setf *log-level* level)
  (setf *log-file* file)
  (when file
    (setf *log-stream* (open file :direction :output
                             :if-exists :append
                             :if-does-not-exist :create)))
  t)

;;; ============================================================================
;;; Internal Logging
;;; ============================================================================

(defun %log (level format-string &rest args)
  "Internal logging function.

  Args:
    LEVEL: Log level keyword
    FORMAT-STRING: Format string
    ARGS: Format arguments"
  (let* ((now (get-universal-time))
         (secs (mod now 86400))
         (hours (floor secs 3600))
         (mins (floor (mod secs 3600) 60))
         (secs (floor (mod secs 60)))
         (timestamp (format nil "~2,'0d:~2,'0d:~2,'0d" hours mins secs))
         (message (apply #'format nil format-string args))
         (output (format nil "[~A ~A] ~A~%" level timestamp message))
         (stream (or *log-stream* *error-output*)))
    (write-string output stream)
    (finish-output stream)))

;;; ============================================================================
;;; Logging Macros
;;; ============================================================================

(defmacro log-debug (format-string &rest args)
  "Log a debug message.

  Args:
    FORMAT-STRING: Format string
    ARGS: Format arguments"
  `(when (eq *log-level* :debug)
     (%log :debug ,format-string ,@args)))

(defmacro log-info (format-string &rest args)
  "Log an info message.

  Args:
    FORMAT-STRING: Format string
    ARGS: Format arguments"
  `(when (member *log-level* '(:info :debug))
     (%log :info ,format-string ,@args)))

(defmacro log-warn (format-string &rest args)
  "Log a warning message.

  Args:
    FORMAT-STRING: Format string
    ARGS: Format arguments"
  `(when (member *log-level* '(:warn :info :debug))
     (%log :warn ,format-string ,@args)))

(defmacro log-error (format-string &rest args)
  "Log an error message.

  Args:
    FORMAT-STRING: Format string
    ARGS: Format arguments"
  `(%log :error ,format-string ,@args))

;;; ============================================================================
;;; Utility Functions
;;; ============================================================================

(defun log-format-message (format-string &rest args)
  "Format a log message.

  Args:
    FORMAT-STRING: Format string
    ARGS: Arguments to the format string

  Returns:
    Formatted message string"
  (apply #'format nil format-string args))

(defun close-logging ()
  "Close the log stream if open.

  Returns:
    NIL"
  (when (and *log-stream*
             (streamp *log-stream*)
             (open-stream-p *log-stream*))
    (close *log-stream*))
  (setf *log-stream* nil)
  (setf *log-file* nil))
