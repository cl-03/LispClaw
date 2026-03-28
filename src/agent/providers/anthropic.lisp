;;; anthropic.lisp --- Anthropic Provider for Lisp-Claw
;;;
;;; This file implements the Anthropic API provider.

(defpackage #:lisp-claw.agent.providers.anthropic
  (:nicknames #:lc.agent.providers.anthropic)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.helpers
        #:lisp-claw.agent.providers.base
        #:dexador)
  (:export
   #:anthropic-call
   #:anthropic-stream
   #:*anthropic-base-url*
   #:*anthropic-api-version*))

(in-package #:lisp-claw.agent.providers.anthropic)

;;; ============================================================================
;;; Constants
;;; ============================================================================

(defvar *anthropic-base-url* "https://api.anthropic.com"
  "Anthropic API base URL.")

(defvar *anthropic-api-version* "2023-06-01"
  "Anthropic API version.")

(defvar *anthropic-timeout* 120
  "Request timeout in seconds.")

;;; ============================================================================
;;; Main Entry Points
;;; ============================================================================

(defun anthropic-call (model messages &key stream options)
  "Make a call to Anthropic API.

  Args:
    MODEL: Model name (e.g., "claude-opus-4-6")
    MESSAGES: List of messages
    STREAM: Whether to stream (for compatibility, use anthropic-stream for streaming)
    OPTIONS: Additional options

  Returns:
    Response alist"
  (let ((api-key (get-api-key "anthropic")))
    (unless api-key
      (error 'provider-auth-error
             :provider "anthropic"
             :message "ANTHROPIC_API_KEY not set"))

    (let ((url (format nil "~A/v1/messages" *anthropic-base-url*))
          (body (build-anthropic-body model messages options)))

      (log-debug "Calling Anthropic API: ~A" model)

      (handler-case
          (let* ((response (dex:post url
                                     :headers `(("Content-Type" . "application/json")
                                                ("x-api-key" . ,api-key)
                                                ("anthropic-version" . ,*anthropic-api-version*))
                                     :content (stringify-json body)
                                     :timeout *anthropic-timeout*))
                 (json (parse-json response)))
            (log-debug "Anthropic API response received")
            (validate-anthropic-response json)
            (extract-anthropic-content json))

        (dex:timeout ()
          (error 'provider-error
                 :provider "anthropic"
                 :message "Request timeout"))

        (dex:http-condition (e)
          (handle-anthropic-error e))

        (error (e)
          (log-error "Anthropic API error: ~A" e)
          (error 'provider-error
                 :provider "anthropic"
                 :message (format nil "API error: ~A" e)))))))

(defun anthropic-stream (model messages &key options on-chunk on-complete)
  "Make a streaming call to Anthropic API.

  Args:
    MODEL: Model name
    MESSAGES: List of messages
    OPTIONS: Additional options
    ON-CHUNK: Callback function for each chunk
    ON-COMPLETE: Callback function when complete

  Returns:
    NIL (results delivered via callbacks)"
  (let ((api-key (get-api-key "anthropic")))
    (unless api-key
      (error 'provider-auth-error
             :provider "anthropic"
             :message "ANTHROPIC_API_KEY not set"))

    (bt:make-thread
     (lambda ()
       (stream-anthropic-internal model messages api-key options on-chunk on-complete))
     :name "lisp-claw-anthropic-stream")

    nil))

;;; ============================================================================
;;; Internal Implementation
;;; ============================================================================

(defun build-anthropic-body (model messages options)
  "Build request body for Anthropic API.

  Args:
    MODEL: Model name
    MESSAGES: Messages list
    OPTIONS: Additional options

  Returns:
    Request body alist"
  (let* ((thinking-level (plist-get options :thinking-level))
         (max-tokens (or (plist-get options :max-tokens) 4096))
         (stream (or (plist-get options :stream) nil)))

    ;; Separate system message
    (multiple-value-bind (user-messages system-prompt)
        (format-messages messages :format :anthropic)

      `((:model . ,model)
        (:max_tokens . ,max-tokens)
        (:stream . ,stream)
        ,@(when system-prompt
            `((:system . ,system-prompt)))
        (:messages . ,(mapcar (lambda (msg)
                                `((:role . ,(cdr (assoc :role msg)))
                                  (:content . ,(cdr (assoc :content msg)))))
                              user-messages))
        ,@(when (member thinking-level '(:high :xhigh))
            `((:thinking . ((:type . "enabled")
                            (:budget_tokens . ,(case thinking-level
                                                 (:high 2000)
                                                 (:xhigh 4000)))))))))))

(defun validate-anthropic-response (response)
  "Validate Anthropic API response.

  Args:
    RESPONSE: Parsed JSON response

  Returns:
    T on success, signals error on failure"
  (let ((type (cdr (assoc :type response))))
    (cond
      ((equal type "message")
       t)
      ((equal type "error")
       (error 'provider-error
              :provider "anthropic"
              :message (format nil "API error: ~A"
                               (cdr (assoc :message response)))))
      (t
       (log-warn "Unknown response type: ~A" type)
       nil))))

(defun extract-anthropic-content (response)
  "Extract content from Anthropic response.

  Args:
    RESPONSE: Parsed JSON response

  Returns:
    Content string"
  (let* ((content (cdr (assoc :content response)))
         (stop-reason (cdr (assoc :stop_reason response))))
    (if (listp content)
        ;; Content is array of content blocks
        (let ((text-parts
               (loop for item in content
                     when (and (alist-p item)
                               (equal (cdr (assoc :type item)) "text"))
                     collect (cdr (assoc :text item)))))
          (values (format nil "~{~A~^~}" text-parts)
                  stop-reason))
        ;; Content is plain string
        (values content stop-reason))))

(defun stream-anthropic-internal (model messages api-key options on-chunk on-complete)
  "Internal streaming implementation.

  Args:
    MODEL: Model name
    MESSAGES: Messages list
    API-KEY: API key
    OPTIONS: Additional options
    ON-CHUNK: Chunk callback
    ON-COMPLETE: Completion callback

  Returns:
    NIL"
  (let ((url (format nil "~A/v1/messages" *anthropic-base-url*))
        (body (build-anthropic-body model messages
                                    (append options '(:stream t))))
        (content-accumulator nil))

    (handler-case
        ;; Note: Actual streaming would require HTTP client with streaming support
        ;; For now, this is a placeholder implementation
        (progn
          (log-info "Starting Anthropic stream for: ~A" model)

          ;; In a real implementation, we would:
          ;; 1. Open streaming HTTP connection
          ;; 2. Parse SSE events
          ;; 3. Call on-chunk for each content delta
          ;; 4. Call on-complete when done

          ;; Placeholder: just do non-streaming call and chunk the result
          (let ((response (anthropic-call model messages :stream nil :options options)))
            ;; Simulate streaming by chunking response
            (loop for i from 0 below (length response) by 50
                  do (let ((chunk (subseq response i (min (+ i 50) (length response)))))
                       (when on-chunk
                         (funcall on-chunk chunk))
                       (push chunk content-accumulator))
                  do (sleep 0.05)))

          ;; Call completion callback
          (when on-complete
            (funcall on-complete (coerce (nreverse content-accumulator) 'string))))

      (error (e)
        (log-error "Anthropic stream error: ~A" e)
        (when on-complete
          (funcall on-complete `(:error . ,e)))))))

(defun handle-anthropic-error (condition)
  "Handle Anthropic API errors.

  Args:
    CONDITION: HTTP condition error

  Returns:
    Signals appropriate provider error"
  (let ((status (dex:http-condition-status condition))
        (body (dex:http-condition-body condition)))
    (cond
      ((= status 401)
       (error 'provider-auth-error
              :provider "anthropic"
              :message "Invalid API key"))

      ((= status 429)
       (error 'provider-rate-limit-error
              :provider "anthropic"
              :retry-after (or (parse-rate-limit-retry body) 60)
              :message "Rate limit exceeded"))

      ((>= status 500)
       (error 'provider-error
              :provider "anthropic"
              :message (format nil "Server error: ~A" status)))

      (t
       (error 'provider-error
              :provider "anthropic"
              :message (format nil "HTTP error ~A: ~A" status body))))))

(defun parse-rate-limit-retry (body)
  "Parse retry-after from rate limit response.

  Args:
    BODY: Response body

  Returns:
    Retry-after seconds or NIL"
  (let ((json (ignore-errors (parse-json body))))
    (when json
      (or (cdr (assoc :retry_after json))
          60))))

;;; ============================================================================
;;; Provider Registration
;;; ============================================================================

(defun register-anthropic-provider ()
  "Register Anthropic as an available provider.

  Returns:
    T on success"
  (setf (gethash "anthropic"
                 (symbol-value (read-from-string "*model-providers*")))
        '(:base-url "https://api.anthropic.com"
          :auth-type :api-key
          :env-var "ANTHROPIC_API_KEY"
          :models ("claude-opus-4-6" "claude-sonnet-4-6" "claude-haiku-4-5")
          :call-fn anthropic-call
          :stream-fn anthropic-stream))
  (log-info "Registered Anthropic provider")
  t)
