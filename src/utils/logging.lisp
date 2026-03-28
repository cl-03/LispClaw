;;; logging.lisp --- Logging System for Lisp-Claw
;;;
;;; This file implements a simple logging system using log4cl.
;;; Provides debug, info, warn, and error level logging with timestamps.

(defpackage #:lisp-claw.utils.logging
  (:nicknames #:lc.utils.logging)
  (:use #:cl
        #:alexandria
        #:log4cl)
  (:export
   #:*logger*
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

(defvar *logger* nil
  "The main logger instance for Lisp-Claw.")

(defvar *log-level* :info
  "Current log level. One of: :debug, :info, :warn, :error.")

(defvar *log-file* nil
  "Path to the log file. If NIL, logs go to stdout.")

;;; ============================================================================
;;; Setup
;;; ============================================================================

(defun setup-logging (&key (level :info)
                         (file nil)
                         (pattern "[%-5p %d{HH:mm:ss}] %m%n"))
  "Initialize the logging system.

  Args:
    LEVEL: Log level keyword (:debug, :info, :warn, :error)
    FILE: Optional path to log file
    PATTERN: Log message pattern

  Returns:
    The logger instance"
  (setf *log-level* level)
  (setf *log-file* file)

  ;; Configure log4cl
  (log:config
   :level level
   :pattern pattern)

  ;; Add file appender if specified
  (when file
    (log:add-appender (make-instance 'log:file-appender
                                     :name "file"
                                     :file file
                                     :append-p t)))

  ;; Create and return logger
  (setf *logger* (log:get-logger "lisp-claw"))
  (log-info "Logging initialized at level ~A" level)
  *logger*)

;;; ============================================================================
;;; Logging Macros
;;; ============================================================================

(defun log-format-message (format-string &rest args)
  "Format a log message with timestamp and level.

  Args:
    FORMAT-STRING: A format string
    ARGS: Arguments to the format string

  Returns:
    Formatted message string"
  (apply #'format nil format-string args))

(defmacro log-debug (format-string &rest args)
  "Log a debug message."
  `(log:debug ,format-string ,@args))

(defmacro log-info (format-string &rest args)
  "Log an info message."
  `(log:info ,format-string ,@args))

(defmacro log-warn (format-string &rest args)
  "Log a warning message."
  `(log:warn ,format-string ,@args))

(defmacro log-error (format-string &rest args)
  "Log an error message."
  `(log:error ,format-string ,@args))

;;; ============================================================================
;;; Utility Functions
;;; ============================================================================

(defun log-with-context (context level format-string &rest args)
  "Log a message with additional context information.

  Args:
    CONTEXT: A string or alist providing context
    LEVEL: Log level
    FORMAT-STRING: Format string for the message
    ARGS: Format arguments

  Returns:
    NIL"
  (let* ((context-str (if (alist-p context)
                          (format nil "~{~A=~A ~}" context)
                          (princ-to-string context)))
         (full-msg (format nil "[~A] ~A" context-str
                           (apply #'format nil format-string args))))
    (ecase level
      (:debug (log:debug full-msg))
      (:info (log:info full-msg))
      (:warn (log:warn full-msg))
      (:error (log:error full-msg)))))

(defun with-logging (name &body body)
  "Macro to wrap body execution with logging.

  Args:
    NAME: Name of the operation for logging
    BODY: Body forms to execute

  Returns:
    Result of body execution"
  (let ((start-gensym (gensym "START"))
        (end-gensym (gensym "END"))
        (result-gensym (gensym "RESULT")))
    `(let* ((,start-gensym (get-universal-time))
            (,result-gensym (progn
                              (log-debug "Starting ~A" ,name)
                              ,@body))
            (,end-gensym (get-universal-time)))
       (log-debug "Completed ~A in ~,2F seconds"
                  ,name
                  (- ,end-gensym ,start-gensym))
       ,result-gensym)))

;;; ============================================================================
;;; Log Rotation
;;; ============================================================================

(defun rotate-log-file (&optional (max-backups 5))
  "Rotate the current log file.

  Args:
    MAX-BACKUPS: Maximum number of backup files to keep

  Returns:
    NIL"
  (when *log-file*
    (let* ((base-name (namestring *log-file*))
           (dir (directory-namestring *log-file*))
           (name (file-namestring *log-file*)))
      ;; Delete oldest backup
      (let ((oldest (probe-file (merge-pathnames (format nil "~A.~D" name max-backups)
                                                 dir))))
        (when oldest
          (delete-file oldest)))

      ;; Rotate existing backups
      (loop for i from (1- max-backups) downto 1
            for src = (merge-pathnames (format nil "~A.~D" name (1- i)) dir)
            for dst = (merge-pathnames (format nil "~A.~D" name i) dir)
            when (probe-file src)
            do (rename-file src dst))

      ;; Move current log to .1
      (when (probe-file *log-file*)
        (rename-file *log-file*
                     (merge-pathnames (format nil "~A.1" name) dir))))))
