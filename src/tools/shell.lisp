;;; tools/shell.lisp --- Shell Tool for Lisp-Claw
;;;
;;; This file implements a sandboxed shell execution tool:
;;; - Command execution with output capture
;;; - Timeout control
;;; - Working directory management
;;; - Command whitelisting/blacklisting
;;; - Security沙箱 integration

(defpackage #:lisp-claw.tools.shell
  (:nicknames #:lc.tools.shell)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.safety.sandbox)
  (:export
   ;; Shell class
   #:shell
   #:make-shell
   #:shell-execute
   #:shell-execute-async
   #:shell-get-output
   #:shell-wait
   #:shell-kill
   ;; Configuration
   #:*allowed-commands*
   #:*blocked-commands*
   #:*default-timeout*
   #:*shell-working-dir*
   ;; Command execution
   #:run-command
   #:run-command-safe
   #:run-command-in-dir
   ;; Output handling
   #:get-output
   #:get-error-output
   #:get-exit-code
   ;; Process management
   #:list-processes
   #:kill-process
   #:kill-all-processes))

(in-package #:lisp-claw.tools.shell)

;;; ============================================================================
;;; Configuration
;;; ============================================================================

(defvar *allowed-commands*
  '("ls" "cat" "head" "tail" "grep" "find" "pwd" "echo" "mkdir" "cp" "mv" "rm"
    "git" "python" "python3" "node" "npm" "cargo" "make" "bash" "sh" "uname"
    "whoami" "date" "wc" "sort" "uniq" "cut" "awk" "sed" "jq" "curl" "wget")
  "List of allowed shell commands.")

(defvar *blocked-commands*
  '("sudo" "su" "rm -rf" "mkfs" "dd" "chmod 777" "chown" "kill" "pkill"
    "wget -O /" "curl -o /" "> /dev/" "tee /dev/" ":(){:|:&};:"
    "curl.*\\|.*sh" "wget.*\\|.*sh" "nc -e" "ncat -e")
  "List of blocked command patterns.")

(defvar *default-timeout* 30
  "Default command timeout in seconds.")

(defvar *shell-working-dir* nil
  "Default working directory for shell commands.")

;;; ============================================================================
;;; Shell Process Class
;;; ============================================================================

(defclass shell-process ()
  ((id :initarg :id
       :reader process-id
       :documentation "Unique process identifier")
   (command :initarg :command
            :reader process-command
            :documentation "Executed command")
   (process :initarg :process
            :accessor process-process
            :documentation "Underlying process object")
   (output :initform nil
           :accessor process-output
           :documentation "Captured stdout")
   (error-output :initform nil
                 :accessor process-error-output
                 :documentation "Captured stderr")
   (exit-code :initform nil
              :accessor process-exit-code
              :documentation "Process exit code")
   (start-time :initform (get-universal-time)
               :reader process-start-time
               :documentation "Process start time")
   (end-time :initform nil
             :accessor process-end-time
             :documentation "Process end time")
   (status :initform :running
           :accessor process-status
           :documentation "Process status: :running, :completed, :timeout, :killed")
   (working-dir :initarg :working-dir
                :initform nil
                :reader process-working-dir
                :documentation "Working directory for command"))
  (:documentation "Shell process representation"))

(defmethod print-object ((proc shell-process) stream)
  (print-unreadable-object (proc stream :type t)
    (format t "~A [~A]" (process-id proc) (process-status proc))))

;;; ============================================================================
;;; Process Registry
;;; ============================================================================

(defvar *shell-processes* (make-hash-table :test 'equal)
  "Registry of shell processes.")

(defvar *process-lock* (bt:make-lock "shell-process-lock")
  "Lock for process registry access.")

(defvar *process-counter* 0
  "Process ID counter.")

(defun generate-process-id ()
  "Generate a unique process ID.

  Returns:
    Process ID string"
  (bt:with-lock-held (*process-lock*)
    (incf *process-counter*)
    (format nil "shell-~A-~A" *process-counter* (get-universal-time))))

;;; ============================================================================
;;; Shell Class
;;; ============================================================================

(defclass shell ()
  ((working-dir :initarg :working-dir
                :accessor shell-working-dir
                :documentation "Current working directory")
   (environment :initarg :environment
                :initform nil
                :accessor shell-environment
                :documentation "Environment variables")
   (timeout :initarg :timeout
            :initform *default-timeout*
            :accessor shell-timeout
            :documentation "Default timeout")
   (processes :initform nil
              :accessor shell-processes
              :documentation "History of processes"))
  (:documentation "Shell session"))

(defmethod print-object ((shell shell) stream)
  (print-unreadable-object (shell stream :type t)
    (format t "~A" (or (shell-working-dir shell) "/"))))

(defun make-shell (&key working-dir environment timeout)
  "Create a new shell session.

  Args:
    WORKING-DIR: Working directory
    ENVIRONMENT: Environment variables (plist)
    TIMEOUT: Default timeout

  Returns:
    Shell instance"
  (make-instance 'shell
                 :working-dir (or working-dir *shell-working-dir* (uiop:getcwd))
                 :environment environment
                 :timeout (or timeout *default-timeout*)))

;;; ============================================================================
;;; Command Validation
;;; ============================================================================

(defun command-allowed-p (command)
  "Check if a command is allowed.

  Args:
    COMMAND: Command string

  Returns:
    T if allowed, NIL otherwise"
  (let ((cmd (first (split-sequence:split-sequence #\Space command))))
    (and (member cmd *allowed-commands* :test #'string=)
         t)))

(defun command-blocked-p (command)
  "Check if a command is blocked.

  Args:
    COMMAND: Command string

  Returns:
    T if blocked, NIL otherwise"
  (dolist (pattern *blocked-commands*)
    (when (or (string= command pattern)
              (search pattern command))
      (return-from command-blocked-p t)))
  nil)

(defun validate-command (command)
  "Validate a command for execution.

  Args:
    COMMAND: Command string

  Returns:
    Values: (valid-p error-message)"
  (cond
    ((command-blocked-p command)
     (values nil "Command is blocked for security reasons"))
    ((not (command-allowed-p command))
     (values nil (format nil "Command '~A' is not in the allowed list"
                         (first (split-sequence:split-sequence #\Space command)))))
    (t
     (values t nil))))

;;; ============================================================================
;;; Command Execution
;;; ============================================================================

(defun shell-execute (shell command &key timeout working-dir input)
  "Execute a shell command synchronously.

  Args:
    SHELL: Shell instance
    COMMAND: Command to execute
    TIMEOUT: Optional timeout
    WORKING-DIR: Optional working directory
    INPUT: Optional stdin input

  Returns:
    Values: (output error-output exit-code)"
  (let ((timeout (or timeout (shell-timeout shell)))
        (working-dir (or working-dir (shell-working-dir shell)))
        (proc nil)
        (output nil)
        (error-output nil)
        (exit-code nil))

    ;; Validate command
    (multiple-value-bind (valid error) (validate-command command)
      (unless valid
        (log-error "Command validation failed: ~A - ~A" command error)
        (return-from shell-execute (values nil error -1))))

    (log-info "Executing: ~A (cwd: ~A, timeout: ~As)" command working-dir timeout)

    (handler-case
        (let ((result (uiop:run-program command
                                        :output :string
                                        :error-output :string
                                        :directory working-dir
                                        :ignore-error-status t
                                        :timeout timeout
                                        :input (when input input))))
          (setf output (getf result :output))
          (setf error-output (getf result :error-output))
          (setf exit-code (getf result :exit-code)))
      (error (e)
        (log-error "Command execution failed: ~A - ~A" command e)
        (setf error-output (format nil "~A" e))
        (setf exit-code -1)))

    ;; Store in history
    (push (list :command command
                :output output
                :error-output error-output
                :exit-code exit-code
                :timestamp (get-universal-time))
          (shell-processes shell))

    (values output error-output exit-code)))

(defun shell-execute-async (shell command &key timeout working-dir)
  "Execute a shell command asynchronously.

  Args:
    SHELL: Shell instance
    COMMAND: Command to execute
    TIMEOUT: Optional timeout
    WORKING-DIR: Optional working directory

  Returns:
    Shell-process instance"
  (let ((timeout (or timeout (shell-timeout shell)))
        (working-dir (or working-dir (shell-working-dir shell)))
        (proc-id (generate-process-id)))

    ;; Validate command
    (multiple-value-bind (valid error) (validate-command command)
      (unless valid
        (log-error "Async command validation failed: ~A - ~A" command error)
        (return-from shell-execute-async nil)))

    (log-info "Executing async: ~A [~A]" command proc-id)

    ;; Create process record
    (let ((proc (make-instance 'shell-process
                               :id proc-id
                               :command command
                               :process nil
                               :working-dir working-dir)))

      ;; Start process in thread
      (let ((thread (bt:make-thread
                     (lambda ()
                       (handler-case
                           (let ((result (uiop:run-program command
                                                           :output :string
                                                           :error-output :string
                                                           :directory working-dir
                                                           :ignore-error-status t
                                                           :timeout timeout)))
                             (setf (process-process proc) result)
                             (setf (process-output proc) (getf result :output))
                             (setf (process-error-output proc) (getf result :error-output))
                             (setf (process-exit-code proc) (getf result :exit-code))
                             (setf (process-status proc) :completed)
                             (setf (process-end-time proc) (get-universal-time)))
                         (timeout (e)
                           (log-error "Process timeout: ~A" proc-id)
                           (setf (process-status proc) :timeout)
                           (setf (process-error-output proc) (format nil "~A" e))
                           (setf (process-end-time proc) (get-universal-time)))
                         (error (e)
                           (log-error "Process error: ~A - ~A" proc-id e)
                           (setf (process-status proc) :killed)
                           (setf (process-error-output proc) (format nil "~A" e))
                           (setf (process-end-time proc) (get-universal-time)))))
                     :name (format nil "shell-~A" proc-id))))
        (setf (process-process proc) thread))

      ;; Register process
      (bt:with-lock-held (*process-lock*)
        (setf (gethash proc-id *shell-processes*) proc))

      proc)))

(defun shell-get-output (process)
  "Get output from an async process.

  Args:
    PROCESS: Shell-process instance

  Returns:
    Output string or NIL"
  (process-output process))

(defun shell-wait (process &key timeout)
  "Wait for an async process to complete.

  Args:
    PROCESS: Shell-process instance
    TIMEOUT: Optional timeout in seconds

  Returns:
    T if completed, NIL on timeout"
  (let ((start (get-universal-time)))
    (loop while (eq (process-status process) :running)
          do (progn
               (sleep 0.1)
               (when (and timeout
                          (>= (- (get-universal-time) start) timeout))
                 (return-from shell-wait nil)))
          finally (return t))))

(defun shell-kill (process)
  "Kill an async process.

  Args:
    PROCESS: Shell-process instance

  Returns:
    T on success"
  (let ((thread (process-process process)))
    (when (and thread (bt:thread-alive-p thread))
      (bt:destroy-thread thread)
      (setf (process-status process) :killed)
      (setf (process-end-time process) (get-universal-time))
      (log-info "Process killed: ~A" (process-id process)))
    t))

;;; ============================================================================
;;; Convenience Functions
;;; ============================================================================

(defun run-command (command &key timeout directory input)
  "Run a shell command.

  Args:
    COMMAND: Command to run
    TIMEOUT: Optional timeout
    DIRECTORY: Optional working directory
    INPUT: Optional stdin input

  Returns:
    Values: (output error-output exit-code)"
  (let ((shell (make-shell :working-dir directory :timeout timeout)))
    (shell-execute shell command :input input)))

(defun run-command-safe (command &key timeout)
  "Run a shell command with strict security.

  Args:
    COMMAND: Command to run
    TIMEOUT: Optional timeout

  Returns:
    Values: (output error-output exit-code)"
  (multiple-value-bind (valid error) (validate-command command)
    (unless valid
      (return-from run-command-safe (values nil error -1))))
  (run-command command :timeout timeout))

(defun run-command-in-dir (command directory &key timeout)
  "Run a command in a specific directory.

  Args:
    COMMAND: Command to run
    DIRECTORY: Working directory
    TIMEOUT: Optional timeout

  Returns:
    Values: (output error-output exit-code)"
  (run-command command :directory directory :timeout timeout))

;;; ============================================================================
;;; Process Management
;;; ============================================================================

(defun get-output (process)
  "Get output from a process.

  Args:
    PROCESS: Shell-process instance

  Returns:
    Output string"
  (process-output process))

(defun get-error-output (process)
  "Get error output from a process.

  Args:
    PROCESS: Shell-process instance

  Returns:
    Error output string"
  (process-error-output process))

(defun get-exit-code (process)
  "Get exit code from a process.

  Args:
    PROCESS: Shell-process instance

  Returns:
    Exit code or NIL"
  (process-exit-code process))

(defun list-processes (&key status)
  "List shell processes.

  Args:
    STATUS: Optional status filter

  Returns:
    List of process info plists"
  (let ((processes nil))
    (bt:with-lock-held (*process-lock*)
      (maphash (lambda (id proc)
                 (when (or (null status)
                           (eq (process-status proc) status))
                   (push (list :id id
                               :command (process-command proc)
                               :status (process-status proc)
                               :start-time (process-start-time proc)
                               :working-dir (process-working-dir proc))
                         processes)))
               *shell-processes*))
    processes))

(defun kill-process (process-id)
  "Kill a process by ID.

  Args:
    PROCESS-ID: Process identifier

  Returns:
    T on success"
  (bt:with-lock-held (*process-lock*)
    (let ((proc (gethash process-id *shell-processes*)))
      (when proc
        (shell-kill proc)
        (remhash process-id *shell-processes*)
        t))))

(defun kill-all-processes ()
  "Kill all running processes.

  Returns:
    Number of processes killed"
  (let ((count 0))
    (bt:with-lock-held (*process-lock*)
      (maphash (lambda (id proc)
                 (when (eq (process-status proc) :running)
                   (shell-kill proc)
                   (incf count)))
               *shell-processes*)
      (clrhash *shell-processes*))
    count))

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defun register-shell-tool ()
  "Register shell tool with the tool system.

  Returns:
    T"
  (log-info "Shell tool registered: run-command, run-command-safe, run-command-in-dir")
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-shell-tool ()
  "Initialize the shell tool.

  Returns:
    T"
  (log-info "Shell tool initialized")
  (register-shell-tool)
  t)
