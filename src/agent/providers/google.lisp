;;; google.lisp --- Google Gemini Provider for Lisp-Claw
;;;
;;; This file implements the Google Gemini API provider.

(defpackage #:lisp-claw.agent.providers.google
  (:nicknames #:lc.agent.providers.google)
  (:use #:cl
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.helpers
        #:lisp-claw.agent.providers.base)
  (:shadowing-import-from #:dexador #:request #:post #:get)
  (:export
   #:google-call
   #:google-stream
   #:*google-base-url*
   #:*google-api-version*))

(in-package #:lisp-claw.agent.providers.google)

;;; ============================================================================
;;; Constants
;;; ============================================================================

(defvar *google-base-url* "https://generativelanguage.googleapis.com/v1beta"
  "Google Gemini API base URL.")

(defvar *google-api-version* "v1beta"
  "Google API version.")

(defvar *google-timeout* 120
  "Request timeout in seconds.")

;;; ============================================================================
;;; Model Mapping
;;; ============================================================================

(defun map-model-name (model-name)
  "Map common model name to Gemini format.

  Args:
    MODEL-NAME: Common model name

  Returns:
    Gemini model endpoint name"
  (let ((name (string-downcase model-name)))
    (cond
      ((search "gemini-2.0-flash" name) "gemini-2.0-flash")
      ((search "gemini-2.0-pro" name) "gemini-2.0-pro")
      ((search "gemini-1.5-pro" name) "gemini-1.5-pro")
      ((search "gemini-1.5-flash" name) "gemini-1.5-flash")
      ((search "gemini-ultra" name) "gemini-ultra")
      (t "gemini-2.0-flash"))))

;;; ============================================================================
;;; Main Entry Points
;;; ============================================================================

(defun google-call (model messages &key stream options)
  "Make a call to Google Gemini API.

  Args:
    MODEL: Model name (e.g., "gemini-2.0-flash")
    MESSAGES: List of messages
    STREAM: Whether to stream (use google-stream for streaming)
    OPTIONS: Additional options

  Returns:
    Response alist"
  (let ((api-key (get-api-key "google")))
    (unless api-key
      (error 'provider-auth-error
             :provider "google"
             :message "GOOGLE_API_KEY not set"))

    (let* ((endpoint (map-model-name model))
           (url (format nil "~A/models/~A:generateContent?key=~A"
                        *google-base-url* endpoint api-key))
           (body (build-google-body messages options)))

      (log-debug "Calling Google Gemini API: ~A" model)

      (handler-case
          (let* ((response (dex:post url
                                     :headers '(("Content-Type" . "application/json"))
                                     :content (stringify-json body)
                                     :read-timeout *google-timeout*
                                     :connect-timeout 30))
                 (json (parse-json response)))
            (log-debug "Google API response received")
            (validate-google-response json)
            (extract-google-content json))

        (dexador.error:http-request-failed (e)
          (handle-google-error e))

        (error (e)
          (log-error "Google API error: ~A" e)
          (error 'provider-error
                 :provider "google"
                 :message (format nil "API error: ~A" e)))))))

(defun google-stream (model messages &key options on-chunk on-complete)
  "Make a streaming call to Google Gemini API.

  Args:
    MODEL: Model name
    MESSAGES: List of messages
    OPTIONS: Additional options
    ON-CHUNK: Callback function for each chunk
    ON-COMPLETE: Callback function when complete

  Returns:
    NIL (results delivered via callbacks)"
  (let ((api-key (get-api-key "google")))
    (unless api-key
      (error 'provider-auth-error
             :provider "google"
             :message "GOOGLE_API_KEY not set"))

    (let* ((endpoint (map-model-name model))
           (url (format nil "~A/models/~A:streamGenerateContent?alt=sse&key=~A"
                        *google-base-url* endpoint api-key))
           (body (build-google-body messages options)))

      (log-debug "Streaming Google Gemini API: ~A" model)

      (handler-case
          (dex:post url
                    :headers '(("Content-Type" . "application/json"))
                    :content (stringify-json body)
                    :want-stream t
                    :read-timeout *google-timeout*
                    :connect-timeout 30)

        (dexador.error:http-request-failed (e)
          (handle-google-error e))

        (error (e)
          (log-error "Google streaming error: ~A" e)
          (error 'provider-error
                 :provider "google"
                 :message (format nil "Streaming error: ~A" e)))))))

;;; ============================================================================
;;; Request Building
;;; ============================================================================

(defun build-google-body (messages options)
  "Build request body for Google Gemini API.

  Args:
    MESSAGES: List of messages
    OPTIONS: Additional options

  Returns:
    Request body alist"
  (let* ((system-instruction (extract-system-message messages))
         (contents (convert-messages-to-contents messages))
         (temperature (or (plist-get options :temperature) 0.7))
         (top-p (or (plist-get options :top-p) 0.95))
         (top-k (or (plist-get options :top-k) 40))
         (max-tokens (or (plist-get options :max-tokens) 8192)))

    `(("contents" . ,contents)
      ,@(when system-instruction
          `(("systemInstruction" . (("parts" . ((("text" . ,system-instruction))))))))
      ("generationConfig" . (("temperature" . ,temperature)
                             ("topP" . ,top-p)
                             ("topK" . ,top-k)
                             ("maxOutputTokens" . ,max-tokens)))
      ,@(when (plist-get options :tools)
          `(("tools" . ,(build-google-tools (plist-get options :tools))))))))

(defun convert-messages-to-contents (messages)
  "Convert messages to Gemini content format.

  Args:
    MESSAGES: List of messages

  Returns:
    List of content objects"
  (loop for msg in messages
        for role = (plist-get msg :role)
        for content = (plist-get msg :content)
        unless (string= role "system")
        collect `(("role" . ,(if (string= role "assistant") "model" "user"))
                  ("parts" . ((("text" . ,content)))))))

(defun extract-system-message (messages)
  "Extract system message from messages.

  Args:
    MESSAGES: List of messages

  Returns:
    System message string or NIL"
  (find-if (lambda (msg)
             (string= (plist-get msg :role) "system"))
           messages))

(defun build-google-tools (tools)
  "Build Google Gemini tools definition.

  Args:
    TOOLS: List of tool definitions

  Returns:
    Tools JSON structure"
  ;; Google Gemini tool format
  `(("functionDeclarations" . ,(loop for tool in tools
                                     collect `(("name" . ,(plist-get tool :name))
                                               ("description" . ,(plist-get tool :description))
                                               ("parameters" . ,(plist-get tool :parameters)))))))

;;; ============================================================================
;;; Response Processing
;;; ============================================================================

(defun validate-google-response (json)
  "Validate Google Gemini API response.

  Args:
    JSON: Response JSON

  Returns:
    T on success, signals error on failure"
  (let ((error (gethash "error" json)))
    (when error
      (error 'provider-error
             :provider "google"
             :message (format nil "API error: ~A" error)))
    t))

(defun extract-google-content (json)
  "Extract content from Google Gemini response.

  Args:
    JSON: Response JSON

  Returns:
    Content alist"
  (let* ((candidates (gethash "candidates" json))
         (first-candidate (if (and candidates (> (length candidates) 0))
                              (aref candidates 0)
                              nil)))
    (when first-candidate
      (let* ((content (gethash "content" first-candidate))
             (parts (gethash "parts" content))
             (text (if (and parts (> (length parts) 0))
                       (gethash "text" (aref parts 0))
                       "")))
        `((:role . "assistant")
          (:content . ,text)
          (:finish-reason . ,(gethash "finishReason" first-candidate))
          (:usage . ,(extract-google-usage json)))))))

(defun extract-google-usage (json)
  "Extract usage metadata from Google response.

  Args:
    JSON: Response JSON

  Returns:
    Usage alist"
  (let* ((metadata (gethash "usageMetadata" json)))
    (when metadata
      `((:prompt-tokens . ,(gethash "promptTokenCount" metadata))
        (:completion-tokens . ,(gethash "candidatesTokenCount" metadata))
        (:total-tokens . ,(gethash "totalTokenCount" metadata))))))

;;; ============================================================================
;;; Error Handling
;;; ============================================================================

(defun handle-google-error (condition)
  "Handle Google API HTTP errors.

  Args:
    CONDITION: HTTP condition

  Returns:
    Signals provider-error"
  (let ((status (dexador.error:response-status condition))
        (headers (dexador.error:response-headers condition)))
    (log-error "Google API error (~A): ~A" status headers)

    (case status
      (400
       (error 'provider-error
              :provider "google"
              :message "Bad request - invalid parameters"))
      (401
       (error 'provider-auth-error
              :provider "google"
              :message "Invalid API key"))
      (403
       (error 'provider-auth-error
              :provider "google"
              :message "API key lacks required permissions"))
      (404
       (error 'provider-error
              :provider "google"
              :message "Model not found"))
      (429
       (error 'provider-rate-limit-error
              :provider "google"
              :message "Rate limit exceeded"))
      (otherwise
       (error 'provider-error
              :provider "google"
              :message (format nil "HTTP error ~A" status))))))

;;; ============================================================================
;;; Vision Support
;;; ============================================================================

(defun google-vision-call (model messages images &key options)
  "Make a call to Google Gemini API with images.

  Args:
    MODEL: Model name
    MESSAGES: List of messages
    IMAGES: List of image URLs or base64 data
    OPTIONS: Additional options

  Returns:
    Response alist"
  (let ((api-key (get-api-key "google")))
    (unless api-key
      (error 'provider-auth-error
             :provider "google"
             :message "GOOGLE_API_KEY not set"))

    (let* ((endpoint (map-model-name model))
           (url (format nil "~A/models/~A:generateContent?key=~A"
                        *google-base-url* endpoint api-key))
           (body (build-google-vision-body messages images options)))

      (handler-case
          (let* ((response (dex:post url
                                     :headers '(("Content-Type" . "application/json"))
                                     :content (stringify-json body)
                                     :read-timeout *google-timeout*
                                     :connect-timeout 30))
                 (json (parse-json response)))
            (validate-google-response json)
            (extract-google-content json))

        (dexador.error:http-request-failed (e)
          (handle-google-error e))

        (error (e)
          (log-error "Google vision error: ~A" e)
          (error 'provider-error
                 :provider "google"
                 :message (format nil "Vision error: ~A" e)))))))

(defun build-google-vision-body (messages images options)
  "Build request body for Google Gemini vision API.

  Args:
    MESSAGES: List of messages
    IMAGES: List of image URLs or base64 data
    OPTIONS: Additional options

  Returns:
    Request body alist"
  (declare (ignore messages images options))
  ;; Placeholder implementation
  `(("contents" . ())))

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defun register-google-provider ()
  "Register Google Gemini as a provider.

  Returns:
    T on success"
  (let ((provider-config (get-provider "google")))
    (unless provider-config
      (register-provider "google"
        '(:base-url "https://generativelanguage.googleapis.com/v1beta"
          :auth-type :api-key
          :env-var "GOOGLE_API_KEY"
          :models ("gemini-2.0-flash" "gemini-2.0-pro"
                   "gemini-1.5-pro" "gemini-1.5-flash"))))
    (log-info "Google Gemini provider registered")
    t))
