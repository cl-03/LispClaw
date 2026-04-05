;;; groq.lisp --- Groq Provider for Lisp-Claw
;;;
;;; This file implements the Groq API provider.
;;; Groq uses an OpenAI-compatible API format.

(defpackage #:lisp-claw.agent.providers.groq
  (:nicknames #:lc.agent.providers.groq)
  (:use #:cl
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.helpers
        #:lisp-claw.agent.providers.base)
  (:shadowing-import-from #:dexador #:request #:post #:get)
  (:export
   #:groq-call
   #:groq-stream
   #:*groq-base-url*))

(in-package #:lisp-claw.agent.providers.groq)

;;; ============================================================================
;;; Constants
;;; ============================================================================

(defvar *groq-base-url* "https://api.groq.com/openai/v1"
  "Groq API base URL.")

(defvar *groq-timeout* 60
  "Request timeout in seconds.")

;;; ============================================================================
;;; Model Mapping
;;; ============================================================================

(defun map-groq-model (model-name)
  "Map common model name to Groq format.

  Args:
    MODEL-NAME: Common model name

  Returns:
    Groq model name"
  (let ((name (string-downcase model-name)))
    (cond
      ((search "llama-3.3-70b" name) "llama-3.3-70b-versatile")
      ((search "llama-3.1-70b" name) "llama-3.1-70b-versatile")
      ((search "llama-3.1-8b" name) "llama-3.1-8b-instant")
      ((search "mixtral-8x7b" name) "mixtral-8x7b-32768")
      ((search "gemma2-9b" name) "gemma2-9b-it")
      ((search "llama3-70b" name) "llama3-70b-8192")
      ((search "llama3-8b" name) "llama3-8b-8192")
      (t model-name))))

;;; ============================================================================
;;; Main Entry Points
;;; ============================================================================

(defun groq-call (model messages &key stream options)
  "Make a call to Groq API.

  Args:
    MODEL: Model name (e.g., "llama-3.3-70b-versatile")
    MESSAGES: List of messages
    STREAM: Whether to stream (use groq-stream for streaming)
    OPTIONS: Additional options

  Returns:
    Response alist"
  (let ((api-key (get-api-key "groq")))
    (unless api-key
      (error 'provider-auth-error
             :provider "groq"
             :message "GROQ_API_KEY not set"))

    (let* ((groq-model (map-groq-model model))
           (url (format nil "~A/chat/completions" *groq-base-url*))
           (body (build-groq-body groq-model messages options)))

      (log-debug "Calling Groq API: ~A" groq-model)

      (handler-case
          (let* ((response (dex:post url
                                     :headers `(("Content-Type" . "application/json")
                                                ("Authorization" . ,(format nil "Bearer ~A" api-key)))
                                     :content (stringify-json body)
                                     :read-timeout *groq-timeout*
                                     :connect-timeout 30))
                 (json (parse-json response)))
            (log-debug "Groq API response received")
            (validate-groq-response json)
            (extract-groq-content json))

        (dexador.error:http-request-failed (e)
          (handle-groq-error e))

        (error (e)
          (log-error "Groq API error: ~A" e)
          (error 'provider-error
                 :provider "groq"
                 :message (format nil "API error: ~A" e)))))))

(defun groq-stream (model messages &key options on-chunk on-complete)
  "Make a streaming call to Groq API.

  Args:
    MODEL: Model name
    MESSAGES: List of messages
    OPTIONS: Additional options
    ON-CHUNK: Callback function for each chunk
    ON-COMPLETE: Callback function when complete

  Returns:
    NIL (results delivered via callbacks)"
  (let ((api-key (get-api-key "groq")))
    (unless api-key
      (error 'provider-auth-error
             :provider "groq"
             :message "GROQ_API_KEY not set"))

    (let* ((groq-model (map-groq-model model))
           (url (format nil "~A/chat/completions" *groq-base-url*))
           (body (build-groq-body groq-model messages
                                  (append options '((:stream . t))))))

      (log-debug "Streaming Groq API: ~A" groq-model)

      (handler-case
          (dex:post url
                    :headers `(("Content-Type" . "application/json")
                               ("Authorization" . ,(format nil "Bearer ~A" api-key)))
                    :content (stringify-json body)
                    :want-stream t
                    :read-timeout *groq-timeout*
                    :connect-timeout 30)

        (dexador.error:http-request-failed (e)
          (handle-groq-error e))

        (error (e)
          (log-error "Groq streaming error: ~A" e)
          (error 'provider-error
                 :provider "groq"
                 :message (format nil "Streaming error: ~A" e)))))))

;;; ============================================================================
;;; Request Building
;;; ============================================================================

(defun build-groq-body (model messages options)
  "Build request body for Groq API.

  Args:
    MODEL: Groq model name
    MESSAGES: List of messages
    OPTIONS: Additional options

  Returns:
    Request body alist"
  (let* ((temperature (or (plist-get options :temperature) 0.7))
         (max-tokens (or (plist-get options :max-tokens) 8192))
         (top-p (or (plist-get options :top-p) 1.0))
         (stream-p (plist-get options :stream)))

    `(("model" . ,model)
      ("messages" . ,(build-messages-array messages))
      ("temperature" . ,temperature)
      ("max_tokens" . ,max-tokens)
      ("top_p" . ,top-p)
      ("stream" . ,(if stream-p t nil))
      ,@(when (plist-get options :tools)
          `(("tools" . ,(build-groq-tools (plist-get options :tools)))))
      ,@(when (plist-get options :tool-choice)
          `(("tool_choice" . ,(plist-get options :tool-choice)))))))

(defun build-messages-array (messages)
  "Build messages array for Groq API.

  Args:
    MESSAGES: List of messages

  Returns:
    Messages array"
  (loop for msg in messages
        collect `(("role" . ,(string-downcase (plist-get msg :role)))
                  ("content" . ,(plist-get msg :content)))))

(defun build-groq-tools (tools)
  "Build Groq tools definition.

  Args:
    TOOLS: List of tool definitions

  Returns:
    Tools JSON structure"
  (loop for tool in tools
        collect `(("type" . "function")
                  ("function" . (("name" . ,(plist-get tool :name))
                                 ("description" . ,(plist-get tool :description))
                                 ("parameters" . ,(plist-get tool :parameters)))))))

;;; ============================================================================
;;; Response Processing
;;; ============================================================================

(defun validate-groq-response (json)
  "Validate Groq API response.

  Args:
    JSON: Response JSON

  Returns:
    T on success, signals error on failure"
  (let ((error (gethash "error" json)))
    (when error
      (error 'provider-error
             :provider "groq"
             :message (format nil "API error: ~A" error)))

    (let ((choices (gethash "choices" json)))
      (unless (and choices (> (length choices) 0))
        (error 'provider-error
               :provider "groq"
               :message "No choices in response")))
    t))

(defun extract-groq-content (json)
  "Extract content from Groq response.

  Args:
    JSON: Response JSON

  Returns:
    Content alist"
  (let* ((choices (gethash "choices" json))
         (first-choice (aref choices 0))
         (message (gethash "message" first-choice))
         (content (gethash "content" message))
         (usage (gethash "usage" json)))

    `((:role . "assistant")
      (:content . ,content)
      (:finish-reason . ,(gethash "finish_reason" first-choice))
      (:usage . ,(when usage
                   `((:prompt-tokens . ,(gethash "prompt_tokens" usage))
                     (:completion-tokens . ,(gethash "completion_tokens" usage))
                     (:total-tokens . ,(gethash "total_tokens" usage))))))))

;;; ============================================================================
;;; Error Handling
;;; ============================================================================

(defun handle-groq-error (condition)
  "Handle Groq API HTTP errors.

  Args:
    CONDITION: HTTP condition

  Returns:
    Signals provider-error"
  (let ((status (dexador.error:response-status condition))
        (headers (dexador.error:response-headers condition)))
    (log-error "Groq API error (~A): ~A" status headers)

    (case status
      (400
       (error 'provider-error
              :provider "groq"
              :message "Bad request - invalid parameters"))
      (401
       (error 'provider-auth-error
              :provider "groq"
              :message "Invalid API key"))
      (403
       (error 'provider-auth-error
              :provider "groq"
              :message "API key lacks required permissions"))
      (404
       (error 'provider-error
              :provider "groq"
              :message "Model not found"))
      (429
       (error 'provider-rate-limit-error
              :provider "groq"
              :message "Rate limit exceeded"))
      (500
       (error 'provider-error
              :provider "groq"
              :message "Internal server error"))
      (otherwise
       (error 'provider-error
              :provider "groq"
              :message (format nil "HTTP error ~A" status))))))

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defun register-groq-provider ()
  "Register Groq as a provider.

  Returns:
    T on success"
  (let ((provider-config (get-provider "groq")))
    (unless provider-config
      (register-provider "groq"
        '(:base-url "https://api.groq.com/openai/v1"
          :auth-type :api-key
          :env-var "GROQ_API_KEY"
          :models ("llama-3.3-70b-versatile" "mixtral-8x7b-32768"
                   "llama-3.1-70b-versatile" "llama-3.1-8b-instant"
                   "gemma2-9b-it"))))
    (log-info "Groq provider registered")
    t))
