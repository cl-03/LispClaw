;;; ollama.lisp --- Ollama Provider for Lisp-Claw
;;;
;;; This file implements the Ollama local model provider.

(defpackage #:lisp-claw.agent.providers.ollama
  (:nicknames #:lc.agent.providers.ollama)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.helpers
        #:lisp-claw.agent.providers.base
        #:dexador)
  (:export
   #:ollama-call
   #:ollama-stream
   #:*ollama-base-url*
   #:ollama-list-models
   #:ollama-pull-model))

(in-package #:lisp-claw.agent.providers.ollama)

;;; ============================================================================
;;; Constants
;;; ============================================================================

(defvar *ollama-base-url* "http://localhost:11434"
  "Ollama API base URL.")

(defvar *ollama-timeout* 300
  "Request timeout in seconds (longer for local models).")

;;; ============================================================================
;;; Main Entry Points
;;; ============================================================================

(defun ollama-call (model messages &key stream options)
  "Make a call to Ollama API.

  Args:
    MODEL: Model name (e.g., "llama-3.1")
    MESSAGES: List of messages
    STREAM: Whether to stream
    OPTIONS: Additional options

  Returns:
    Response alist"
  (let ((url (format nil "~A/api/chat" *ollama-base-url*))
        (body (build-ollama-body model messages options)))

    (log-debug "Calling Ollama API: ~A" model)

    (handler-case
        (let* ((response (dex:post url
                                   :headers '(("Content-Type" . "application/json"))
                                   :content (stringify-json body)
                                   :timeout *ollama-timeout*))
               (json (parse-json response)))
          (log-debug "Ollama API response received")
          (extract-ollama-content json))

      (dex:timeout ()
        (error 'provider-error
               :provider "ollama"
               :message "Request timeout (model may be loading)"))

      (dex:connection-error ()
        (error 'provider-error
               :provider "ollama"
               :message "Cannot connect to Ollama. Is it running on localhost:11434?"))

      (dex:http-condition (e)
        (handle-ollama-error e))

      (error (e)
        (log-error "Ollama API error: ~A" e)
        (error 'provider-error
               :provider "ollama"
               :message (format nil "API error: ~A" e))))))

(defun ollama-stream (model messages &key options on-chunk on-complete)
  "Make a streaming call to Ollama API.

  Args:
    MODEL: Model name
    MESSAGES: List of messages
    OPTIONS: Additional options
    ON-CHUNK: Callback for each chunk
    ON-COMPLETE: Callback when complete

  Returns:
    NIL (results via callbacks)"
  (bt:make-thread
   (lambda ()
     (stream-ollama-internal model messages options on-chunk on-complete))
   :name "lisp-claw-ollama-stream")
  nil)

;;; ============================================================================
;;; Internal Implementation
;;; ============================================================================

(defun build-ollama-body (model messages options)
  "Build request body for Ollama API.

  Args:
    MODEL: Model name
    MESSAGES: Messages list
    OPTIONS: Additional options

  Returns:
    Request body alist"
  (let* ((stream (or (plist-get options :stream) nil))
         (temperature (or (plist-get options :temperature) 0.7))
         (num-predict (or (plist-get options :max-tokens) 2048)))

    `((:model . ,model)
      (:messages . ,(mapcar (lambda (msg)
                              `((:role . ,(cdr (assoc :role msg)))
                                (:content . ,(cdr (assoc :content msg)))))
                            messages))
      (:stream . ,stream)
      (:options . ((:temperature . ,temperature)
                   (:num_predict . ,num-predict))))))

(defun extract-ollama-content (response)
  "Extract content from Ollama response.

  Args:
    RESPONSE: Parsed JSON response

  Returns:
    Content string"
  (let* ((message (cdr (assoc :message response)))
         (content (cdr (assoc :content message)))
         (done (cdr (assoc :done response))))
    (values content done)))

