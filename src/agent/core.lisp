;;; core.lisp --- AI Agent Core for Lisp-Claw
;;;
;;; This file implements the core AI agent functionality
;;; including request processing and response handling.

(defpackage #:lisp-claw.agent.core
  (:nicknames #:lc.agent.core)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.agent.session
        #:lisp-claw.agent.models
        #:lisp-claw.agent.providers.base)
  (:export
   #:*agent-config*
   #:agent-request
   #:process-agent-request
   #:stream-agent-response
   #:invoke-tool
   #:handle-tool-call
   #:agent-error-handler))

(in-package #:lisp-claw.agent.core)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *agent-config* nil
  "Global agent configuration.")

(defvar *pending-requests* (make-hash-table :test 'equal)
  "Hash table of pending agent requests.")

(defvar *request-counter* 0
  "Counter for request IDs.")

;;; ============================================================================
;;; Agent Request Processing
;;; ============================================================================

(defun agent-request (session-id message &key model thinking-level verbose-level stream)
  "Make an agent request.

  Args:
    SESSION-ID: Session identifier
    MESSAGE: User message
    MODEL: Optional model override
    THINKING-LEVEL: Optional thinking level
    VERBOSE-LEVEL: Optional verbosity level
    STREAM: Whether to stream response

  Returns:
    Agent response"
  (let ((session (get-session session-id)))
    (unless session
      (error 'agent-error :message "Session not found")))

  ;; Get model from session or override
  (let ((model (or model (session-model session))))
    ;; Build request
    (let ((request `(:session-id ,session-id
                     :message ,message
                     :model ,model
                     :thinking-level ,(or thinking-level :medium)
                     :verbose-level ,(or verbose-level :normal)
                     :stream ,(or stream nil)
                     :timestamp ,(get-universal-time))))

      ;; Process request
      (process-agent-request request))))

(defun process-agent-request (request)
  "Process an agent request.

  Args:
    REQUEST: Request plist

  Returns:
    Agent response"
  (let* ((session-id (plist-get request :session-id))
         (message (plist-get request :message))
         (model (plist-get request :model))
         (stream-p (plist-get request :stream))
         (session (get-session session-id)))

    (unless session
      (error 'agent-error :message "Session not found"))

    ;; Get provider
    (multiple-value-bind (provider model-name)
        (parse-model-string model)
      (unless provider
        (error 'agent-error :message (format nil "Invalid model: ~A" model)))

      ;; Get provider implementation
      (let ((provider-fn (get-provider provider)))
        (unless provider-fn
          (error 'agent-error :message (format nil "Unknown provider: ~A" provider)))

        ;; Build messages for API
        (let ((messages (build-messages session-id request)))
          (if stream-p
              (stream-agent-response provider-fn model-name messages request)
              (invoke-provider provider-fn model-name messages request)))))))

(defun build-messages (session-id request)
  "Build message list for API request.

  Args:
    SESSION-ID: Session identifier
    REQUEST: Request plist

  Returns:
    List of message alists"
  (let* ((session (get-session session-id))
         (history (session-get-history session-id :limit 50))
         (thinking-level (plist-get request :thinking-level))
         (system-prompt (build-system-prompt thinking-level)))

    ;; Build messages array
    (cons `(:role "system" :content ,system-prompt)
          (loop for msg in history
                collect `(:role ,(string (plist-get msg :role))
                          :content ,(plist-get msg :content))))))

(defun build-system-prompt (thinking-level)
  "Build system prompt based on thinking level.

  Args:
    THINKING-LEVEL: Thinking level keyword

  Returns:
    System prompt string"
  (let ((base-prompt "You are a helpful AI assistant."))
    (case thinking-level
      (:off base-prompt)
      (:minimal (concatenate 'string base-prompt " Think briefly before responding."))
      (:low (concatenate 'string base-prompt " Think carefully before responding."))
      (:medium (concatenate 'string base-prompt " Think thoroughly before responding."))
      (:high (concatenate 'string base-prompt " Think very deeply and systematically."))
      (:xhigh (concatenate 'string base-prompt " Engage in extensive reasoning and analysis."))
      (otherwise base-prompt))))

;;; ============================================================================
;;; Streaming Response
;;; ============================================================================

(defun stream-agent-response (provider-fn model-name messages request)
  "Stream agent response.

  Args:
    PROVIDIER-FN: Provider function
    MODEL-NAME: Model name
    MESSAGES: Message list
    REQUEST: Request plist

  Returns:
    Streaming response handle"
  (let ((response-channels (bt:make-condition-variable))
        (response-queue (make-instance 'thread-queue))
        (response-text "")
        (done-p nil))

    ;; Start streaming in background
    (bt:make-thread
     (lambda ()
       (handler-case
           (funcall provider-fn model-name messages
                    :stream t
                    :on-chunk (lambda (chunk)
                                (thread-enqueue response-queue chunk)))
         (error (e)
           (thread-enqueue response-queue `(:error . ,e))))
       (thread-enqueue response-queue :done))
     :name "lisp-claw-stream-worker")

    ;; Return streaming handle
    `(:stream . t)))

(defun invoke-provider (provider-fn model-name messages request)
  "Invoke provider for non-streaming response.

  Args:
    PROVIDIER-FN: Provider function
    MODEL-NAME: Model name
    MESSAGES: Message list
    REQUEST: Request plist

  Returns:
    Response string"
  (handler-case
      (let ((result (funcall provider-fn model-name messages :stream nil)))
        (let ((content (extract-response-content result)))
          ;; Add to session history
          (session-add-message (plist-get request :session-id)
                               :assistant content)
          content))
    (error (e)
      (log-error "Provider invocation failed: ~A" e)
      (error 'agent-error :message (format nil "Provider error: ~A" e)))))

(defun extract-response-content (response)
  "Extract content from provider response.

  Args:
    RESPONSE: Provider response

  Returns:
    Content string"
  (etypecase response
    (string response)
    (alist (or (cdr (assoc :content response))
               (cdr (assoc :text response))
               ""))))

;;; ============================================================================
;;; Tool Handling
;;; ============================================================================

(defvar *tool-registry* (make-hash-table :test 'equal)
  "Registry of available tools.")

(defun register-tool (name handler &key description parameters)
  "Register a tool.

  Args:
    NAME: Tool name
    HANDLER: Tool handler function
    DESCRIPTION: Tool description
    PARAMETERS: Parameter schema

  Returns:
    T on success"
  (setf (gethash name *tool-registry*)
        `(:handler ,handler
          :description ,description
          :parameters ,parameters))
  (log-debug "Registered tool: ~A" name)
  t)

(defun invoke-tool (name arguments)
  "Invoke a tool.

  Args:
    NAME: Tool name
    ARGUMENTS: Tool arguments

  Returns:
    Tool result"
  (let ((tool (gethash name *tool-registry*)))
    (unless tool
      (error 'tool-not-found :tool name))

    (let ((handler (plist-get tool :handler)))
      (handler-case
          (funcall handler arguments)
        (error (e)
          (log-error "Tool invocation failed: ~A" e)
          `(:error . ,(format nil "Tool error: ~A" e)))))))

(defun handle-tool-call (session-id tool-name tool-arguments)
  "Handle a tool call from the agent.

  Args:
    SESSION-ID: Session identifier
    TOOL-NAME: Tool name
    TOOL-ARGUMENTS: Tool arguments

  Returns:
    Tool result"
  (log-info "Handling tool call: ~A" tool-name)

  (let ((result (invoke-tool tool-name tool-arguments)))
    ;; Log tool usage
    (session-add-message session-id :system
                         (format nil "[Tool: ~A] ~A" tool-name result))
    result))

;;; ============================================================================
;;; Error Handling
;;; ============================================================================

(defun agent-error-handler (error session-id)
  "Handle agent errors.

  Args:
    ERROR: Error condition
    SESSION-ID: Session identifier

  Returns:
    Error response string"
  (log-error "Agent error: ~A" error)

  (typecase error
    (agent-error
     (format nil "Error: ~A" (error-message error)))
    (tool-not-found
     (format nil "Tool not found: ~A" (error-tool error)))
    (otherwise
     (format nil "An unexpected error occurred: ~A" error))))

;;; ============================================================================
;;; Conditions
;;; ============================================================================

(define-condition agent-error (error)
  ((message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "Agent Error: ~A"
                     (error-message condition)))))

(define-condition tool-not-found (error)
  ((tool :initarg :tool :reader error-tool))
  (:report (lambda (condition stream)
             (format stream "Tool not found: ~A"
                     (error-tool condition)))))
