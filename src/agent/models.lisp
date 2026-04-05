;;; models.lisp --- AI Model Abstraction for Lisp-Claw
;;;
;;; This file defines the model abstraction layer for AI providers.

(defpackage #:lisp-claw.agent.models
  (:nicknames #:lc.agent.models)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   #:model-provider
   #:model-info
   #:*model-providers*
   #:register-provider
   #:get-provider
   #:list-providers
   #:get-model-info
   #:parse-model-string
   #:validate-model
   #:model-not-found-error))

(in-package #:lisp-claw.agent.models)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *model-providers* (make-hash-table :test 'equal)
  "Registry of model providers.
   Key: provider name, Value: provider config alist")

(defvar *model-cache* (make-hash-table :test 'equal)
  "Cache of model information.")

;;; ============================================================================
;;; Provider Registration
;;; ============================================================================

(defun register-provider (name config)
  "Register a model provider.

  Args:
    NAME: Provider name (string)
    CONFIG: Provider configuration alist

  Returns:
    T on success"
  (setf (gethash name *model-providers*) config)
  (log-debug "Registered provider: ~A" name)
  t)

(defun get-provider (name)
  "Get provider configuration.

  Args:
    NAME: Provider name

  Returns:
    Provider config or NIL"
  (gethash name *model-providers*))

(defun list-providers ()
  "List all registered providers.

  Returns:
    List of provider names"
  (loop for name being the hash-keys of *model-providers*
        collect name))

(defun provider-registered-p (name)
  "Check if a provider is registered.

  Args:
    NAME: Provider name

  Returns:
    T if registered"
  (and (gethash name *model-providers*) t))

;;; ============================================================================
;;; Built-in Providers
;;; ============================================================================

(defun register-built-in-providers ()
  "Register built-in model providers.

  Returns:
    T on success"
  ;; Anthropic
  (register-provider "anthropic"
    '(:base-url "https://api.anthropic.com"
      :auth-type :api-key
      :env-var "ANTHROPIC_API_KEY"
      :models ("claude-opus-4-6" "claude-sonnet-4-6" "claude-haiku-4-5")))

  ;; OpenAI
  (register-provider "openai"
    '(:base-url "https://api.openai.com/v1"
      :auth-type :api-key
      :env-var "OPENAI_API_KEY"
      :models ("gpt-4o" "gpt-4o-mini" "o1" "o1-mini")))

  ;; Google
  (register-provider "google"
    '(:base-url "https://generativelanguage.googleapis.com/v1beta"
      :auth-type :api-key
      :env-var "GOOGLE_API_KEY"
      :models ("gemini-2.0-flash" "gemini-2.0-pro"
               "gemini-1.5-pro" "gemini-1.5-flash")))

  ;; Ollama (local)
  (register-provider "ollama"
    '(:base-url "http://localhost:11434"
      :auth-type :none
      :models ("llama-3.1" "mistral" "codellama")))

  ;; Groq
  (register-provider "groq"
    '(:base-url "https://api.groq.com/openai/v1"
      :auth-type :api-key
      :env-var "GROQ_API_KEY"
      :models ("llama-3.3-70b-versatile" "mixtral-8x7b-32768"
               "llama-3.1-70b-versatile" "llama-3.1-8b-instant"
               "gemma2-9b-it")))

  ;; xAI
  (register-provider "xai"
    '(:base-url "https://api.x.ai/v1"
      :auth-type :api-key
      :env-var "XAI_API_KEY"
      :models ("grok-2" "grok-beta" "grok-vision")))

  (log-info "Registered ~A built-in providers"
            (hash-table-count *model-providers*))
  t)

;;; ============================================================================
;;; Model String Parsing
;;; ============================================================================