(defun stream-ollama-internal (model messages options on-chunk on-complete)
  "Internal streaming implementation.

  Args:
    MODEL: Model name
    MESSAGES: Messages list
    OPTIONS: Additional options
    ON-CHUNK: Chunk callback
    ON-COMPLETE: Completion callback

  Returns:
    NIL"
  (let ((url (format nil "~A/api/chat" *ollama-base-url*))
        (body (build-ollama-body model messages
                                 (append options '(:stream t))))
        (content-accumulator nil))

    (handler-case
        (progn
          (log-info "Starting Ollama stream for: ~A" model)

          ;; Placeholder: non-streaming fallback
          (let ((response (ollama-call model messages :stream nil :options options)))
            (loop for i from 0 below (length response) by 50
                  do (let ((chunk (subseq response i (min (+ i 50) (length response)))))
                       (when on-chunk
                         (funcall on-chunk chunk))
                       (push chunk content-accumulator))
                  do (sleep 0.05)))

          (when on-complete
            (funcall on-complete (coerce (nreverse content-accumulator) 'string))))

      (error (e)
        (log-error "Ollama stream error: ~A" e)
        (when on-complete
          (funcall on-complete `(:error . ,e)))))))

(defun handle-ollama-error (condition)
  "Handle Ollama API errors.

  Args:
    CONDITION: HTTP condition error

  Returns:
    Signals appropriate provider error"
  (let ((status (dex:http-condition-status condition))
        (body (dex:http-condition-body condition)))
    (cond
      ((= status 404)
       (error 'provider-error
              :provider "ollama"
              :message (format nil "Model not found: ~A" body)))

      ((>= status 500)
       (error 'provider-error
              :provider "ollama"
              :message (format nil "Server error: ~A" status)))

      (t
       (error 'provider-error
              :provider "ollama"
              :message (format nil "HTTP error ~A: ~A" status body))))))

;;; ============================================================================
;;; Model Management
;;; ============================================================================

(defun ollama-list-models ()
  "List available Ollama models.

  Returns:
    List of model names"
  (handler-case
      (let* ((url (format nil "~A/api/tags" *ollama-base-url*))
             (response (dex:get url :timeout 10))
             (json (parse-json response))
             (models (cdr (assoc :models json))))
        (loop for model in models
              collect (cdr (assoc :name model))))
    (error (e)
      (log-error "Failed to list Ollama models: ~A" e)
      nil)))

(defun ollama-pull-model (model-name &key on-progress)
  "Pull/download an Ollama model.

  Args:
    MODEL-NAME: Model name to pull
    ON-PROGRESS: Optional progress callback

  Returns:
    T on success"
  (let ((url (format nil "~A/api/pull" *ollama-base-url*))
        (body `((:name . ,model-name) (:stream . t))))

    (log-info "Pulling Ollama model: ~A" model-name)

    (handler-case
        (let ((response (dex:post url
                                  :headers '(("Content-Type" . "application/json"))
                                  :content (stringify-json body)
                                  :timeout nil))) ; No timeout for large downloads
          (declare (ignore response))
          (log-info "Model pulled successfully: ~A" model-name)
          t))
    (error (e)
      (log-error "Failed to pull model: ~A" e)
      nil))))

(defun ollama-check-running-p ()
  "Check if Ollama is running.

  Returns:
    T if running, NIL otherwise"
  (handler-case
      (let ((url (format nil "~A/api/tags" *ollama-base-url*)))
        (dex:get url :timeout 5)
        t)
    (error ()
      nil)))

;;; ============================================================================
;;; Provider Registration
;;; ============================================================================

(defun register-ollama-provider ()
  "Register Ollama as an available provider.

  Returns:
    T on success"
  (setf (gethash "ollama"
                 (symbol-value (read-from-string "*model-providers*")))
        '(:base-url "http://localhost:11434"
          :auth-type :none
          :models ("llama-3.1" "mistral" "codellama" "gemma" "qwen2.5")
          :call-fn ollama-call
          :stream-fn ollama-stream))
  (log-info "Registered Ollama provider")
  t)
