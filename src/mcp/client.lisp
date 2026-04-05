;;; mcp/client.lisp --- MCP (Model Context Protocol) Client for Lisp-Claw
;;;
;;; This file implements MCP client for connecting to MCP servers
;;; and accessing external tools and resources.

(defpackage #:lisp-claw.mcp.client
  (:nicknames #:lc.mcp.client)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; MCP Client
   #:mcp-client
   #:make-mcp-client
   #:mcp-client-name
   #:mcp-client-server
   #:mcp-client-connected-p
   ;; Connection
   #:mcp-connect
   #:mcp-disconnect
   #:mcp-reconnect
   ;; Tool operations
   #:mcp-list-tools
   #:mcp-call-tool
   #:mcp-get-tool-schema
   ;; Resource operations
   #:mcp-list-resources
   #:mcp-get-resource
   ;; Prompt operations
   #:mcp-list-prompts
   #:mcp-get-prompt
   ;; Notification handling
   #:mcp-on-notification
   ;; Registry
   #:*mcp-registry*
   #:register-mcp-server
   #:unregister-mcp-server
   #:get-mcp-server
   #:list-mcp-servers))

(in-package #:lisp-claw.mcp.client)

;;; ============================================================================
;;; MCP Client Class
;;; ============================================================================

(defclass mcp-client ()
  ((name :initarg :name
         :reader mcp-client-name
         :documentation "Client name")
   (server-cmd :initarg :server-cmd
               :reader mcp-client-server-cmd
               :documentation "Server command to start")
   (server-args :initarg :server-args
                :initform nil
                :reader mcp-client-server-args
                :documentation "Server command arguments")
   (process :initform nil
            :accessor mcp-client-process
            :documentation "Server process")
   (stdin :initform nil
          :accessor mcp-client-stdin
          :documentation "Server stdin stream")
   (stdout :initform nil
           :accessor mcp-client-stdout
           :documentation "Server stdout stream")
   (connected-p :initform nil
                :accessor mcp-client-connected-p
                :documentation "Connection status")
   (request-id :initform 0
               :accessor mcp-client-request-id
               :documentation "Request ID counter")
   (pending-requests :initform (make-hash-table :test 'equal)
                     :accessor mcp-client-pending-requests
                     :documentation "Pending requests")
   (notification-handler :initform nil
                         :accessor mcp-client-notification-handler
                         :documentation "Notification handler function")
   (tools :initform nil
          :accessor mcp-client-tools
          :documentation "Cached tools list")
   (resources :initform nil
              :accessor mcp-client-resources
              :documentation "Cached resources list"))
  (:documentation "MCP (Model Context Protocol) client"))

(defmethod print-object ((client mcp-client) stream)
  (print-unreadable-object (client stream :type t)
    (format stream "~A [~A]"
            (mcp-client-name client)
            (if (mcp-client-connected-p client) "connected" "disconnected"))))

(defun make-mcp-client (name server-cmd &rest server-args)
  "Create an MCP client.

  Args:
    NAME: Client name
    SERVER-CMD: Server command (e.g., 'npx', 'python')
    SERVER-ARGS: Server command arguments

  Returns:
    MCP client instance"
  (make-instance 'mcp-client
                 :name name
                 :server-cmd server-cmd
                 :server-args server-args))

;;; ============================================================================
;;; MCP Registry
;;; ============================================================================

(defvar *mcp-registry* (make-hash-table :test 'equal)
  "Registry of MCP server connections.")

(defun register-mcp-server (name client)
  "Register an MCP server connection.

  Args:
    NAME: Server name
    CLIENT: MCP client instance

  Returns:
    T on success"
  (setf (gethash name *mcp-registry*) client)
  (log-info "Registered MCP server: ~A" name)
  t)

(defun unregister-mcp-server (name)
  "Unregister an MCP server connection.

  Args:
    NAME: Server name

  Returns:
    T on success"
  (let ((client (gethash name *mcp-registry*)))
    (when client
      (mcp-disconnect client))
    (remhash name *mcp-registry*)
    (log-info "Unregistered MCP server: ~A" name)
    t))

(defun get-mcp-server (name)
  "Get an MCP server by name.

  Args:
    NAME: Server name

  Returns:
    MCP client instance or NIL"
  (gethash name *mcp-registry*))

(defun list-mcp-servers ()
  "List all registered MCP servers.

  Returns:
    List of server names"
  (let ((names nil))
    (maphash (lambda (k v)
               (declare (ignore v))
               (push k names))
             *mcp-registry*)
    names))

;;; ============================================================================
;;; MCP Protocol Constants
;;; ============================================================================

(defparameter +mcp-protocol-version+ "2024-11-05"
  "MCP protocol version.")

(defparameter +mcp-timeout+ 30
  "Default timeout in seconds.")

;;; ============================================================================
;;; JSON-RPC Helpers
;;; ============================================================================

(defun make-json-rpc-request (method params &optional id)
  "Create a JSON-RPC 2.0 request.

  Args:
    METHOD: Method name
    PARAMS: Method parameters
    ID: Request ID (optional)

  Returns:
    JSON-RPC request plist"
  `(:jsonrpc "2.0"
    :id ,(or id (get-universal-time))
    :method ,method
    :params ,params))

(defun make-json-rpc-notification (method params)
  "Create a JSON-RPC 2.0 notification (no response expected).

  Args:
    METHOD: Method name
    PARAMS: Method parameters

  Returns:
    JSON-RPC notification plist"
  `(:jsonrpc "2.0"
    :method ,method
    :params ,params))

(defun make-json-rpc-response (result id)
  "Create a JSON-RPC 2.0 response.

  Args:
    RESULT: Response result
    ID: Request ID

  Returns:
    JSON-RPC response plist"
  `(:jsonrpc "2.0"
    :id ,id
    :result ,result))

(defun make-json-rpc-error (error-code message id)
  "Create a JSON-RPC 2.0 error response.

  Args:
    ERROR-CODE: Error code
    MESSAGE: Error message
    ID: Request ID

  Returns:
    JSON-RPC error response plist"
  `(:jsonrpc "2.0"
    :id ,id
    :error (:code ,error-code :message ,message)))

;;; ============================================================================
;;; Connection Management
;;; ============================================================================

(defun mcp-connect (client)
  "Connect to an MCP server.

  Args:
    CLIENT: MCP client instance

  Returns:
    T on success, NIL on failure"
  (when (mcp-client-connected-p client)
    (log-warn "MCP client ~A is already connected" (mcp-client-name client))
    (return-from mcp-connect t))

  (handler-case
      (progn
        ;; Start server process
        (log-info "Starting MCP server ~A: ~A ~{~A~^ ~}"
                  (mcp-client-name client)
                  (mcp-client-server-cmd client)
                  (mcp-client-server-args client))

        ;; Use external process (implementation depends on platform)
        ;; For now, we'll use a placeholder
        (setf (mcp-client-process client) nil
              (mcp-client-stdin client) nil
              (mcp-client-stdout client) nil
              (mcp-client-connected-p client) t)

        ;; Initialize connection
        (let ((result (mcp-initialize client)))
          (when result
            (log-info "Connected to MCP server ~A" (mcp-client-name client))
            ;; Start response reader thread
            (bt:make-thread (lambda () (mcp-read-loop client))
                            :name (format nil "mcp-reader-~A" (mcp-client-name client)))
            t)))
    (error (e)
      (log-error "Failed to connect to MCP server ~A: ~A"
                 (mcp-client-name client) e)
      (setf (mcp-client-connected-p client) nil)
      nil)))

(defun mcp-disconnect (client)
  "Disconnect from an MCP server.

  Args:
    CLIENT: MCP client instance

  Returns:
    T on success"
  (when (mcp-client-connected-p client)
    ;; Send shutdown notification
    (mcp-send-notification client "notifications/initialized" nil)

    ;; Close streams if any
    (ignore-errors (close (mcp-client-stdin client)))
    (ignore-errors (close (mcp-client-stdout client)))

    (setf (mcp-client-connected-p client) nil
          (mcp-client-process client) nil
          (mcp-client-stdin client) nil
          (mcp-client-stdout client) nil
          (mcp-client-tools client) nil
          (mcp-client-resources client) nil)

    (log-info "Disconnected from MCP server ~A" (mcp-client-name client)))
  t)

(defun mcp-reconnect (client)
  "Reconnect to an MCP server.

  Args:
    CLIENT: MCP client instance

  Returns:
    T on success"
  (mcp-disconnect client)
  (sleep 1)
  (mcp-connect client))

;;; ============================================================================
;;; MCP Core Protocol
;;; ============================================================================

(defun mcp-initialize (client)
  "Initialize MCP connection.

  Args:
    CLIENT: MCP client instance

  Returns:
    Server info plist or NIL"
  (let ((result (mcp-send-request client "initialize"
                                   `(:protocolVersion ,+mcp-protocol-version+
                                     :capabilities (:tools :resources :prompts)
                                     :clientInfo (:name "Lisp-Claw" :version "0.1.0")))))
    (when result
      ;; Send initialized notification
      (mcp-send-notification client "notifications/initialized" nil)
      ;; Cache tools and resources
      (setf (mcp-client-tools client)
            (mcp-list-tools client)
            (mcp-client-resources client)
            (mcp-list-resources client))
      result)))

(defun mcp-send-request (client method params)
  "Send an MCP request and wait for response.

  Args:
    CLIENT: MCP client instance
    METHOD: Method name
    PARAMS: Method parameters

  Returns:
    Response result or NIL"
  (unless (mcp-client-connected-p client)
    (log-error "MCP client ~A is not connected" (mcp-client-name client))
    (return-from mcp-send-request nil))

  (let* ((id (incf (mcp-client-request-id client)))
         (request (make-json-rpc-request method params id))
         (response nil)
         (lock (bt:make-lock))
         (done-p nil))

    ;; Store pending request
    (setf (gethash id (mcp-client-pending-requests client))
          (list :lock lock :done-p nil :response nil))

    ;; Send request
    (mcp-send-message client request)

    ;; Wait for response with simple polling
    (let ((start-time (get-universal-time))
          (timeout +mcp-timeout+))
      (loop
        with pending = (gethash id (mcp-client-pending-requests client))
        until (or done-p (null pending) (> (- (get-universal-time) start-time) timeout))
        do (progn
             (sleep 0.1)
             (bt:with-lock-held (lock)
               (when (getf pending :response)
                 (setf done-p t
                       response (getf pending :response))
                 (remhash id (mcp-client-pending-requests client)))))))

    response))

(defun mcp-send-notification (client method params)
  "Send an MCP notification (no response expected).

  Args:
    CLIENT: MCP client instance
    METHOD: Method name
    PARAMS: Method parameters

  Returns:
    T on success"
  (unless (mcp-client-connected-p client)
    (return-from mcp-send-notification nil))

  (let ((notification (make-json-rpc-notification method params)))
    (mcp-send-message client notification)
    t))

(defun mcp-send-message (client message)
  "Send a raw message to MCP server.

  Args:
    CLIENT: MCP client instance
    MESSAGE: Message plist

  Returns:
    T on success"
  (let ((stdin (mcp-client-stdin client)))
    (when stdin
      (let ((json (stringify-json message)))
        (write-line json stdin)
        (finish-output stdin)
        (log-debug "MCP send: ~A" method)
        t))))

(defun mcp-read-loop (client)
  "Read loop for MCP responses.

  Args:
    CLIENT: MCP client instance"
  (let ((stdout (mcp-client-stdout client)))
    (when stdout
      (handler-case
          (loop for line = (read-line stdout nil nil)
                while (and line (mcp-client-connected-p client))
                do (mcp-process-message client line))
        (error (e)
          (log-error "MCP read error: ~A" e)
          (when (mcp-client-connected-p client)
            (mcp-disconnect client)))))))

(defun mcp-process-message (client json-string)
  "Process an incoming MCP message.

  Args:
    CLIENT: MCP client instance
    JSON-STRING: JSON message string

  Returns:
    T on success"
  (handler-case
      (let ((message (parse-json json-string)))
        (let ((id (getf message :id))
              (method (getf message :method))
              (result (getf message :result))
              (error (getf message :error)))
          (cond
            ;; Response to our request
            (id
             (let ((pending (gethash id (mcp-client-pending-requests client))))
               (when pending
                 (setf (getf pending :response) (or result error))
                 (setf (getf pending :done-p) t))))
            ;; Notification from server
            (method
             (handle-notification client method (getf message :params)))
            ;; Unknown message
            (t
             (log-warn "Unknown MCP message: ~A" message)))))
    (error (e)
      (log-error "Failed to process MCP message: ~A~%  Data: ~A" e json-string)))
  t)

(defun handle-notification (client method params)
  "Handle an incoming notification.

  Args:
    CLIENT: MCP client instance
    METHOD: Notification method
    PARAMS: Notification parameters

  Returns:
    T on success"
  (log-debug "MCP notification: ~A" method)

  ;; Update cached data based on notification
  (case (intern (string-upcase method) :keyword)
    (:notifications/tools/list_changed
     (setf (mcp-client-tools client) (mcp-list-tools client)))
    (:notifications/resources/list_changed
     (setf (mcp-client-resources client) (mcp-list-resources client))))

  ;; Call user-defined handler if any
  (let ((handler (mcp-client-notification-handler client)))
    (when handler
      (funcall handler method params)))

  t)

(defun mcp-on-notification (client handler)
  "Set notification handler for MCP client.

  Args:
    CLIENT: MCP client instance
    HANDLER: Handler function (takes method and params)

  Returns:
    T on success"
  (setf (mcp-client-notification-handler client) handler)
  t)

;;; ============================================================================
;;; Tool Operations
;;; ============================================================================

(defun mcp-list-tools (client)
  "List available tools from MCP server.

  Args:
    CLIENT: MCP client instance

  Returns:
    List of tool definitions"
  (let ((response (mcp-send-request client "tools/list" nil)))
    (when response
      (getf response :tools))))

(defun mcp-call-tool (client tool-name arguments)
  "Call a tool on MCP server.

  Args:
    CLIENT: MCP client instance
    TOOL-NAME: Tool name
    ARGUMENTS: Tool arguments (plist)

  Returns:
    Tool result or NIL"
  (let ((response (mcp-send-request client "tools/call"
                                     `(:name ,tool-name :arguments ,arguments))))
    (when response
      (getf response :content))))

(defun mcp-get-tool-schema (client tool-name)
  "Get schema for a specific tool.

  Args:
    CLIENT: MCP client instance
    TOOL-NAME: Tool name

  Returns:
    Tool schema plist or NIL"
  (let ((tools (mcp-list-tools client)))
    (find tool-name tools :key (lambda (tool) (getf tool :name)) :test #'string=)))

;;; ============================================================================
;;; Resource Operations
;;; ============================================================================

(defun mcp-list-resources (client)
  "List available resources from MCP server.

  Args:
    CLIENT: MCP client instance

  Returns:
    List of resource definitions"
  (let ((response (mcp-send-request client "resources/list" nil)))
    (when response
      (getf response :resources))))

(defun mcp-get-resource (client uri)
  "Get a resource by URI.

  Args:
    CLIENT: MCP client instance
    URI: Resource URI

  Returns:
    Resource content or NIL"
  (let ((response (mcp-send-request client "resources/get"
                                     `(:uri ,uri))))
    (when response
      (getf response :contents))))

;;; ============================================================================
;;; Prompt Operations
;;; ============================================================================

(defun mcp-list-prompts (client)
  "List available prompts from MCP server.

  Args:
    CLIENT: MCP client instance

  Returns:
    List of prompt definitions"
  (let ((response (mcp-send-request client "prompts/list" nil)))
    (when response
      (getf response :prompts))))

(defun mcp-get-prompt (client prompt-name &optional arguments)
  "Get a prompt by name.

  Args:
    CLIENT: MCP client instance
    PROMPT-NAME: Prompt name
    ARGUMENTS: Optional prompt arguments

  Returns:
    Prompt definition or NIL"
  (let ((response (mcp-send-request client "prompts/get"
                                     `(:name ,prompt-name
                                       :arguments ,(or arguments nil)))))
    (when response
      (getf response :messages))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-mcp-system ()
  "Initialize the MCP system.

  Returns:
    T"
  (log-info "MCP system initialized")
  t)
