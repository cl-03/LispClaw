;;; base.lisp --- AI Provider Base for Lisp-Claw
;;;
;;; This file defines the base interface for AI providers.

(defpackage #:lisp-claw.agent.providers.base
  (:nicknames #:lc.agent.providers.base)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   #:provider-call
   #:provider-stream
   #:format-messages
   #:extract-content
   #:handle-error))

(in-package #:lisp-claw.agent.providers.base)

;;; ============================================================================
;;; Provider Interface
;;; ============================================================================

(defgeneric provider-call (provider model messages &key options)
  "Make a non-streaming call to a provider.

  Args:
    PROVIDER: Provider identifier
    MODEL: Model name
    MESSAGES: List of messages
    OPTIONS: Additional options

  Returns:
    Provider response"
  (:method (provider model messages &key options)
    (declare (ignore provider model messages options))
    (error 'provider-unsupported :operation 'provider-call)))

(defgeneric provider-stream (provider model messages &key options on-chunk on-complete)
  "Make a streaming call to a provider.

  Args:
    PROVIDER: Provider identifier
    MODEL: Model name
    MESSAGES: List of messages
    OPTIONS: Additional options
    ON-CHUNK: Callback for each chunk
    ON-COMPLETE: Callback when complete

  Returns:
    NIL (results via callbacks)"
  (:method (provider model messages &key options on-chunk on-complete)
    (declare (ignore provider model messages options on-chunk on-complete))
    (error 'provider-unsupported :operation 'provider-stream)))

;;; ============================================================================
;;; Message Formatting
;;; ============================================================================

(defun format-messages (messages &key format)
  "Format messages for provider API.

  Args:
    MESSAGES: List of messages
    FORMAT: Target format (:anthropic, :openai, :google)

  Returns:
    Formatted messages"
  (ecase format
    (:anthropic
     ;; Anthropic format: system separate, messages with role/content
     (let ((system nil)
           (rest-messages nil))
       (dolist (msg messages)
         (if (equal (cdr (assoc :role msg)) "system")
             (setf system (cdr (assoc :content msg)))
             (push msg rest-messages)))
       (values (nreverse rest-messages) system)))

    (:openai
     ;; OpenAI format: array of role/content objects
     messages)

    (:google
     ;; Google format: contents array with role and parts
     (loop for msg in messages
           collect `(:role ,(if (equal (cdr (assoc :role msg)) "assistant")
                               "model" "user")
                     :parts (,(cdr (assoc :content msg))))))))

(defun extract-content (response &key format)
  "Extract content from provider response.

  Args:
    RESPONSE: Provider response
    FORMAT: Source format

  Returns:
    Content string"
  (ecase format
    (:anthropic
     (let ((content (cdr (assoc :content response))))
       (if (listp content)
           (loop for item in content
                 when (equal (cdr (assoc :type item)) "text")
                 collect (cdr (assoc :text item))
                 into texts
                 finally (return (format nil "~{~A~^~}" texts)))
           content)))

    (:openai
     (let* ((choices (cdr (assoc :choices response)))
            (first (first choices))
            (message (cdr (assoc :message first)))
            (content (cdr (assoc :content message))))
       content))

    (:google
     (let* ((candidates (cdr (assoc :candidates response)))
            (first (first candidates))
            (content (cdr (assoc :content first))))
       (cdr (assoc :parts (first content)))))))

;;; ============================================================================
;;; Error Handling
;;; ============================================================================

(defun handle-error (error provider)
  "Handle provider errors.

  Args:
    ERROR: Error condition
    PROVIDER: Provider identifier

  Returns:
    Error alist"
  (declare (ignore provider))
  `(:error . ,(princ-to-string error)))

;;; ============================================================================
;;; Provider Utilities
;;; ============================================================================

(defun get-api-key (provider)
  "Get API key for provider from environment.

  Args:
    PROVIDER: Provider identifier

  Returns:
    API key string or NIL"
  (let ((env-var (case (intern (string-upcase provider) :keyword)
                   (:anthropic "ANTHROPIC_API_KEY")
                   (:openai "OPENAI_API_KEY")
                   (:google "GOOGLE_API_KEY")
                   (:groq "GROQ_API_KEY")
                   (:xai "XAI_API_KEY")
                   (otherwise nil))))
    (when env-var
      (uiop:getenv env-var))))

(defun build-auth-header (provider api-key)
  "Build authorization header.

  Args:
    PROVIDER: Provider identifier
    API-KEY: API key

  Returns:
    Authorization header alist"
  (declare (ignore provider))
  `(("Authorization" . ,(format nil "Bearer ~A" api-key))))

(defun build-request-body (model messages &key stream options)
  "Build request body for provider API.

  Args:
    MODEL: Model name
    MESSAGES: Messages list
    STREAM: Whether streaming
    OPTIONS: Additional options

  Returns:
    Request body alist"
  (declare (ignore model messages stream options))
  nil)

;;; ============================================================================
;;; Conditions
;;; ============================================================================

(define-condition provider-error (error)
  ((provider :initarg :provider :reader error-provider)
   (message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "Provider Error (~A): ~A"
                     (error-provider condition)
                     (error-message condition)))))

(define-condition provider-unsupported (error)
  ((operation :initarg :operation :reader error-operation))
  (:report (lambda (condition stream)
             (format stream "Provider operation unsupported: ~A"
                     (error-operation condition)))))

(define-condition provider-auth-error (provider-error)
  ((message :initform "Authentication failed")))

(define-condition provider-rate-limit-error (provider-error)
  ((retry-after :initarg :retry-after :reader error-retry-after)
   (message :initform "Rate limit exceeded")))
