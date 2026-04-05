;;; safety/sandbox.lisp --- Safety Sandbox for Lisp-Claw
;;;
;;; This file implements security sandboxing for Lisp-Claw,
;;; similar to OpenClaw's safety system for execution control.

(defpackage #:lisp-claw.safety.sandbox
  (:nicknames #:lc.safety.sandbox)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.config.loader
        #:lisp-claw.agents.workspace)
  (:export
   ;; Security policy
   #:security-policy
   #:make-security-policy
   #:policy-allowed-tools
   #:policy-blocked-tools
   #:policy-allowed-models
   #:policy-blocked-models
   #:policy-max-tokens
   #:policy-require-confirmation
   #:policy-allowed-commands
   #:policy-blocked-commands
   #:policy-max-memory
   #:policy-network-allowed
   ;; Sandbox
   #:sandbox
   #:make-sandbox
   #:sandbox-policy
   #:sandbox-context
   ;; Execution control
   #:execute-in-sandbox
   #:validate-tool-call
   #:validate-model-request
   #:validate-command
   #:check-command-allowed
   ;; Confirmation
   #:request-confirmation
   #:confirmation-pending-p
   #:approve-confirmation
   #:deny-confirmation
   ;; Audit logging
   #:log-security-event
   #:get-security-log
   #:clear-security-log
   ;; Safety checks
   #:check-safety
   #:safety-violation
   #:safety-warning
   ;; Built-in policies
   #:make-safe-policy
   #:make-strict-policy
   #:make-permissive-policy))

(in-package #:lisp-claw.safety.sandbox)

;;; ============================================================================
;;; Security Policy
;;; ============================================================================

(defclass security-policy ()
  ((allowed-tools :initarg :allowed-tools
                  :initform nil
                  :accessor policy-allowed-tools
                  :documentation "List of allowed tool names")
   (blocked-tools :initarg :blocked-tools
                  :initform nil
                  :accessor policy-blocked-tools
                  :documentation "List of blocked tool names")
   (allowed-models :initarg :allowed-models
                   :initform nil
                   :accessor policy-allowed-models
                   :documentation "List of allowed model IDs")
   (blocked-models :initarg :blocked-models
                   :initform nil
                   :accessor policy-blocked-models
                   :documentation "List of blocked model IDs")
   (max-tokens :initarg :max-tokens
               :initform 4096
               :accessor policy-max-tokens
               :documentation "Maximum tokens per response")
   (require-confirmation :initarg :require-confirmation
                         :initform nil
                         :accessor policy-require-confirmation
                         :documentation "Whether to require confirmation")
   (confirmation-threshold :initarg :confirmation-threshold
                           :initform 0
                           :accessor policy-confirmation-threshold
                           :documentation "Risk threshold requiring confirmation")
   (allowed-commands :initarg :allowed-commands
                     :initform nil
                     :accessor policy-allowed-commands
                     :documentation "List of allowed shell commands")
   (blocked-commands :initarg :blocked-commands
                     :initform '("sudo" "rm -rf" "mkfs" "dd" "chmod 777")
                     :accessor policy-blocked-commands
                     :documentation "List of blocked shell commands")
   (max-memory :initarg :max-memory
               :initform (* 1024 1024 1024)  ; 1GB
               :accessor policy-max-memory
               :documentation "Maximum memory usage in bytes")
   (network-allowed :initarg :network-allowed
                    :initform t
                    :accessor policy-network-allowed
                    :documentation "Whether network access is allowed")
   (blocked-hosts :initarg :blocked-hosts
                  :initform nil
                  :accessor policy-blocked-hosts
                  :documentation "List of blocked network hosts")
   (allowed-hosts :initarg :allowed-hosts
                  :initform nil
                  :accessor policy-allowed-hosts
                  :documentation "List of allowed network hosts")
   (file-read-only :initarg :file-read-only
                   :initform nil
                   :accessor policy-file-read-only
                   :documentation "Whether file system is read-only")
   (allowed-paths :initarg :allowed-paths
                  :initform nil
                  :accessor policy-allowed-paths
                  :documentation "List of allowed file paths")
   (blocked-paths :initarg :blocked-paths
                  :initform '("/etc" "/root" "/var" "/proc")
                  :accessor policy-blocked-paths
                  :documentation "List of blocked file paths"))
  (:documentation "Security policy definition"))

(defmethod print-object ((policy security-policy) stream)
  (print-unreadable-object (policy stream :type t)
    (format stream "~A tools, ~A models"
            (length (policy-allowed-tools policy))
            (length (policy-allowed-models policy)))))

(defun make-security-policy (&key
                             allowed-tools
                             blocked-tools
                             allowed-models
                             blocked-models
                             max-tokens
                             require-confirmation
                             confirmation-threshold
                             allowed-commands
                             blocked-commands
                             max-memory
                             network-allowed
                             blocked-hosts
                             allowed-hosts
                             file-read-only
                             allowed-paths
                             blocked-paths)
  "Create a security policy.

  Args:
    ALLOWED-TOOLS: List of allowed tools
    BLOCKED-TOOLS: List of blocked tools
    ALLOWED-MODELS: List of allowed models
    BLOCKED-MODELS: List of blocked models
    MAX-TOKENS: Maximum tokens
    REQUIRE-CONFIRMATION: Require confirmation flag
    CONFIRMATION-THRESHOLD: Risk threshold
    ALLOWED-COMMANDS: Allowed shell commands
    BLOCKED-COMMANDS: Blocked shell commands
    MAX-MEMORY: Maximum memory
    NETWORK-ALLOWED: Network access flag
    BLOCKED-HOSTS: Blocked hosts
    ALLOWED-HOSTS: Allowed hosts
    FILE-READ-ONLY: Read-only file system
    ALLOWED-PATHS: Allowed paths
    BLOCKED-PATHS: Blocked paths

  Returns:
    Security policy instance"
  (make-instance 'security-policy
                 :allowed-tools (or allowed-tools nil)
                 :blocked-tools (or blocked-tools nil)
                 :allowed-models (or allowed-models nil)
                 :blocked-models (or blocked-models nil)
                 :max-tokens (or max-tokens 4096)
                 :require-confirmation (or require-confirmation nil)
                 :confirmation-threshold (or confirmation-threshold 0)
                 :allowed-commands (or allowed-commands nil)
                 :blocked-commands (or blocked-commands '("sudo" "rm -rf" "mkfs" "dd" "chmod 777"))
                 :max-memory (or max-memory (* 1024 1024 1024))
                 :network-allowed (or network-allowed t)
                 :blocked-hosts (or blocked-hosts nil)
                 :allowed-hosts (or allowed-hosts nil)
                 :file-read-only (or file-read-only nil)
                 :allowed-paths (or allowed-paths nil)
                 :blocked-paths (or blocked-paths '("/etc" "/root" "/var" "/proc"))))

;;; ============================================================================
;;; Sandbox
;;; ============================================================================

(defclass sandbox ()
  ((policy :initarg :policy
           :reader sandbox-policy
           :documentation "Security policy")
   (context :initform (make-hash-table :test 'equal)
            :accessor sandbox-context
            :documentation "Execution context")
   (event-log :initform (make-array 1000 :adjustable t :fill-pointer 0)
              :accessor sandbox-event-log
              :documentation "Security event log")
   (lock :initform (bt:make-lock)
         :reader sandbox-lock
         :documentation "Lock for thread safety"))
  (:documentation "Execution sandbox"))

(defmethod print-object ((sandbox sandbox) stream)
  (print-unreadable-object (sandbox stream :type t)
    (format stream "~A events logged"
            (length (sandbox-event-log sandbox)))))

(defun make-sandbox (&key policy)
  "Create a sandbox.

  Args:
    POLICY: Security policy

  Returns:
    Sandbox instance"
  (make-instance 'sandbox :policy (or policy (make-safe-policy))))

;;; ============================================================================
;;; Execution Control
;;; ============================================================================

(defun execute-in-sandbox (sandbox function &rest args)
  "Execute a function in the sandbox.

  Args:
    SANDBOX: Sandbox instance
    FUNCTION: Function to execute
    ARGS: Function arguments

  Returns:
    Function result or security error"
  (bt:with-lock-held ((sandbox-lock sandbox))
    (handler-case
        (progn
          ;; Log execution start
          (log-security-event sandbox :execution-start (format nil "Executing: ~A" function))

          ;; Check memory usage
          (let ((usage (get-memory-usage)))
            (when (> usage (policy-max-memory (sandbox-policy sandbox)))
              (log-security-event sandbox :violation "Memory limit exceeded")
              (return-from execute-in-sandbox
                (list :success nil :error "Memory limit exceeded"))))

          ;; Execute function
          (let ((result (apply function args)))
            (log-security-event sandbox :execution-complete "Execution completed")
            (list :success t :result result)))

      (error (e)
        (log-security-event sandbox :error (format nil "Execution error: ~A" e))
        (list :success nil :error (format nil "~A" e))))))

(defun validate-tool-call (sandbox tool-name args)
  "Validate a tool call against the security policy.

  Args:
    SANDBOX: Sandbox instance
    TOOL-NAME: Tool name
    ARGS: Tool arguments

  Returns:
    Validation result plist"
  (let ((policy (sandbox-policy sandbox)))
    ;; Check if tool is blocked
    (when (member tool-name (policy-blocked-tools policy) :test #'string=)
      (log-security-event sandbox :blocked (format nil "Blocked tool: ~A" tool-name))
      (return-from validate-tool-call
        (list :allowed nil :reason "Tool is blocked")))

    ;; Check if tool is allowed (if allowlist exists)
    (when (and (policy-allowed-tools policy)
               (not (member tool-name (policy-allowed-tools policy) :test #'string=)))
      (log-security-event sandbox :blocked (format nil "Tool not in allowlist: ~A" tool-name))
      (return-from validate-tool-call
        (list :allowed nil :reason "Tool not in allowlist")))

    ;; Check confirmation requirement
    (when (and (policy-require-confirmation policy)
               (tool-requires-confirmation-p tool-name args policy))
      (log-security-event sandbox :confirmation-pending (format nil "Confirmation required: ~A" tool-name))
      (return-from validate-tool-call
        (list :allowed nil :reason "Confirmation required" :confirmation-pending t)))

    ;; All checks passed
    (log-security-event sandbox :allowed (format nil "Tool allowed: ~A" tool-name))
    (list :allowed t)))

(defun tool-requires-confirmation-p (tool-name args policy)
  "Check if a tool call requires confirmation.

  Args:
    TOOL-NAME: Tool name
    ARGS: Tool arguments
    POLICY: Security policy

  Returns:
    T if confirmation required"
  ;; Check risk threshold
  (let ((risk (calculate-tool-risk tool-name args)))
    (when (> risk (policy-confirmation-threshold policy))
      (return-from tool-requires-confirmation-p t)))

  ;; Check specific tools
  (when (member tool-name '("shell-execute" "file-write" "network-request")
                :test #'string=)
    (return-from tool-requires-confirmation-p t))

  nil)

(defun calculate-tool-risk (tool-name args)
  "Calculate risk score for a tool call.

  Args:
    TOOL-NAME: Tool name
    ARGS: Tool arguments

  Returns:
    Risk score (0-10)"
  (let ((base-risk
         (case (if (keywordp tool-name) tool-name (intern (string-upcase tool-name) :keyword))
           ((:shell-execute :system-command) 8)
           ((:file-write :file-delete) 7)
           ((:network-request :http-client) 5)
           ((:file-read :file-list) 3)
           (otherwise 5))))

    ;; Adjust based on arguments
    (let ((adjusted base-risk))
      ;; Check for dangerous patterns in arguments
      (dolist (arg args)
        (when (and (stringp arg)
                   (or (search "sudo" arg)
                       (search "rm -rf" arg)
                       (search "/etc" arg)))
          (incf adjusted 2)))

      (min 10 adjusted))))

(defun validate-model-request (sandbox model-id tokens)
  "Validate a model request against the security policy.

  Args:
    SANDBOX: Sandbox instance
    MODEL-ID: Model identifier
    TOKENS: Requested token count

  Returns:
    Validation result plist"
  (let ((policy (sandbox-policy sandbox)))
    ;; Check if model is blocked
    (when (member model-id (policy-blocked-models policy) :test #'string=)
      (log-security-event sandbox :blocked (format nil "Blocked model: ~A" model-id))
      (return-from validate-model-request
        (list :allowed nil :reason "Model is blocked")))

    ;; Check if model is allowed (if allowlist exists)
    (when (and (policy-allowed-models policy)
               (not (member model-id (policy-allowed-models policy) :test #'string=)))
      (log-security-event sandbox :blocked (format nil "Model not in allowlist: ~A" model-id))
      (return-from validate-model-request
        (list :allowed nil :reason "Model not in allowlist")))

    ;; Check token limit
    (when (> tokens (policy-max-tokens policy))
      (log-security-event sandbox :blocked (format nil "Token limit exceeded: ~A > ~A"
                                                   tokens (policy-max-tokens policy)))
      (return-from validate-model-request
        (list :allowed nil :reason "Token limit exceeded")))

    ;; All checks passed
    (log-security-event sandbox :allowed (format nil "Model allowed: ~A" model-id))
    (list :allowed t)))

(defun validate-command (sandbox command)
  "Validate a shell command against the security policy.

  Args:
    SANDBOX: Sandbox instance
    COMMAND: Command string

  Returns:
    Validation result plist"
  (let ((policy (sandbox-policy sandbox)))
    ;; Parse command
    (let ((cmd-name (first (split-sequence:split-sequence #\Space command))))
      ;; Check if command is blocked
      (when (member cmd-name (policy-blocked-commands policy) :test #'string=)
        (log-security-event sandbox :blocked (format nil "Blocked command: ~A" command))
        (return-from validate-command
          (list :allowed nil :reason "Command is blocked")))

      ;; Check if command is allowed (if allowlist exists)
      (when (and (policy-allowed-commands policy)
                 (not (member cmd-name (policy-allowed-commands policy) :test #'string=)))
        (log-security-event sandbox :blocked (format nil "Command not in allowlist: ~A" command))
        (return-from validate-command
          (list :allowed nil :reason "Command not in allowlist")))

      ;; Check for dangerous patterns
      (when (has-dangerous-pattern-p command)
        (log-security-event sandbox :blocked (format nil "Dangerous pattern: ~A" command))
        (return-from validate-command
          (list :allowed nil :reason "Dangerous pattern detected")))

      ;; All checks passed
      (log-security-event sandbox :allowed (format nil "Command allowed: ~A" command))
      (list :allowed t))))

(defun check-command-allowed (command)
  "Check if a command is allowed.

  Args:
    COMMAND: Command string

  Returns:
    T if allowed"
  (let ((blocked-commands '("sudo" "rm -rf" "mkfs" "dd" "chmod 777"
                            "fdisk" "parted" "mount" "umount"
                            "wget" "curl" "nc" "netcat")))
    (let ((cmd-name (first (split-sequence:split-sequence #\Space command))))
      (not (member cmd-name blocked-commands :test #'string=)))))

(defun has-dangerous-pattern-p (command)
  "Check if command has dangerous patterns.

  Args:
    COMMAND: Command string

  Returns:
    T if dangerous"
  (let ((dangerous-patterns '("sudo" "rm -rf" "mkfs" "dd if=" "chmod 777"
                              "/etc/passwd" "/etc/shadow" "/root" "/proc"
                              "| sh" "| bash" "&& rm" "|| rm")))
    (dolist (pattern dangerous-patterns)
      (when (search pattern command :test #'char-equal)
        (return-from has-dangerous-pattern-p t)))
    nil))

;;; ============================================================================
;;; Confirmation System
;;; ============================================================================

(defvar *confirmation-requests* (make-hash-table :test 'equal)
  "Pending confirmation requests.")

(defvar *confirmation-lock* (bt:make-lock)
  "Lock for confirmation access.")

(defun request-confirmation (sandbox action description &key timeout)
  "Request user confirmation for an action.

  Args:
    SANDBOX: Sandbox instance
    ACTION: Action identifier
    DESCRIPTION: Action description
    TIMEOUT: Timeout in seconds

  Returns:
    Confirmation ID or NIL"
  (let ((id (uuid:make-uuid)))
    (bt:with-lock-held (*confirmation-lock*)
      (setf (gethash id *confirmation-requests*)
            (list :action action
                  :description description
                  :status :pending
                  :created-at (get-universal-time)
                  :timeout timeout))

      (log-security-event sandbox :confirmation-requested
                          (format nil "~A: ~A" action description))

      ;; In production, would notify user through UI
      (format t "~%[CONFIRMATION REQUIRED]~%")
      (format t "Action: ~A~%" action)
      (format t "Description: ~A~%" description)
      (format t "Approve? (y/n): ")
      (finish-output)

      id)))

(defun confirmation-pending-p (id)
  "Check if confirmation is pending.

  Args:
    ID: Confirmation ID

  Returns:
    T if pending"
  (bt:with-lock-held (*confirmation-lock*)
    (let ((req (gethash id *confirmation-requests*)))
      (when req
        (eq (getf req :status) :pending)))))

(defun approve-confirmation (id)
  "Approve a confirmation request.

  Args:
    ID: Confirmation ID

  Returns:
    T on success"
  (bt:with-lock-held (*confirmation-lock*)
    (let ((req (gethash id *confirmation-requests*)))
      (when req
        (setf (getf req :status) :approved)
        (setf (getf req :decided-at) (get-universal-time))
        t))))

(defun deny-confirmation (id)
  "Deny a confirmation request.

  Args:
    ID: Confirmation ID

  Returns:
    T on success"
  (bt:with-lock-held (*confirmation-lock*)
    (let ((req (gethash id *confirmation-requests*)))
      (when req
        (setf (getf req :status) :denied)
        (setf (getf req :decided-at) (get-universal-time))
        t))))

;;; ============================================================================
;;; Audit Logging
;;; ============================================================================

(defun log-security-event (sandbox type description &rest details)
  "Log a security event.

  Args:
    SANDBOX: Sandbox instance
    TYPE: Event type
    DESCRIPTION: Event description
    DETAILS: Additional details

  Returns:
    T"
  (bt:with-lock-held ((sandbox-lock sandbox))
    (let ((event (list :timestamp (get-universal-time)
                       :type type
                       :description description
                       :details details)))
      (vector-push-extend event (sandbox-event-log sandbox))))
  t)

(defun get-security-log (sandbox &key limit type)
  "Get security event log.

  Args:
    SANDBOX: Sandbox instance
    LIMIT: Maximum entries
    TYPE: Filter by type

  Returns:
    List of events"
  (let ((log nil))
    (bt:with-lock-held ((sandbox-lock sandbox))
      (let ((len (length (sandbox-event-log sandbox))))
        (loop for i from (1- len) downto 0
              for event = (aref (sandbox-event-log sandbox) i)
              when (or (null type)
                       (eq (getf event :type) type))
              do (push event log)
              when (and limit (>= (length log) limit))
              do (return))))
    log))

(defun clear-security-log (sandbox)
  "Clear security event log.

  Args:
    SANDBOX: Sandbox instance

  Returns:
    T"
  (bt:with-lock-held ((sandbox-lock sandbox))
    (setf (sandbox-event-log sandbox)
          (make-array 1000 :adjustable t :fill-pointer 0)))
  t)

;;; ============================================================================
;;; Safety Checks
;;; ============================================================================

(defun check-safety (sandbox action &key tool model command)
  "Perform comprehensive safety check.

  Args:
    SANDBOX: Sandbox instance
    ACTION: Action type
    TOOL: Tool info (if applicable)
    MODEL: Model info (if applicable)
    COMMAND: Command info (if applicable)

  Returns:
    Safety check result"
  (cond
    ((string= action "tool")
     (validate-tool-call sandbox (getf tool :name) (getf tool :args)))

    ((string= action "model")
     (validate-model-request sandbox (getf model :id) (getf model :tokens)))

    ((string= action "command")
     (validate-command sandbox command))

    (t
     (list :success nil :error "Unknown action type"))))

(defun safety-violation (sandbox message &key action severity)
  "Record a safety violation.

  Args:
    SANDBOX: Sandbox instance
    MESSAGE: Violation message
    ACTION: Action taken
    SEVERITY: Severity level

  Returns:
    T"
  (log-security-event sandbox :violation message
                      :action action
                      :severity (or severity :low))
  t)

(defun safety-warning (sandbox message &key context)
  "Record a safety warning.

  Args:
    SANDBOX: Sandbox instance
    MESSAGE: Warning message
    CONTEXT: Additional context

  Returns:
    T"
  (log-security-event sandbox :warning message :context context)
  t)

;;; ============================================================================
;;; Pre-defined Policies
;;; ============================================================================

(defun make-safe-policy ()
  "Create a balanced safe policy.

  Returns:
    Security policy instance"
  (make-security-policy
   :blocked-tools '("shell-sudo" "system-exec" "dangerous-operation")
   :blocked-commands '("sudo" "rm -rf" "mkfs" "dd" "chmod 777")
   :max-tokens 4096
   :require-confirmation t
   :confirmation-threshold 5
   :network-allowed t
   :file-read-only nil))

(defun make-strict-policy ()
  "Create a strict security policy.

  Returns:
    Security policy instance"
  (make-security-policy
   :allowed-tools '("file-read" "chat" "memory-search")
   :blocked-tools '("shell-execute" "file-write" "file-delete" "network-request")
   :allowed-models '("claude-sonnet-4-6")
   :max-tokens 2048
   :require-confirmation t
   :confirmation-threshold 0
   :network-allowed nil
   :file-read-only t
   :allowed-paths '("./" "~/projects/")))

(defun make-permissive-policy ()
  "Create a permissive security policy.

  Returns:
    Security policy instance"
  (make-security-policy
   :blocked-tools '("shell-sudo" "dangerous-operation")
   :blocked-commands '("sudo" "rm -rf /" "mkfs" "dd")
   :max-tokens 8192
   :require-confirmation nil
   :confirmation-threshold 8
   :network-allowed t
   :file-read-only nil))

;;; ============================================================================
;;; Policy from Workspace
;;; ============================================================================

(defun policy-from-workspace (workspace)
  "Create security policy from workspace configuration.

  Args:
    WORKSPACE: Workspace instance

  Returns:
    Security policy instance"
  (let ((policy-config (workspace-policy workspace)))
    (if policy-config
        (make-security-policy
         :allowed-tools (getf policy-config :allowed-tools)
         :blocked-tools (getf policy-config :blocked-tools)
         :max-tokens (getf policy-config :max-tokens)
         :require-confirmation (getf policy-config :require-confirmation))
        (make-safe-policy))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defvar *default-sandbox* nil
  "Default sandbox instance.")

(defun initialize-sandbox-system ()
  "Initialize the sandbox system.

  Returns:
    T"
  (setf *default-sandbox* (make-sandbox :policy (make-safe-policy)))
  (log-info "Sandbox system initialized")
  t)

(defun get-default-sandbox ()
  "Get the default sandbox.

  Returns:
    Sandbox instance"
  (or *default-sandbox*
      (setf *default-sandbox* (make-sandbox))))
