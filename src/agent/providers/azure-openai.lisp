;;; agent/providers/azure-openai.lisp --- Azure OpenAI Provider for Lisp-Claw
;;;
;;; This file implements Azure OpenAI Service integration supporting:
;;; - Azure OpenAI REST API
;;; - Azure AD authentication (optional)
;;; - API Key authentication
;;; - Chat completions
;;; - Embeddings
;;; - Deployments management

(defpackage #:lisp-claw.agent.providers.azure-openai
  (:nicknames #:lc.agent.providers.azure-openai)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.agent.providers.base
        #:dexador
        #:json-mop
        #:babel)
  (:export
   ;; Azure OpenAI client class
   #:azure-openai-client
   #:make-azure-openai-client
   ;; Azure-specific operations
   #:azure-deployment
   #:azure-endpoint
   #:azure-api-version
   #:azure-ad-token
   ;; Chat operations
   #:azure-chat-completion
   #:azure-chat-with-tools
   ;; Embeddings
   #:azure-embeddings
   ;; Initialization
   #:initialize-azure-openai-provider))

(in-package #:lisp-claw.agent.providers.azure-openai)

;;; ============================================================================
;;; Azure OpenAI Client Class
;;; ============================================================================

(defclass azure-openai-client (base-agent-client)
  ((endpoint :initarg :endpoint
             :initform nil
             :accessor azure-endpoint
             :documentation "Azure OpenAI endpoint URL")
   (deployment :initarg :deployment
               :initform "gpt-4"
               :accessor azure-deployment
               :documentation "Azure deployment name")
   (api-version :initarg :api-version
                :initform "2024-02-15-preview"
                :accessor azure-api-version
                :documentation "Azure API version")
   (api-key :initarg :api-key
            :initform nil
            :accessor azure-api-key
            :documentation "Azure API Key (alternative to AAD)")
   (tenant-id :initarg :tenant-id
              :initform nil
              :accessor azure-tenant-id
              :documentation "Azure AD Tenant ID")
   (client-id :initarg :client-id
              :initform nil
              :accessor azure-client-id
              :documentation "Azure AD Client ID")
   (client-secret :initarg :client-secret
                  :initform nil
                  :accessor azure-client-secret
                  :documentation "Azure AD Client Secret")
   (ad-token :initform nil
             :accessor azure-ad-token
             :documentation "Azure AD access token")
   (ad-token-expires :initform nil
                     :accessor azure-ad-token-expires
                     :documentation "Azure AD token expiration time"))
  (:documentation "Azure OpenAI Service client"))

(defmethod print-object ((client azure-openai-client) stream)
  (print-unreadable-object (client stream :type t)
    (format stream "~A [~A]" (azure-deployment client) (azure-endpoint client))))

(defun make-azure-openai-client (&key endpoint deployment api-version
                                     api-key tenant-id client-id client-secret)
  "Create an Azure OpenAI client.

  Args:
    ENDPOINT: Azure OpenAI endpoint URL (e.g., https://your-resource.openai.azure.com)
    DEPLOYMENT: Deployment name (e.g., gpt-4, gpt-35-turbo)
    API-VERSION: Azure API version (default: 2024-02-15-preview)
    API-KEY: Azure API Key (optional if using AAD)
    TENANT-ID: Azure AD Tenant ID (optional if using API Key)
    CLIENT-ID: Azure AD Client ID (optional)
    CLIENT-SECRET: Azure AD Client Secret (optional)

  Returns:
    Azure OpenAI client instance"
  (let ((client (make-instance 'azure-openai-client
                               :provider :azure-openai
                               :endpoint endpoint
                               :deployment deployment
                               :api-version (or api-version "2024-02-15-preview")
                               :api-key api-key
                               :tenant-id tenant-id
                               :client-id client-id
                               :client-secret client-secret)))
    ;; Authenticate if using AAD
    (when (and tenant-id client-id client-secret)
      (azure-authenticate client))
    client))

;;; ============================================================================
;;; Azure AD Authentication
;;; ============================================================================

(defun azure-authenticate (client)
  "Authenticate with Azure AD using client credentials.

  Args:
    CLIENT: Azure OpenAI client

  Returns:
    Access token or NIL"
  (handler-case
      (let* ((tenant-id (azure-tenant-id client))
             (client-id (azure-client-id client))
             (client-secret (azure-client-secret client))
             (url (format nil "https://login.microsoftonline.com/~A/oauth2/v2.0/token"
                          tenant-id))
             (scope "https://cognitiveservices.azure.com/.default")
             (params (list (cons "client_id" client-id)
                           (cons "client_secret" client-secret)
                           (cons "grant_type" "client_credentials")
                           (cons "scope" scope))))
        (let* ((response (dex:post url :content params))
               (json (json:decode-json-from-string response)))
          (when (gethash "access_token" json)
            (setf (azure-ad-token client) (gethash "access_token" json))
            (setf (azure-ad-token-expires client)
                  (+ (get-universal-time) (gethash "expires_in" json 3600)))
            (log-info "Azure AD token acquired, expires in ~A seconds"
                      (gethash "expires_in" json 3600))
            (azure-ad-token client))))
    (error (e)
      (log-error "Azure AD authentication failed: ~A" e)
      nil)))

(defun azure-ensure-token (client)
  "Ensure valid Azure AD token exists.

  Args:
    CLIENT: Azure OpenAI client

  Returns:
    T if valid token exists"
  (cond
    ;; Using API Key, no token needed
    ((azure-api-key client) t)
    ;; Check if existing token is still valid
    ((and (azure-ad-token client)
          (azure-ad-token-expires client)
          (< (get-universal-time) (- (azure-ad-token-expires client) 300)))
     t)
    ;; Need to refresh token
    ((and (azure-tenant-id client)
          (azure-client-id client)
          (azure-client-secret client))
     (azure-authenticate client))
    ;; No valid authentication
    (t (error "Azure OpenAI: No valid authentication (API Key or AAD)"))))

(defun azure-auth-header (client)
  "Get Azure OpenAI authorization header.

  Args:
    CLIENT: Azure OpenAI client

  Returns:
    Authorization header string"
  (azure-ensure-token client)
  (if (azure-api-key client)
      (list (cons "api-key" (azure-api-key client)))
      (list (cons "Authorization" (format nil "Bearer ~A" (azure-ad-token client))))))

;;; ============================================================================
;;; Chat Completions
;;; ============================================================================

(defun azure-chat-completion (client messages &key temperature max-tokens top-p
                              stop stream tools tool-choice)
  "Create a chat completion using Azure OpenAI.

  Args:
    CLIENT: Azure OpenAI client
    MESSAGES: List of message objects
    TEMPERATURE: Sampling temperature (0-2)
    MAX-TOKENS: Max tokens to generate
    TOP-P: Nucleus sampling parameter
    STOP: Stop sequences
    STREAM: Whether to stream response
    TOOLS: List of tool definitions
    TOOL-CHOICE: Tool choice strategy

  Returns:
    Completion response plist"
  (let* ((deployment (azure-deployment client))
         (endpoint (azure-endpoint client))
         (api-version (azure-api-version client))
         (url (format nil "~A/openai/deployments/~A/chat/completions?api-version=~A"
                      endpoint deployment api-version))
         (headers (azure-auth-header client))
         (body (make-hash-table :test 'equal)))
    ;; Add request parameters
    (setf (gethash "messages" body) (mapcar #'format-azure-message messages))
    (when temperature
      (setf (gethash "temperature" body) temperature))
    (when max-tokens
      (setf (gethash "max_tokens" body) max-tokens))
    (when top-p
      (setf (gethash "top_p" body) top-p))
    (when stop
      (setf (gethash "stop" body) (if (listp stop) stop (list stop))))
    (when stream
      (setf (gethash "stream" body) t))
    (when tools
      (setf (gethash "tools" body) (mapcar #'format-azure-tool tools)))
    (when tool-choice
      (setf (gethash "tool_choice" body) tool-choice))

    ;; Make request
    (handler-case
        (let* ((response (dex:post url
                                   :headers (append headers
                                                    (list (cons "Content-Type"
                                                                "application/json")))
                                   :content (json:encode-json-to-string body)))
               (json (json:decode-json-from-string response)))
          (log-info "Azure OpenAI chat completion: ~A tokens used"
                    (gethash "usage" json))
          (parse-azure-completion json))
      (error (e)
        (log-error "Azure OpenAI chat completion failed: ~A" e)
        (list :status :error :message (princ-to-string e))))))

(defun format-azure-message (message)
  "Format message for Azure OpenAI API.

  Args:
    MESSAGE: Message plist

  Returns:
    Formatted message object"
  (let ((json (make-hash-table :test 'equal)))
    (setf (gethash "role" json) (getf message :role))
    (setf (gethash "content" json) (or (getf message :content) ""))
    (when (getf message :name)
      (setf (gethash "name" json) (getf message :name)))
    (when (getf message :tool-calls)
      (setf (gethash "tool_calls" json)
            (mapcar #'format-azure-tool-call (getf message :tool-calls))))
    (when (getf message :tool-call-id)
      (setf (gethash "tool_call_id" json) (getf message :tool-call-id)))
    json))

(defun format-azure-tool (tool)
  "Format tool definition for Azure OpenAI API.

  Args:
    TOOL: Tool definition plist

  Returns:
    Formatted tool object"
  (let ((json (make-hash-table :test 'equal)))
    (setf (gethash "type" json) "function")
    (let ((func-json (make-hash-table :test 'equal)))
      (setf (gethash "name" func-json) (getf tool :name))
      (setf (gethash "description" func-json) (or (getf tool :description) ""))
      (when (getf tool :parameters)
        (setf (gethash "parameters" func-json) (getf tool :parameters)))
      (setf (gethash "function" json) func-json))
    json))

(defun format-azure-tool-call (tool-call)
  "Format tool call for Azure OpenAI API.

  Args:
    TOOL-CALL: Tool call plist

  Returns:
    Formatted tool call object"
  (let ((json (make-hash-table :test 'equal)))
    (setf (gethash "id" json) (getf tool-call :id))
    (setf (gethash "type" json) "function")
    (let ((func-json (make-hash-table :test 'equal)))
      (setf (gethash "name" func-json) (getf tool-call :function-name))
      (setf (gethash "arguments" func-json)
            (if (stringp (getf tool-call :arguments))
                (getf tool-call :arguments)
                (json:encode-json-to-string (getf tool-call :arguments))))
      (setf (gethash "function" json) func-json))
    json))

(defun parse-azure-completion (json)
  "Parse Azure OpenAI completion response.

  Args:
    JSON: Response JSON object

  Returns:
    Parsed response plist"
  (let* ((choices (gethash "choices" json nil))
         (choice (first choices))
         (message (gethash "message" choice))
         (usage (gethash "usage" json)))
    (list :status :success
          :content (gethash "content" message)
          :role (gethash "role" message)
          :finish-reason (gethash "finish_reason" choice)
          :prompt-tokens (gethash "prompt_tokens" usage 0)
          :completion-tokens (gethash "completion_tokens" usage 0)
          :total-tokens (gethash "total_tokens" usage 0)
          :tool-calls (parse-azure-tool-calls (gethash "tool_calls" message)))))

(defun parse-azure-tool-calls (tool-calls)
  "Parse tool calls from Azure OpenAI response.

  Args:
    TOOL-CALLS: Tool calls array from response

  Returns:
    List of parsed tool calls"
  (when tool-calls
    (mapcar (lambda (tc)
              (let ((func (gethash "function" tc)))
                (list :id (gethash "id" tc)
                      :function-name (gethash "name" func)
                      :arguments (json:decode-json-from-string
                                  (gethash "arguments" func)))))
            tool-calls)))

(defun azure-chat-with-tools (client messages tools &key temperature max-tokens)
  "Chat with tools support, handling tool execution loop.

  Args:
    CLIENT: Azure OpenAI client
    MESSAGES: Initial messages
    TOOLS: Available tools
    TEMPERATURE: Sampling temperature
    MAX-TOKENS: Max tokens

  Returns:
    Final response plist"
  (let ((current-messages messages)
        (max-iterations 10)
        (iteration 0))
    (loop
      (incf iteration)
      (when (> iteration max-iterations)
        (return (list :status :error :message "Max tool call iterations exceeded")))

      (let ((response (azure-chat-completion client current-messages
                                             :temperature temperature
                                             :max-tokens max-tokens
                                             :tools tools)))
        (if (eq (getf response :status) :error)
            (return response)
            (progn
              ;; Check for tool calls
              (let ((tool-calls (getf response :tool-calls)))
                (if (null tool-calls)
                    ;; No tool calls, return final response
                    (return response)
                    ;; Execute tools and continue
                    (let ((tool-results (execute-tools tool-calls tools)))
                      ;; Add assistant message and tool results
                      (push (list :role "assistant"
                                  :content (getf response :content)
                                  :tool-calls tool-calls)
                            current-messages)
                      (dolist (result tool-results)
                        (push (list :role "tool"
                                    :tool-call-id (getf result :call-id)
                                    :content (getf result :result))
                              current-messages)))))))))))

(defun execute-tools (tool-calls tools)
  "Execute tool calls and return results.

  Args:
    TOOL-CALLS: List of tool calls
    TOOLS: Available tool definitions

  Returns:
    List of tool results"
  (mapcar (lambda (tc)
            (let* ((name (getf tc :function-name))
                   (args (getf tc :arguments))
                   (tool (find name tools :key #'getf :test #'string=)))
              (if tool
                  (handler-case
                      (let ((result (funcall (getf tool :handler) args)))
                        (list :call-id (getf tc :id)
                              :result (if (stringp result)
                                          result
                                          (json:encode-json-to-string result))))
                    (error (e)
                      (list :call-id (getf tc :id)
                            :result (format nil "Error: ~A" e))))
                  (list :call-id (getf tc :id)
                        :result (format nil "Unknown tool: ~A" name)))))
          tool-calls))

;;; ============================================================================
;;; Embeddings
;;; ============================================================================

(defun azure-embeddings (client texts &key deployment)
  "Generate embeddings using Azure OpenAI.

  Args:
    CLIENT: Azure OpenAI client
    TEXTS: Text or list of texts to embed
    DEPLOYMENT: Embedding deployment name (default: text-embedding-ada-002)

  Returns:
    Embeddings list"
  (let* ((embedding-deployment (or deployment "text-embedding-ada-002"))
         (endpoint (azure-endpoint client))
         (api-version (azure-api-version client))
         (url (format nil "~A/openai/deployments/~A/embeddings?api-version=~A"
                      endpoint embedding-deployment api-version))
         (headers (azure-auth-header client))
         (body (make-hash-table :test 'equal)))
    ;; Add input
    (setf (gethash "input" body) (if (listp texts) texts (list texts)))

    ;; Make request
    (handler-case
        (let* ((response (dex:post url
                                   :headers (append headers
                                                    (list (cons "Content-Type"
                                                                "application/json")))
                                   :content (json:encode-json-to-string body)))
               (json (json:decode-json-from-string response)))
          (log-info "Azure OpenAI embeddings generated: ~A texts"
                    (length (gethash "data" json)))
          (mapcar (lambda (item)
                    (list :index (gethash "index" item)
                          :embedding (gethash "embedding" item)))
                  (gethash "data" json)))
      (error (e)
        (log-error "Azure OpenAI embeddings failed: ~A" e)
        nil))))

;;; ============================================================================
;;; Provider Registration
;;; ============================================================================

(defun register-azure-openai-provider ()
  "Register Azure OpenAI as an available provider.

  Returns:
    T on success"
  (let ((registry (or (getf lisp-claw.agent.providers.base:*agent-providers*
                            :registry)
                      (make-hash-table :test 'equal))))
    (setf (gethash :azure-openai registry)
          (list :name "Azure OpenAI"
                :class 'azure-openai-client
                :make-fn #'make-azure-openai-client
                :chat-fn #'azure-chat-completion
                :embeddings-fn #'azure-embeddings))
    (setf lisp-claw.agent.providers.base:*agent-providers*
          (list :registry registry))
    (log-info "Azure OpenAI provider registered")
    t))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-azure-openai-provider ()
  "Initialize the Azure OpenAI provider.

  Returns:
    T on success"
  (register-azure-openai-provider)
  (log-info "Azure OpenAI provider initialized")
  t)
