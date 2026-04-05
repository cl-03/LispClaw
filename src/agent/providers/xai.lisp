;;; xai.lisp --- xAI (Grok) Provider for Lisp-Claw
;;;
;;; This file implements the xAI (Grok) API provider.
;;; xAI uses an OpenAI-compatible API format.

(defpackage #:lisp-claw.agent.providers.xai
  (:nicknames #:lc.agent.providers.xai)
  (:use #:cl
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.helpers
        #:lisp-claw.agent.providers.base)
  (:shadowing-import-from #:dexador #:request #:post #:get)
  (:export
   #:xai-call
   #:xai-stream
   #:*xai-base-url*))

(in-package #:lisp-claw.agent.providers.xai)

;;; ============================================================================
;;; Constants
;;; ============================================================================

(defvar *xai-base-url* "https://api.x.ai/v1"
  "xAI API base URL.")

(defvar *xai-timeout* 120
  "Request timeout in seconds.")

;;; ============================================================================
;;; Model Mapping
;;; ============================================================================

(defun map-xai-model (model-name)
  "Map common model name to xAI format.

  Args:
    MODEL-NAME: Common model name

  Returns:
    xAI model name"
  (let ((name (string-downcase model-name)))
    (cond
      ((search "grok-2" name) "grok-2")
      ((search "grok-beta" name) "grok-beta")
      ((search "grok-vision" name) "grok-vision")
      (t "grok-2"))))

;;; ============================================================================
;;; Main Entry Points
;;; ============================================================================

(defun xai-call (model messages &key stream options)
  "Make a call to xAI API.

  Args:
    MODEL: Model name (e.g., "grok-2")
    MESSAGES: List of messages
    STREAM: Whether to stream (use xai-stream for streaming)
    OPTIONS: Additional options

  Returns:
    Response alist"
  (let ((api-key (get-api-key "xai")))
    (unless api-key
      (error 'provider-auth-error
             :provider "xai"
             :message "XAI_API_KEY not set"))

    (let* ((xai-model (map-xai-model model))
           (url (format nil "~A/chat/completions" *xai-base-url*))
           (body (build-xai-body xai-model messages options)))

      (log-debug "Calling xAI API: ~A" xai-model)

      (handler-case
          (let* ((response (dex:post url
                                     :headers `(("Content-Type" . "application/json")
                                                ("Authorization" . ,(format nil "Bearer ~A" api-key)))
                                     :content (stringify-json body)
                                     :read-timeout *xai-timeout*
                                     :connect-timeout 30))
                 (json (parse-json response)))
            (log-debug "xAI API response received")
            (validate-xai-response json)
            (extract-xai-content json))

        (dexador.error:http-request-failed (e)
          (handle-xai-error e))

        (error (e)
          (log-error "xAI API error: ~A" e)
          (error 'provider-error
                 :provider "xai"
                 :message (format nil "API error: ~A" e)))))))

(defun xai-stream (model messages &key options on-chunk on-complete)
  "Make a streaming call to xAI API.

  Args:
    MODEL: Model name
    MESSAGES: List of messages
    OPTIONS: Additional options
    ON-CHUNK: Callback function for each chunk
    ON-COMPLETE: Callback function when complete

  Returns:
    NIL (results delivered via callbacks)"
  (let ((api-key (get-api-key "xai")))
    (unless api-key
      (error 'provider-auth-error
             :provider "xai"
             :message "XAI_API_KEY not set"))

    (let* ((xai-model (map-xai-model model))
           (url (format nil "~A/chat/completions" *xai-base-url*))
           (body (build-xai-body xai-model messages
                                 (append options '((:stream . t))))))

      (log-debug "Streaming xAI API: ~A" xai-model)

      (handler-case
          (dex:post url
                    :headers `(("Content-Type" . "application/json")
                               ("Authorization" . ,(format nil "Bearer ~A" api-key)))
                    :content (stringify-json body)
                    :want-stream t
                    :read-timeout *xai-timeout*
                    :connect-timeout 30)

        (dexador.error:http-request-failed (e)
          (handle-xai-error e))

        (error (e)
          (log-error "xAI streaming error: ~A" e)
          (error 'provider-error
                 :provider "xai"
                 :message (format nil "Streaming error: ~A" e)))))))

;;; ============================================================================
;;; Request Building
;;; ============================================================================

(defun build-xai-body (model messages options)
  "Build request body for xAI API.

  Args:
    MODEL: xAI model name
    MESSAGES: List of messages
    OPTIONS: Additional options

  Returns:
    Request body alist"
  (let* ((temperature (or (plist-get options :temperature) 0.7))
         (max-tokens (or (plist-get options :max-tokens) 4096))
         (top-p (or (plist-get options :top-p) 1.0))
         (stream-p (plist-get options :stream)))

    `(("model" . ,model)
      ("messages" . ,(build-xai-messages messages))
      ("temperature" . ,temperature)
      ("max_tokens" . ,max-tokens)
      ("top_p" . ,top-p)
      ("stream" . ,(if stream-p t nil))
      ,@(when (plist-get options :tools)
          `(("tools" . ,(build-xai-tools (plist-get options :tools)))))
      ,@(when (plist-get options :tool-choice)
          `(("tool_choice" . ,(plist-get options :tool-choice)))))))

(defun build-xai-messages (messages)
  "Build messages array for xAI API.

  Args:
    MESSAGES: List of messages

  Returns:
    Messages array"
  (loop for msg in messages
        collect `(("role" . ,(string-downcase (plist-get msg :role)))
                  ("content" . ,(plist-get msg :content)))))

(defun build-xai-tools (tools)
  "Build xAI tools definition.

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

(defun validate-xai-response (json)
  "Validate xAI API response.

  Args:
    JSON: Response JSON

  Returns:
    T on success, signals error on failure"
  (let ((error (gethash "error" json)))
    (when error
      (error 'provider-error
             :provider "xai"
             :message (format nil "API error: ~A" error)))

    (let ((choices (gethash "choices" json)))
      (unless (and choices (> (length choices) 0))
        (error 'provider-error
               :provider "xai"
               :message "No choices in response")))
    t))

(defun extract-xai-content (json)
  "Extract content from xAI response.

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

(defun handle-xai-error (condition)
  "Handle xAI API HTTP errors.

  Args:
    CONDITION: HTTP condition

  Returns:
    Signals provider-error"
  (let ((status (dexador.error:response-status condition))
        (headers (dexador.error:response-headers condition)))
    (log-error "xAI API error (~A): ~A" status headers)

    (case status
      (400
       (error 'provider-error
              :provider "xai"
              :message "Bad request - invalid parameters"))
      (401
       (error 'provider-auth-error
              :provider "xai"
              :message "Invalid API key"))
      (403
       (error 'provider-auth-error
              :provider "xai"
              :message "API key lacks required permissions"))
      (404
       (error 'provider-error
              :provider "xai"
              :message "Model not found"))
      (429
       (error 'provider-rate-limit-error
              :provider "xai"
              :message "Rate limit exceeded"))
      (500
       (error 'provider-error
              :provider "xai"
              :message "Internal server error"))
      (otherwise
       (error 'provider-error
              :provider "xai"
              :message (format nil "HTTP error ~A" status))))))

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defun register-xai-provider ()
  "Register xAI as a provider.

  Returns:
    T on success"
  (let ((provider-config (get-provider "xai")))
    (unless provider-config
      (register-provider "xai"
        '(:base-url "https://api.x.ai/v1"
          :auth-type :api-key
          :env-var "XAI_API_KEY"
          :models ("grok-2" "grok-beta" "grok-vision"))))
    (log-info "xAI provider registered")
    t))
