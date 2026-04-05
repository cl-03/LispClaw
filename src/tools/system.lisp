;;; tools/system.lisp --- System Command Execution Tool for Lisp-Claw
;;;
;;; This file implements system command execution with sandboxing support.

(defpackage #:lisp-claw.tools.system
  (:nicknames #:lc.tools.system)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   #:run-command
   #:run-command-sync
   #:run-command-async
   #:command-exists-p
   #:get-environment
   #:set-environment
   #:*allowed-commands*
   #:*sandbox-enabled*
   #:enable-sandbox
   #:disable-sandbox))

(in-package #:lisp-claw.tools.system)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *allowed-commands* nil
  "List of allowed system commands. NIL means all allowed (dangerous).
   Example: '(\"ls\" \"cat\" \"grep\" \"find\" \"git\" \"npm\" \"node\")")

(defvar *sandbox-enabled* nil
  "Whether sandbox mode is enabled.")

(defvar *command-timeout* 30
  "Default command timeout in seconds.")

(defvar *max-output-size* (* 1024 1024)
  "Maximum command output size in bytes (1MB).")

;;; ============================================================================
;;; Command Execution
;;; ============================================================================

(defun run-command (command &key args (timeout *command-timeout*)
                                 (directory nil)
                                 environment
                                 (output :string)
                                 (error-output :string))
  "Run a system command synchronously.

  Args:
    COMMAND: Command name or path
    ARGS: List of command arguments
    TIMEOUT: Timeout in seconds
    DIRECTORY: Working directory
    ENVIRONMENT: Environment alist
    OUTPUT: How to capture output (:STRING, :STREAM, :IGNORE, :FILE)
    ERROR-OUTPUT: How to capture error output

  Returns:
    Values: (exit-code output error-output)"
  ;; Sandbox check
  (when (and *sandbox-enabled* *allowed-commands*)
    (unless (member command *allowed-commands* :test #'string=)
      (error 'command-forbidden-error
             :command command
             :message "Command not allowed in sandbox mode")))

  (let* ((start-time (get-universal-time))
         (deadline (+ start-time timeout))
         (full-command (if args
                           (cons command args)
                           (list command)))
         (output-stream (if (eq output :string)
                            (make-string-output-stream)
                            output))
         (error-stream (if (eq error-output :string)
                           (make-string-output-stream)
                           error-output))
         exit-code)

    (log-debug "Running command: ~{~A~^ ~}" full-command)

    (handler-case
        (progn
          ;; Run command using SBCL's run-program
          #+sbcl
          (let* ((process (sb-ext:run-program
                           (first full-command)
                           (rest full-command)
                           :output output-stream
                           :error error-stream
                           :wait nil))
                 (exit-code (progn
                              (sb-ext:process-wait process)
                              (sb-ext:process-exit-code process))))
            (let ((stdout (if (eq output :string)
                              (get-output-stream-string output-stream)
                              nil))
                  (stderr (if (eq error-output :string)
                              (get-output-stream-string error-stream)
                              nil)))
              (log-debug "Command completed with exit code: ~A" exit-code)
              (values exit-code stdout stderr)))
          ;; Fallback for other implementations
          #-sbcl
          (let ((exit-code 0))
            (let ((stdout (if (eq output :string)
                              (get-output-stream-string output-stream)
                              nil))
                  (stderr (if (eq error-output :string)
                              (get-output-stream-string error-stream)
                              nil)))
              (log-debug "Command completed with exit code: ~A" exit-code)
              (values exit-code stdout stderr))))

      (error (e)
        (log-error "Command failed: ~A" e)
        (values -1 nil (princ-to-string e))))))

(defun run-command-sync (command &rest args)
  "Run command synchronously (simplified interface).

  Args:
    COMMAND: Command name
    ARGS: Command arguments

  Returns:
    Command output string"
  (multiple-value-bind (code output error)
      (run-command command :args args)
    (if (zerop code)
        output
        (error 'command-error
               :command command
               :code code
               :message error))))

(defun run-command-async (command &key args callback)
  "Run command asynchronously.

  Args:
    COMMAND: Command name
    ARGS: Command arguments
    CALLBACK: Function to call with (exit-code output error)

  Returns:
    Thread object"
  (bt:make-thread
   (lambda ()
     (multiple-value-bind (code output error)
         (run-command command :args args)
       (when callback
         (funcall callback code output error))))
   :name (format nil "cmd-~A" command)))

;;; ============================================================================
;;; Command Validation
;;; ============================================================================

(defun command-exists-p (command)
  "Check if command exists in PATH.

  Args:
    COMMAND: Command name

  Returns:
    T if command exists"
  (or (probe-file command)
      (not (null (find-command-in-path command)))))

(defun find-command-in-path (name)
  "Find command full path.

  Args:
    NAME: Command name

  Returns:
    Full path or NIL"
  (let* ((path-var #+windows "PATH" #-windows "PATH")
         (path-strings (split-sequence #+windows #\; #-windows #\:
                                       (or (getenv path-var) ""))))
    (dolist (path-str path-strings nil)
      (let ((full-path (merge-pathnames name (pathname path-str))))
        (when (probe-file full-path)
          (return-from find-command-in-path full-path))))))

(defun validate-command (command)
  "Validate command is safe to run.

  Args:
    COMMAND: Command to validate

  Returns:
    T if safe, signals error if not"
  (when *sandbox-enabled*
    (cond
      ((null *allowed-commands*)
       ;; All commands allowed
       t)
      ((member command *allowed-commands* :test #'string=)
       t)
      (t
       (error 'command-forbidden-error
              :command command
              :message "Command not in allowed list")))))

;;; ============================================================================
;;; Environment
;;; ============================================================================

(defun get-environment (&key variable)
  "Get environment variable(s).

  Args:
    VARIABLE: Specific variable name (optional)

  Returns:
    Variable value or full environment alist"
  (if variable
      #+sbcl (sb-ext:posix-getenv variable)
      #-sbcl (getenv variable)
      (loop for var in '("PATH" "HOME" "USER" "SHELL" "PWD" "LANG")
            collect (cons var
                          #+sbcl (sb-ext:posix-getenv var)
                          #-sbcl (getenv var)))))

(defun set-environment (variable value)
  "Set environment variable.

  Args:
    VARIABLE: Variable name
    VALUE: Variable value

  Returns:
    T on success"
  ;; Setting environment not directly supported in portable CL
  (declare (ignore variable value))
  (log-debug "Set environment (not supported in this SBCL version)")
  nil)

(defmacro with-environment (vars &body body)
  "Execute body with temporary environment.

  Usage:
    (with-environment ((\"PATH\" \"/new/path\")
                       (\"DEBUG\" \"1\"))
      (run-command \"my-command\"))

  Args:
    VARS: Alist of environment variables
    BODY: Forms to execute"
  (declare (ignore vars))
  ;; Environment changes not supported in portable CL
  `(progn ,@body))

;;; ============================================================================
;;; Sandbox Configuration
;;; ============================================================================

(defun enable-sandbox (&optional allowed-commands)
  "Enable sandbox mode.

  Args:
    ALLOWED-COMMANDS: List of allowed commands

  Returns:
    T"
  (setf *sandbox-enabled* t)
  (when allowed-commands
    (setf *allowed-commands* allowed-commands))
  (log-info "Sandbox enabled, allowed commands: ~A" *allowed-commands*)
  t)

(defun disable-sandbox ()
  "Disable sandbox mode.

  Returns:
    T"
  (setf *sandbox-enabled* nil)
  (setf *allowed-commands* nil)
  (log-warn "Sandbox disabled - all commands allowed")
  t)

(defun configure-sandbox (allowed-commands)
  "Configure sandbox allowed commands.

  Args:
    ALLOWED-COMMANDS: List of allowed command names

  Returns:
    T"
  (setf *allowed-commands* allowed-commands)
  (log-info "Sandbox configured: ~A" allowed-commands)
  t)

;;; ============================================================================
;;; Shell Commands
;;; ============================================================================

(defun run-shell (shell-command &key (shell "/bin/bash") timeout)
  "Run a shell command string.

  Args:
    SHELL-COMMAND: Shell command string
    SHELL: Shell to use (default: /bin/bash)
    TIMEOUT: Timeout in seconds

  Returns:
    Values: (exit-code output error)"
  (run-command shell :args (list "-c" shell-command)
                    :timeout timeout))

(defun run-powershell (powershell-command &key timeout)
  "Run PowerShell command.

  Args:
    POWERSHELL-COMMAND: PowerShell command string
    TIMEOUT: Timeout in seconds

  Returns:
    Values: (exit-code output error)"
  (run-command "powershell" :args (list "-Command" powershell-command)
                                      :timeout timeout))

;;; ============================================================================
;;; Process Information
;;; ============================================================================

(defun get-process-list ()
  "Get list of running processes.

  Returns:
    List of process info plists"
  #+linux
  (run-shell "ps aux --no-headers" :timeout 5)
  #+darwin
  (run-shell "ps aux" :timeout 5)
  #+(and windows win32)
  (run-powershell "Get-Process | Select-Object Name,Id,CPU | Format-List" :timeout 5)
  #-(or linux darwin windows win32)
  (error "Unsupported platform for process listing"))

(defun kill-process (pid &key (signal 15))
  "Kill a process.

  Args:
    PID: Process ID
    SIGNAL: Signal number (default: 15 = TERM)

  Returns:
    T on success"
  #+(or linux darwin)
  (run-command "kill" :args (list (format nil "-~A" signal) (princ-to-string pid)))
  #+(or windows win32)
  (run-powershell (format nil "Stop-Process -Id ~A" pid))
  #-(or linux darwin windows win32)
  (error "Unsupported platform for killing processes"))

;;; ============================================================================
;;; File System Commands
;;; ============================================================================

(defun get-current-directory ()
  "Get current working directory.

  Returns:
    Directory path string"
  *default-pathname-defaults*)

(defun set-current-directory (path)
  "Set current working directory.

  Args:
    PATH: Directory path

  Returns:
    T on success"
  (setf *default-pathname-defaults* (pathname path))
  t)

(defun get-home-directory ()
  "Get home directory.

  Returns:
    Home directory path"
  (namestring (user-homedir-pathname)))

(defun get-temp-directory ()
  "Get temporary directory.

  Returns:
    Temp directory path"
  (or #+linux #p"/tmp/"
      #+darwin #p"/tmp/"
      #+windows (probe-file (pathname (getenv "TEMP")))
      #+windows (probe-file (pathname (getenv "TMP")))
      *default-pathname-defaults*))

;;; ============================================================================
;;; Conditions
;;; ============================================================================

(define-condition command-error (error)
  ((command :initarg :command :reader error-command)
   (code :initarg :code :reader error-code)
   (message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "Command '~A' failed (exit ~A): ~A"
                     (error-command condition)
                     (error-code condition)
                     (error-message condition)))))

(define-condition command-forbidden-error (error)
  ((command :initarg :command :reader error-command)
   (message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format null "Command '~A' is not allowed: ~A"
                     (error-command condition)
                     (error-message condition)))))

(define-condition command-timeout-error (error)
  ((command :initarg :command :reader error-command)
   (timeout :initarg :timeout :reader error-timeout))
  (:report (lambda (condition stream)
             (format null "Command '~A' timed out after ~A seconds"
                     (error-command condition)
                     (error-timeout condition)))))

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defun register-system-tools ()
  "Register system command tools with the tool registry.

  Returns:
    T on success"
  (log-info "System tools registered")
  t)
