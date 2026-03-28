;;; openai.lisp --- OpenAI Provider for Lisp-Claw
;;;
;;; This file implements the OpenAI API provider.

(defpackage #:lisp-claw.agent.providers.openai
  (:nicknames #:lc.agent.providers.openai)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.helpers
        #:lisp-claw.agent.providers.base
        #:dexador)
  (:export
   #:openai-call
   #:openai-stream
   #:*openai-base-url*))

(in-package #:lisp-claw.agent.providers.openai)

;;; ============================================================================
;;; Constants
;;; ============================================================================

(defvar *openai-base-url* "https://api.openai.com/v1"
  "OpenAI API base URL.")

(defvar *openai-timeout* 120
  "Request timeout in seconds.")

;;; ============================================================================
;;; Main Entry Points
;;; ============================================================================

(defun openai-call (model messages &key stream options)
  "Make a call to OpenAI API.

  Args:
    MODEL: Model name (e.g., "gpt-4o")
    MESSAGES: List of messages
    STREAM: Whether to stream
    OPTIONS: Additional options

  Returns:
    Response alist"
  (let ((api-key (get-api-key "openai")))
    (unless api-key
      (error 'provider-auth-error
             :provider "openai"
             :message "OPENAI_API_KEY not set"))

    (let ((url (format nil "~A/chat/completions" *openai-base-url*))
          (body (build-openai-body model messages options)))

      (log-debug "Calling OpenAI API: ~A" model)

      (handler-case
          (let* ((response (dex:post url
                                     :headers `(("Content-Type" . "application/json")
                                                ("Authorization" . ,(format nil "Bearer ~A" api-key)))
                                     :content (stringify-json body)
                                     :timeout *openai-timeout*))
                 (json (parse-json response)))
            (log-debug "OpenAI API response received")
            (extract-openai-content json))

        (dex:timeout ()
          (error 'provider-error
                 :provider "openai"
                 :message "Request timeout"))

        (dex:http-condition (e)
          (handle-openai-error e))

        (error (e)
          (log-error "OpenAI API error: ~A" e)
          (error 'provider-error
                 :provider "openai"
                 :message (format nil "API error: ~A" e)))))))

(defun openai-stream (model messages &key options on-chunk on-complete)
  "Make a streaming call to OpenAI API.

  Args:
    MODEL: Model name
    MESSAGES: List of messages
    OPTIONS: Additional options
    ON-CHUNK: Callback for each chunk
    ON-COMPLETE: Callback when complete

  Returns:
    NIL (results via callbacks)"
  (let ((api-key (get-api-key "openai")))
    (unless api-key
      (error 'provider-auth-error
             :provider "openai"
             :message "OPENAI_API_KEY not set"))

    (bt:make-thread
     (lambda ()
       (stream-openai-internal model messages api-key options on-chunk on-complete))
     :name "lisp-claw-openai-stream")

    nil))

;;; ============================================================================
;;; Internal Implementation
;;; ============================================================================

(defun build-openai-body (model messages options)
  "Build request body for OpenAI API.

  Args:
    MODEL: Model name
    MESSAGES: Messages list
    OPTIONS: Additional options

  Returns:
    Request body alist"
  (let* ((stream (or (plist-get options :stream) nil))
         (max-tokens (or (plist-get options :max-tokens) 4096))
         (temperature (or (plist-get options :temperature) 0.7)))

    `((:model . ,model)
      (:messages . ,(mapcar (lambda (msg)
                              `((:role . ,(cdr (assoc :role msg)))
                                (:content . ,(cdr (assoc :content msg)))))
                            messages))
      (:max_tokens . ,max-tokens)
      (:temperature . ,temperature)
      (:stream . ,stream))))

(defun extract-openai-content (response)
  "Extract content from OpenAI response.

  Args:
    RESPONSE: Parsed JSON response

  Returns:
    Content string"
  (let* ((choices (cdr (assoc :choices response)))
         (first-choice (first choices))
         (message (cdr (assoc :message first-choice)))
         (content (cdr (assoc :content message)))
         (finish-reason (cdr (assoc :finish_reason first-choice))))
    (values content finish-reason)))

(defun stream-openai-internal (model messages api-key options on-chunk on-complete)
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
  (let ((content-accumulator nil))
    (handler-case
        (progn
          (log-info "Starting OpenAI stream for: ~A" model)

          ;; Placeholder: non-streaming fallback
          (let ((response (openai-call model messages :stream nil :options options)))
            (loop for i from 0 below (length response) by 50
                  do (let ((chunk (subseq response i (min (+ i 50) (length response)))))
                       (when on-chunk
                         (funcall on-chunk chunk))
                       (push chunk content-accumulator))
                  do (sleep 0.05)))

          (when on-complete
            (funcall on-complete (coerce (nreverse content-accumulator) 'string))))

      (error (e)
        (log-error "OpenAI stream error: ~A" e)
        (when on-complete
          (funcall on-complete `(:error . ,e)))))))

(defun handle-openai-error (condition)
  "Handle OpenAI API errors.

  Args:
    CONDITION: HTTP condition error

  Returns:
    Signals appropriate provider error"
  (let ((status (dex:http-condition-status condition))
        (body (dex:http-condition-body condition)))
    (cond
      ((= status 401)
       (error 'provider-auth-error
              :provider "openai"
              :message "Invalid API key"))

      ((= status 429)
       (error 'provider-rate-limit-error
              :provider "openai"
              :retry-after 60
              :message "Rate limit exceeded"))

      ((>= status 500)
       (error 'provider-error
              :provider "openai"
              :message (format nil "Server error: ~A" status)))

      (t
       (error 'provider-error
              :provider "openai"
              :message (format nil "HTTP error ~A: ~A" status body))))))

;;; ============================================================================
;;; Provider Registration
;;; ============================================================================

(defun register-openai-provider ()
  "Register OpenAI as an available provider.

  Returns:
    T on success"
  (setf (gethash "openai"
                 (symbol-value (read-from-string "*model-providers*")))
        '(:base-url "https://api.openai.com/v1"
          :auth-type :api-key
          :env-var "OPENAI_API_KEY"
          :models ("gpt-4o" "gpt-4o-mini" "o1" "o1-mini")
          :call-fn openai-call
          :stream-fn openai-stream))
  (log-info "Registered OpenAI provider")
  t)
