;;; tools/registry.lisp --- Tool Registry for Lisp-Claw
;;;
;;; This file implements the central tool registry and management system.

(defpackage #:lisp-claw.tools.registry
  (:nicknames #:lc.tools.registry)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   #:*tool-registry*
   #:tool-definition
   #:make-tool-definition
   #:register-tool
   #:unregister-tool
   #:get-tool
   #:list-tools
   #:execute-tool
   #:tool-exists-p
   #:register-all-tools
   #:clear-tools))

(in-package #:lisp-claw.tools.registry)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *tool-registry* (make-hash-table :test 'equal)
  "Central registry of all available tools.
   Key: tool name (string)
   Value: tool-definition instance")

(defvar *tool-call-history* (make-hash-table :test 'equal)
  "History of tool calls for rate limiting and analytics.")

(defvar *tool-rate-limits* (make-hash-table :test 'equal)
  "Rate limits per tool (calls per minute).")

;;; ============================================================================
;;; Tool Definition Class
;;; ============================================================================

(defclass tool-definition ()
  ((name :initarg :name
         :reader tool-name
         :documentation "Tool name")
   (description :initarg :description
                :reader tool-description
                :documentation "Tool description")
   (handler :initarg :handler
            :reader tool-handler
            :documentation "Tool handler function")
   (parameters :initarg :parameters
               :initform nil
               :reader tool-parameters
               :documentation "JSON Schema for parameters")
   (enabled :initform t
            :accessor tool-enabled
            :documentation "Whether tool is enabled")
   (rate-limit :initarg :rate-limit
               :initform nil
               :reader tool-rate-limit
               :documentation "Max calls per minute")
   (call-count :initform 0
               :accessor tool-call-count
               :documentation "Number of times called")
   (last-called :initform nil
                :accessor tool-last-called
                :documentation "When tool was last called"))
  (:documentation "Definition of a registered tool"))

(defmethod print-object ((tool tool-definition) stream)
  "Print tool representation."
  (print-unreadable-object (tool stream :type t)
    (format stream "~A [~:[disabled~;enabled~]"
            (tool-name tool)
            (tool-enabled tool))))

(defun make-tool-definition (name handler description &key parameters rate-limit)
  "Create a tool definition.

  Args:
    NAME: Tool name
    HANDLER: Handler function
    DESCRIPTION: Tool description
    PARAMETERS: JSON Schema for parameters
    RATE-LIMIT: Max calls per minute

  Returns:
    Tool-definition instance"
  (make-instance 'tool-definition
                 :name name
                 :handler handler
                 :description description
                 :parameters parameters
                 :rate-limit rate-limit))

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defun register-tool (name handler description &key parameters rate-limit)
  "Register a tool.

  Args:
    NAME: Tool name
    HANDLER: Handler function
    DESCRIPTION: Tool description
    PARAMETERS: JSON Schema for parameters
    RATE-LIMIT: Max calls per minute

  Returns:
    T on success"
  (let ((tool (make-tool-definition name handler description
                                    :parameters parameters
                                    :rate-limit rate-limit)))
    (setf (gethash name *tool-registry*) tool)
    (when rate-limit
      (setf (gethash name *tool-rate-limits*) rate-limit))
    (log-info "Registered tool: ~A" name)
    t))

(defun unregister-tool (name)
  "Unregister a tool.

  Args:
    NAME: Tool name

  Returns:
    T on success"
  (remhash name *tool-registry*)
  (remhash name *tool-rate-limits*)
  (log-debug "Unregistered tool: ~A" name)
  t)

(defun get-tool (name)
  "Get a tool definition.

  Args:
    NAME: Tool name

  Returns:
    Tool-definition or NIL"
  (gethash name *tool-registry*))

(defun list-tools (&key enabled-only)
  "List all registered tools.

  Args:
    ENABLED-ONLY: Only list enabled tools

  Returns:
    List of tool names"
  (loop for name being the hash-keys of *tool-registry*
        for tool = (gethash name *tool-registry*)
        when (or (not enabled-only) (tool-enabled tool))
        collect name))

(defun tool-exists-p (name)
  "Check if a tool is registered.

  Args:
    NAME: Tool name

  Returns:
    T if registered"
  (and (gethash name *tool-registry*) t))

(defun clear-tools ()
  "Clear all registered tools.

  Returns:
    T"
  (clrhash *tool-registry*)
  (clrhash *tool-rate-limits*)
  (clrhash *tool-call-history*)
  (log-warn "All tools cleared")
  t)

;;; ============================================================================
;;; Tool Execution
;;; ============================================================================

(defun execute-tool (name arguments)
  "Execute a tool.

  Args:
    NAME: Tool name
    ARGUMENTS: Tool arguments (JSON-compatible)

  Returns:
    Tool execution result"
  (let ((tool (get-tool name)))
    (unless tool
      (return-from execute-tool
        (values nil (format nil "Unknown tool: ~A" name))))

    (unless (tool-enabled tool)
      (return-from execute-tool
        (values nil (format nil "Tool disabled: ~A" name))))

    ;; Rate limiting check
    (unless (check-rate-limit name)
      (return-from execute-tool
        (values nil (format nil "Rate limit exceeded for: ~A" name))))

    ;; Execute tool
    (incf (tool-call-count tool))
    (setf (tool-last-called tool) (get-universal-time))

    ;; Record call history
    (record-tool-call name)

    (handler-case
        (let ((result (funcall (tool-handler tool) arguments)))
          (log-debug "Tool executed: ~A" name)
          (values result nil))

      (error (e)
        (log-error "Tool execution error ~A: ~A" name e)
        (values nil (format nil "Tool error: ~A" e))))))

(defun check-rate-limit (tool-name)
  "Check if tool is within rate limit.

  Args:
    TOOL-NAME: Tool name

  Returns:
    T if within limit"
  (let ((limit (gethash tool-name *tool-rate-limits*)))
    (unless limit
      ;; No limit set
      (return-from check-rate-limit t))

    (let* ((now (get-universal-time))
           (one-minute-ago (- now 60))
           (calls (gethash tool-name *tool-call-history*)))
      ;; Count recent calls
      (let ((recent-calls (loop for call-time in calls
                                when (> call-time one-minute-ago)
                                count it)))
        (< recent-calls limit)))))

(defun record-tool-call (tool-name)
  "Record a tool call for rate limiting.

  Args:
    TOOL-NAME: Tool name"
  (let ((now (get-universal-time))
        (calls (gethash tool-name *tool-call-history*)))
    (setf (gethash tool-name *tool-call-history*)
          (append (or calls nil) (list now)))))

;;; ============================================================================
;;; Tool Schema Generation
;;; ============================================================================

(defun tool-to-json-schema (tool)
  "Convert tool definition to JSON Schema.

  Args:
    TOOL: Tool-definition

  Returns:
    JSON Schema object"
  `(("type" . "function")
    ("function" . (("name" . ,(tool-name tool))
                   ("description" . ,(tool-description tool))
                   ("parameters" . ,(tool-parameters tool))))))

(defun tools-to-openai-format ()
  "Export all tools to OpenAI function calling format.

  Returns:
    List of tool definitions"
  (loop for name in (list-tools :enabled-only t)
        for tool = (get-tool name)
        collect (tool-to-json-schema tool)))

(defun tools-to-anthropic-format ()
  "Export all tools to Anthropic tool calling format.

  Returns:
    List of tool definitions"
  (loop for name in (list-tools :enabled-only t)
        for tool = (get-tool name)
        collect `(("name" . ,(tool-name tool))
                  ("description" . ,(tool-description tool))
                  ("input_schema" . ,(tool-parameters tool)))))

;;; ============================================================================
;;; Built-in Tool Registration
;;; ============================================================================

(defun register-all-tools ()
  "Register all available tools.

  Returns:
    T on success"
  (log-info "Registering all tools...")

  ;; Register browser tools
  (let ((browser-register (find-symbol "REGISTER-BROWSER-TOOLS" '#:lisp-claw.tools.browser)))
    (when browser-register
      (funcall browser-register)))

  ;; Register file tools
  (let ((files-register (find-symbol "REGISTER-FILE-TOOLS" '#:lisp-claw.tools.files)))
    (when files-register
      (funcall files-register)))

  ;; Register system tools
  (let ((system-register (find-symbol "REGISTER-SYSTEM-TOOLS" '#:lisp-claw.tools.system)))
    (when system-register
      (funcall system-register)))

  ;; Register canvas tools
  (let ((canvas-register (find-symbol "REGISTER-CANVAS-TOOLS" '#:lisp-claw.tools.canvas)))
    (when canvas-register
      (funcall canvas-register)))

  (log-info "All tools registered: ~A" (length (list-tools)))
  t)

(defun enable-tool (name)
  "Enable a tool.

  Args:
    NAME: Tool name

  Returns:
    T on success"
  (let ((tool (get-tool name)))
    (when tool
      (setf (tool-enabled tool) t)
      t)))

(defun disable-tool (name)
  "Disable a tool.

  Args:
    NAME: Tool name

  Returns:
    T on success"
  (let ((tool (get-tool name)))
    (when tool
      (setf (tool-enabled tool) nil)
      t)))

(defun configure-tool-rate-limit (name limit)
  "Configure tool rate limit.

  Args:
    NAME: Tool name
    LIMIT: Calls per minute

  Returns:
    T on success"
  (setf (gethash name *tool-rate-limits*) limit)
  (log-info "Tool ~A rate limit set to ~A/min" name limit)
  t)

;;; ============================================================================
;;; Tool Call Analytics
;;; ============================================================================

(defun get-tool-stats (name)
  "Get tool usage statistics.

  Args:
    NAME: Tool name

  Returns:
    Stats plist"
  (let ((tool (get-tool name)))
    (when tool
      `(:name ,(tool-name tool)
        :calls ,(tool-call-count tool)
        :last-called ,(tool-last-called tool)
        :enabled ,(tool-enabled tool)
        :rate-limit ,(tool-rate-limit tool)))))

(defun get-all-tool-stats ()
  "Get statistics for all tools.

  Returns:
    List of stats plists"
  (loop for name in (list-tools)
        for stats = (get-tool-stats name)
        when stats collect stats))

(defun reset-tool-stats (name)
  "Reset tool usage statistics.

  Args:
    NAME: Tool name

  Returns:
    T on success"
  (let ((tool (get-tool name)))
    (when tool
      (setf (tool-call-count tool) 0)
      (setf (tool-last-called tool) nil)
      t)))