(defun parse-model-string (model-string)
  "Parse a model string like 'provider/model' or 'provider/sub/model'.

  Args:
    MODEL-STRING: Model identifier string

  Returns:
    Values: (provider model-name)

  Examples:
    (parse-model-string \"anthropic/claude-opus-4-6\")
    => \"anthropic\", \"claude-opus-4-6\"

    (parse-model-string \"openai/gpt-4o\")
    => \"openai\", \"gpt-4o\""
  (let ((parts (split-sequence:split-sequence #\/ model-string)))
    (cond
      ((null parts)
       (values nil nil))
      ((= (length parts) 1)
       ;; No provider specified, use default
       (values "anthropic" (first parts)))
      (t
       ;; Provider/model format
       (values (first parts)
               (format nil "~{~A~^/~}" (rest parts)))))))

(defun normalize-model-string (model-string)
  "Normalize a model string to canonical form.

  Args:
    MODEL-STRING: Model identifier string

  Returns:
    Normalized model string"
  (multiple-value-bind (provider model)
      (parse-model-string model-string)
    (if (and provider model)
        (format nil "~A/~A" provider model)
        model-string)))

;;; ============================================================================
;;; Model Validation
;;; ============================================================================

(defun get-model-info (model-string)
  "Get information about a model.

  Args:
    MODEL-STRING: Model identifier string

  Returns:
    Model info alist or NIL"
  ;; Check cache first
  (let ((cached (gethash model-string *model-cache*)))
    (when cached
      (return-from get-model-info cached)))

  (multiple-value-bind (provider model-name)
      (parse-model-string model-string)
    (unless provider
      (return-from get-model-info nil))

    (let ((provider-config (get-provider provider)))
      (unless provider-config
        (return-from get-model-info nil))

      (let ((models (plist-get provider-config :models)))
        (if (member model-name models :test #'string=)
            ;; Known model
            (let ((info `(:provider ,provider
                          :name ,model-name
                          :base-url ,(plist-get provider-config :base-url)
                          :auth-type ,(plist-get provider-config :auth-type))))
              (setf (gethash model-string *model-cache*) info)
              info)
            ;; Unknown model, but provider exists
            (let ((info `(:provider ,provider
                          :name ,model-name
                          :base-url ,(plist-get provider-config :base-url)
                          :auth-type ,(plist-get provider-config :auth-type)
                          :unknown . t)))
              (setf (gethash model-string *model-cache*) info)
              info))))))

(defun validate-model (model-string)
  "Validate a model identifier.

  Args:
    MODEL-STRING: Model identifier string

  Returns:
    Values: (valid-p error-message)"
  (multiple-value-bind (provider model-name)
      (parse-model-string model-string)
    (cond
      ((null provider)
       (values nil "Invalid model string format"))
      ((null (get-provider provider))
       (values nil (format nil "Unknown provider: ~A" provider)))
      ((null model-name)
       (values nil "Missing model name"))
      (t
       (values t nil)))))

;;; ============================================================================
;;; Model Selection
;;; ============================================================================

(defun select-best-model (&key capabilities constraints)
  "Select the best model for given capabilities and constraints.

  Args:
    CAPABILITIES: Required capabilities (:vision, :code, :reasoning, etc.)
    CONSTRAINTS: Constraints (:max-cost, :max-latency, etc.)

  Returns:
    Model string or NIL"
  (declare (ignore capabilities constraints))
  ;; Simple default for now
  "anthropic/claude-opus-4-6")

(defun get-fallback-model (model-string)
  "Get a fallback model if the primary is unavailable.

  Args:
    MODEL-STRING: Primary model

  Returns:
    Fallback model string"
  (declare (ignore model-string))
  ;; Default fallback
  "anthropic/claude-sonnet-4-6")

;;; ============================================================================
;;; Model Capabilities
;;; ============================================================================

(defun model-supports-vision-p (model-string)
  "Check if model supports vision/images.

  Args:
    MODEL-STRING: Model identifier

  Returns:
    T if supported"
  (let ((info (get-model-info model-string)))
    (when info
      (member (plist-get info :name)
              '("claude-opus-4-6" "claude-sonnet-4-6" "gpt-4o" "gemini-2.0-flash")
              :test #'string=))))

(defun model-supports-streaming-p (model-string)
  "Check if model supports streaming.

  Args:
    MODEL-STRING: Model identifier

  Returns:
    T if supported"
  ;; Most modern models support streaming
  (let ((info (get-model-info model-string)))
    (and info t)))

(defun model-supports-tools-p (model-string)
  "Check if model supports tool calling.

  Args:
    MODEL-STRING: Model identifier

  Returns:
    T if supported"
  (let ((info (get-model-info model-string)))
    (when info
      (member (plist-get info :name)
              '("claude-opus-4-6" "claude-sonnet-4-6" "gpt-4o" "gemini-2.0-flash")
              :test #'string=))))

;;; ============================================================================
;;; Model Pricing (for usage tracking)
;;; ============================================================================

(defun get-model-pricing (model-string)
  "Get pricing information for a model.

  Args:
    MODEL-STRING: Model identifier

  Returns:
    Pricing alist (:input-price, :output-price per 1K tokens)"
  (let ((info (get-model-info model-string)))
    (unless info
      (return-from get-model-pricing nil))

    (let ((name (plist-get info :name)))
      (cond
        ((string= name "claude-opus-4-6")
         '(:input-price 0.015 :output-price 0.075))
        ((string= name "claude-sonnet-4-6")
         '(:input-price 0.003 :output-price 0.015))
        ((string= name "claude-haiku-4-5")
         '(:input-price 0.00025 :output-price 0.00125))
        ((string= name "gpt-4o")
         '(:input-price 0.005 :output-price 0.015))
        ((string= name "gpt-4o-mini")
         '(:input-price 0.00015 :output-price 0.0006))
        (t
         '(:input-price 0.001 :output-price 0.003))))))

;;; ============================================================================
;;; Conditions
;;; ============================================================================

(define-condition model-not-found-error (error)
  ((model :initarg :model :reader error-model)
   (message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "Model not found '~A': ~A"
                     (error-model condition)
                     (error-message condition)))))
