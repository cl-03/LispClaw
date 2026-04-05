;;; mcp/server.lisp --- MCP Server Mode for Lisp-Claw
;;;
;;; This file implements MCP server mode, allowing Lisp-Claw to expose
;;; its tools and capabilities as an MCP server for other AI systems.

(defpackage #:lisp-claw.mcp.server
  (:nicknames #:lc.mcp.server)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; MCP Server class
   #:mcp-server
   #:make-mcp-server
   #:mcp-server-name
   #:mcp-server-version
   #:mcp-server-port
   #:mcp-server-running-p
   ;; Server lifecycle
   #:mcp-server-start
   #:mcp-server-stop
   #:mcp-server-restart
   ;; Tool registration
   #:mcp-register-tool
   #:mcp-unregister-tool
   #:mcp-list-tools
   #:mcp-get-tool
   ;; Resource registration
   #:mcp-register-resource
   #:mcp-unregister-resource
   #:mcp-list-resources
   #:mcp-get-resource
   ;; Prompt registration
   #:mcp-register-prompt
   #:mcp-unregister-prompt
   #:mcp-list-prompts
   #:mcp-get-prompt
   ;; Protocol handling
   #:mcp-handle-request
   #:mcp-handle-notification
   ;; Configuration
   #:*mcp-server-protocol*
   #:*mcp-server-host*
   #:*mcp-server-port*))

(in-package #:lisp-claw.mcp.server)

;;; ============================================================================
;;; Configuration
;;; ============================================================================

(defvar *mcp-server-protocol* :stdio
  "Server protocol: :stdio or :http")

(defvar *mcp-server-host* "127.0.0.1"
  "Server host for HTTP mode")

(defvar *mcp-server-port* 8765
  "Server port for HTTP mode")

(defvar *mcp-spec-version* "2024-11-05"
  "Supported MCP specification version")

;;; ============================================================================
;;; MCP Server Class
;;; ============================================================================

(defclass mcp-server ()
  ((name :initarg :name
         :initform "lisp-claw"
         :reader mcp-server-name
         :documentation "Server name")
   (version :initarg :version
            :initform "0.1.0"
            :reader mcp-server-version
            :documentation "Server version")
   (port :initarg :port
         :initform *mcp-server-port*
         :accessor mcp-server-port
         :documentation "Server port")
   (host :initarg :host
         :initform *mcp-server-host*
         :accessor mcp-server-host
         :documentation "Server host")
   (protocol :initarg :protocol
             :initform *mcp-server-protocol*
             :reader mcp-server-protocol
             :documentation "Communication protocol")
   (running-p :initform nil
              :accessor mcp-server-running-p
              :documentation "Server running status")
   (tools :initform (make-hash-table :test 'equal)
          :accessor mcp-server-tools
          :documentation "Registered tools")
   (resources :initform (make-hash-table :test 'equal)
              :accessor mcp-server-resources
              :documentation "Registered resources")
   (prompts :initform (make-hash-table :test 'equal)
            :accessor mcp-server-prompts
            :documentation "Registered prompts")
   (capabilities :initform (list :tools :resources :prompts)
                 :accessor mcp-server-capabilities
                 :documentation "Server capabilities")
   (request-id :initform 0
               :accessor mcp-server-request-id
               :documentation "Request ID counter"))
  (:documentation "MCP (Model Context Protocol) server"))

(defmethod print-object ((server mcp-server) stream)
  (print-unreadable-object (server stream :type t)
    (format stream "~A [~A]"
            (mcp-server-name server)
            (if (mcp-server-running-p server) "running" "stopped"))))

(defun make-mcp-server (&key name version port host protocol)
  "Create an MCP server.

  Args:
    NAME: Server name (default: \"lisp-claw\")
    VERSION: Server version (default: \"0.1.0\")
    PORT: Server port (default: 8765)
    HOST: Server host (default: \"127.0.0.1\")
    PROTOCOL: Protocol type (default: :stdio)

  Returns:
    MCP server instance"
  (make-instance 'mcp-server
                 :name (or name "lisp-claw")
                 :version (or version "0.1.0")
                 :port (or port *mcp-server-port*)
                 :host (or host *mcp-server-host*)
                 :protocol (or protocol *mcp-server-protocol*)))

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defclass mcp-tool ()
  ((name :initarg :name
         :reader mcp-tool-name
         :documentation "Tool name")
   (description :initarg :description
                :reader mcp-tool-description
                :documentation "Tool description")
   (input-schema :initarg :input-schema
                 :reader mcp-tool-input-schema
                 :documentation "JSON Schema for input")
   (handler :initarg :handler
            :reader mcp-tool-handler
            :documentation "Tool handler function"))
  (:documentation "MCP tool definition"))

(defun mcp-register-tool (server name description input-schema handler)
  "Register a tool with the MCP server.

  Args:
    SERVER: MCP server instance
    NAME: Tool name
    DESCRIPTION: Tool description
    INPUT-SCHEMA: JSON Schema for input validation
    HANDLER: Function to handle tool calls

  Returns:
    T on success"
  (let ((tool (make-instance 'mcp-tool
                             :name name
                             :description description
                             :input-schema input-schema
                             :handler handler)))
    (setf (gethash name (mcp-server-tools server)) tool)
    (log-info "Registered MCP tool: ~A" name)
    t))

(defun mcp-unregister-tool (server name)
  "Unregister a tool from the MCP server.

  Args:
    SERVER: MCP server instance
    NAME: Tool name

  Returns:
    T if tool was removed"
  (when (gethash name (mcp-server-tools server))
    (remhash name (mcp-server-tools server))
    (log-info "Unregistered MCP tool: ~A" name)
    t))

(defun mcp-list-tools (server)
  "List all registered tools.

  Args:
    SERVER: MCP server instance

  Returns:
    List of tool definitions"
  (let ((tools nil))
    (maphash (lambda (name tool)
               (declare (ignore name))
               (push (list :name (mcp-tool-name tool)
                           :description (mcp-tool-description tool)
                           :inputSchema (mcp-tool-input-schema tool))
                     tools))
             (mcp-server-tools server))
    tools))

(defun mcp-get-tool (server name)
  "Get a tool by name.

  Args:
    SERVER: MCP server instance
    NAME: Tool name

  Returns:
    MCP tool instance or NIL"
  (gethash name (mcp-server-tools server)))

;;; ============================================================================
;;; Resource Registration
;;; ============================================================================

(defclass mcp-resource ()
  ((uri :initarg :uri
        :reader mcp-resource-uri
        :documentation "Resource URI")
   (name :initarg :name
         :reader mcp-resource-name
         :documentation "Resource name")
   (description :initarg :description
                :reader mcp-resource-description
                :documentation "Resource description")
   (mime-type :initarg :mime-type
              :initform "text/plain"
              :reader mcp-resource-mime-type
              :documentation "MIME type")
   (content :initarg :content
            :accessor mcp-resource-content
            :documentation "Resource content or content function"))
  (:documentation "MCP resource definition"))

(defun mcp-register-resource (server uri name description content &key mime-type)
  "Register a resource with the MCP server.

  Args:
    SERVER: MCP server instance
    URI: Resource URI
    NAME: Resource name
    DESCRIPTION: Resource description
    CONTENT: Content or function returning content
    MIME-TYPE: MIME type (default: \"text/plain\")

  Returns:
    T on success"
  (let ((resource (make-instance 'mcp-resource
                                 :uri uri
                                 :name name
                                 :description description
                                 :content content
                                 :mime-type (or mime-type "text/plain"))))
    (setf (gethash uri (mcp-server-resources server)) resource)
    (log-info "Registered MCP resource: ~A" uri)
    t))

(defun mcp-unregister-resource (server uri)
  "Unregister a resource from the MCP server.

  Args:
    SERVER: MCP server instance
    URI: Resource URI

  Returns:
    T if resource was removed"
  (when (gethash uri (mcp-server-resources server))
    (remhash uri (mcp-server-resources server))
    (log-info "Unregistered MCP resource: ~A" uri)
    t))

(defun mcp-list-resources (server)
  "List all registered resources.

  Args:
    SERVER: MCP server instance

  Returns:
    List of resource definitions"
  (let ((resources nil))
    (maphash (lambda (uri resource)
               (declare (ignore uri))
               (push (list :uri (mcp-resource-uri resource)
                           :name (mcp-resource-name resource)
                           :description (mcp-resource-description resource)
                           :mimeType (mcp-resource-mime-type resource))
                     resources))
             (mcp-server-resources server))
    resources))

(defun mcp-get-resource (server uri)
  "Get a resource by URI.

  Args:
    SERVER: MCP server instance
    URI: Resource URI

  Returns:
    Resource content or NIL"
  (let ((resource (gethash uri (mcp-server-resources server))))
    (when resource
      (let ((content (mcp-resource-content resource)))
        (if (functionp content)
            (funcall content)
            content)))))

;;; ============================================================================
;;; Prompt Registration
;;; ============================================================================

(defclass mcp-prompt ()
  ((name :initarg :name
         :reader mcp-prompt-name
         :documentation "Prompt name")
   (description :initarg :description
                :reader mcp-prompt-description
                :documentation "Prompt description")
   (arguments :initarg :arguments
              :initform nil
              :reader mcp-prompt-arguments
              :documentation "Prompt arguments schema")
   (handler :initarg :handler
            :reader mcp-prompt-handler
            :documentation "Prompt handler function"))
  (:documentation "MCP prompt definition"))

(defun mcp-register-prompt (server name description handler &key arguments)
  "Register a prompt with the MCP server.

  Args:
    SERVER: MCP server instance
    NAME: Prompt name
    DESCRIPTION: Prompt description
    HANDLER: Function to handle prompt requests
    ARGUMENTS: Argument schema (optional)

  Returns:
    T on success"
  (let ((prompt (make-instance 'mcp-prompt
                               :name name
                               :description description
                               :arguments (or arguments (list))
                               :handler handler)))
    (setf (gethash name (mcp-server-prompts server)) prompt)
    (log-info "Registered MCP prompt: ~A" name)
    t))

(defun mcp-unregister-prompt (server name)
  "Unregister a prompt from the MCP server.

  Args:
    SERVER: MCP server instance
    NAME: Prompt name

  Returns:
    T if prompt was removed"
  (when (gethash name (mcp-server-prompts server))
    (remhash name (mcp-server-prompts server))
    (log-info "Unregistered MCP prompt: ~A" name)
    t))

(defun mcp-list-prompts (server)
  "List all registered prompts.

  Args:
    SERVER: MCP server instance

  Returns:
    List of prompt definitions"
  (let ((prompts nil))
    (maphash (lambda (name prompt)
               (declare (ignore name))
               (push (list :name (mcp-prompt-name prompt)
                           :description (mcp-prompt-description prompt)
                           :arguments (mcp-prompt-arguments prompt))
                     prompts))
             (mcp-server-prompts server))
    prompts))

(defun mcp-get-prompt (server name)
  "Get a prompt by name.

  Args:
    SERVER: MCP server instance
    NAME: Prompt name

  Returns:
    MCP prompt instance or NIL"
  (gethash name (mcp-server-prompts server)))

;;; ============================================================================
;;; Protocol Handling
;;; ============================================================================

(defun mcp-create-response (id result)
  "Create an MCP response.

  Args:
    ID: Request ID
    RESULT: Result data

  Returns:
    Response plist"
  (list :jsonrpc "2.0"
        :id id
        :result result))

(defun mcp-create-error (id code message &optional data)
  "Create an MCP error response.

  Args:
    ID: Request ID
    CODE: Error code
    MESSAGE: Error message
    DATA: Optional error data

  Returns:
    Error response plist"
  (let ((error (list :code code
                     :message message)))
    (when data
      (setf error (plist-put error :data data)))
    (list :jsonrpc "2.0"
          :id id
          :error error)))

(defun mcp-handle-request (server request)
  "Handle an MCP request.

  Args:
    SERVER: MCP server instance
    REQUEST: Request plist

  Returns:
    Response plist"
  (let* ((method (getf request :method))
         (params (getf request :params))
         (id (getf request :id)))

    (log-debug "Handling MCP request: ~A" method)

    (handler-case
        (cond
          ;; Initialization
          ((string= method "initialize")
           (mcp-create-response id
                                (list :protocolVersion *mcp-spec-version*
                                      :capabilities (list :tools (list :listChanged t)
                                                          :resources (list :subscribe t)
                                                          :prompts (list :listChanged t))
                                      :serverInfo (list :name (mcp-server-name server)
                                                        :version (mcp-server-version server)))))

          ;; Tools
          ((string= method "tools/list")
           (mcp-create-response id (list :tools (mcp-list-tools server))))

          ((string= method "tools/call")
           (let* ((tool-name (getf params :name))
                  (tool-args (getf params :arguments))
                  (tool (mcp-get-tool server tool-name)))
             (if tool
                 (let ((result (funcall (mcp-tool-handler tool) tool-args)))
                   (mcp-create-response id result))
                 (mcp-create-error id -32602
                                   (format nil "Unknown tool: ~A" tool-name)))))

          ;; Resources
          ((string= method "resources/list")
           (mcp-create-response id (list :resources (mcp-list-resources server))))

          ((string= method "resources/get")
           (let* ((uri (getf params :uri))
                  (content (mcp-get-resource server uri)))
             (if content
                 (mcp-create-response id (list :contents content))
                 (mcp-create-error id -32602
                                   (format nil "Unknown resource: ~A" uri)))))

          ;; Prompts
          ((string= method "prompts/list")
           (mcp-create-response id (list :prompts (mcp-list-prompts server))))

          ((string= method "prompts/get")
           (let* ((prompt-name (getf params :name))
                  (prompt (mcp-get-prompt server prompt-name)))
             (if prompt
                 (let ((result (funcall (mcp-prompt-handler prompt) params)))
                   (mcp-create-response id result))
                 (mcp-create-error id -32602
                                   (format nil "Unknown prompt: ~A" prompt-name)))))

          ;; Unknown method
          (t
           (mcp-create-error id -32601
                             (format nil "Unknown method: ~A" method))))

      (error (e)
        (log-error "MCP request handler error: ~A" e)
        (mcp-create-error id -32603 (princ-to-string e))))))

(defun mcp-handle-notification (server notification)
  "Handle an MCP notification.

  Args:
    SERVER: MCP server instance
    NOTIFICATION: Notification plist

  Returns:
    NIL (notifications don't send responses)"
  (let ((method (getf notification :method))
        (params (getf notification :params)))

    (log-debug "Handling MCP notification: ~A" method)

    (cond
      ((string= method "notifications/initialized")
       (log-info "Client initialized"))

      ((string= method "notifications/tools/list_changed")
       (log-info "Tools list changed"))

      ((string= method "notifications/resources/list_changed")
       (log-info "Resources list changed"))

      (t
       (log-warning "Unknown notification: ~A" method)))

    nil))

;;; ============================================================================
;;; Server Lifecycle
;;; ============================================================================

(defun mcp-server-start-stdio (server)
  "Start MCP server in STDIO mode.

  Args:
    SERVER: MCP server instance

  Returns:
    T on success"
  (log-info "Starting MCP server in STDIO mode")
  (setf (mcp-server-running-p server) t)

  ;; Main loop for STDIO
  (loop while (mcp-server-running-p server)
        do (let* ((line (read-line *standard-input* nil nil)))
             (when line
               (let* ((request (parse-json line))
                      (response (if (getf request :method)
                                    (mcp-handle-request server request)
                                    (mcp-handle-notification server request))))
                 (when response
                   (let ((json (json-to-string response)))
                     (write-line json *standard-output*)
                     (finish-output *standard-output*)))))))

  t)

(defun mcp-server-start-http (server)
  "Start MCP server in HTTP mode.

  Args:
    SERVER: MCP server instance

  Returns:
    T on success"
  (log-info "Starting MCP server in HTTP mode on ~A:~A"
            (mcp-server-host server)
            (mcp-server-port server))

  (setf (mcp-server-running-p server) t)

  ;; HTTP server implementation would go here
  ;; For now, use a simple placeholder
  (log-info "HTTP mode not fully implemented yet")

  t)

(defun mcp-server-start (server &key protocol)
  "Start the MCP server.

  Args:
    SERVER: MCP server instance
    PROTOCOL: Protocol override (default: from server)

  Returns:
    T on success"
  (let ((proto (or protocol (mcp-server-protocol server))))
    (ecase proto
      (:stdio (mcp-server-start-stdio server))
      (:http (mcp-server-start-http server)))))

(defun mcp-server-stop (server)
  "Stop the MCP server.

  Args:
    SERVER: MCP server instance

  Returns:
    T on success"
  (setf (mcp-server-running-p server) nil)
  (log-info "MCP server stopped")
  t)

(defun mcp-server-restart (server)
  "Restart the MCP server.

  Args:
    SERVER: MCP server instance

  Returns:
    T on success"
  (mcp-server-stop server)
  (sleep 1)
  (mcp-server-start server)
  t)

;;; ============================================================================
;;; Built-in Tools Registration
;;; ============================================================================

(defun register-built-in-tools (server)
  "Register built-in Lisp-Claw tools.

  Args:
    SERVER: MCP server instance

  Returns:
    T on success"
  ;; Example: Register a simple echo tool
  (mcp-register-tool server
                     "echo"
                     "Echo back the input message"
                     (list :type "object"
                           :properties (list :message (list :type "string"
                                                            :description "Message to echo"))
                           :required '(:message))
                     (lambda (args)
                       (list :content (list (list :type "text"
                                                  :text (getf args :message))))))

  (log-info "Built-in tools registered")
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-mcp-server-system (&key name version port protocol)
  "Initialize the MCP server system.

  Args:
    NAME: Server name
    VERSION: Server version
    PORT: Server port
    PROTOCOL: Communication protocol

  Returns:
    MCP server instance"
  (let ((server (make-mcp-server :name (or name "lisp-claw")
                                 :version (or version "0.1.0")
                                 :port (or port 8765)
                                 :protocol (or protocol :stdio))))
    (register-built-in-tools server)
    (log-info "MCP server system initialized")
    server))
