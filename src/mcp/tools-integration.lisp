;;; mcp/tools-integration.lisp --- MCP Tools Integration with Agent
;;;
;;; This file integrates MCP tools with the agent tool system,
;;; allowing AI to discover and call MCP tools dynamically.

(defpackage #:lisp-claw.mcp.tools
  (:nicknames #:lc.mcp.tools)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.agent.core
        #:lisp-claw.agent.models
        #:lisp-claw.mcp.client
        #:lisp-claw.mcp.servers)
  (:export
   ;; Tool registration
   #:register-mcp-tools
   #:unregister-mcp-tools
   #:sync-all-mcp-tools
   ;; Tool execution
   #:execute-mcp-tool
   ;; Tool discovery
   #:list-all-mcp-tools
   #:get-mcp-tool-definition
   ;; Configuration
   #:*auto-sync-mcp-tools*
   #:*mcp-tool-prefix*))

(in-package #:lisp-claw.mcp.tools)

;;; ============================================================================
;;; Configuration
;;; ============================================================================

(defvar *auto-sync-mcp-tools* t
  "Automatically sync MCP tools when servers connect.")

(defvar *mcp-tool-prefix* "mcp_"
  "Prefix for MCP tool names to avoid conflicts.")

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defun register-mcp-tools (server-name &key tool-prefix)
  "Register tools from an MCP server with the agent tool system.

  Args:
    SERVER-NAME: Registered MCP server name
    TOOL-PREFIX: Optional prefix for tool names

  Returns:
    Number of tools registered"
  (let* ((server (get-mcp-server server-name))
         (prefix (or tool-prefix *mcp-tool-prefix*))
         (count 0))
    (unless server
      (log-error "MCP server not found: ~A" server-name)
      (return-from register-mcp-tools 0))

    (let ((tools (mcp-list-tools server)))
      (dolist (tool tools)
        (let* ((name (getf tool :name))
               (description (getf tool :description))
               (input-schema (getf tool :inputSchema))
               (tool-name (intern (string-upcase (concatenate 'string prefix name)) :keyword)))
          ;; Create tool wrapper
          (register-tool
           name
           description
           (lambda (&rest args)
             (execute-mcp-tool server-name name args))
           :parameters input-schema)
          (incf count)
          (log-debug "Registered MCP tool: ~A as ~A" name tool-name)))
      (log-info "Registered ~A tools from MCP server: ~A" count server-name)
      count)))

(defun unregister-mcp-tools (server-name)
  "Unregister tools from an MCP server.

  Args:
    SERVER-NAME: Registered MCP server name

  Returns:
    Number of tools unregistered"
  (let* ((server (get-mcp-server server-name))
         (count 0))
    (unless server
      (return-from unregister-mcp-tools 0))

    (let ((tools (mcp-list-tools server)))
      (dolist (tool tools)
        (let ((name (getf tool :name)))
          (unregister-tool name)
          (incf count)))
      (log-info "Unregistered ~A tools from MCP server: ~A" count server-name)
      count)))

(defun sync-all-mcp-tools ()
  "Sync tools from all connected MCP servers.

  Returns:
    Total number of tools synced"
  (let ((total 0))
    (maphash (lambda (name server)
               (declare (ignore server))
               (incf total (register-mcp-tools name)))
             *mcp-registry*)
    (log-info "Synced ~A total MCP tools" total)
    total))

;;; ============================================================================
;;; Tool Execution
;;; ============================================================================

(defun execute-mcp-tool (server-name tool-name arguments)
  "Execute an MCP tool.

  Args:
    SERVER-NAME: MCP server name
    TOOL-NAME: Tool name
    ARGUMENTS: Tool arguments (plist)

  Returns:
    Tool result"
  (let ((server (get-mcp-server server-name)))
    (unless server
      (return-from execute-mcp-tool
        (list :success nil :error (format nil "MCP server not found: ~A" server-name))))

    (handler-case
        (let ((result (apply #'mcp-call-tool server tool-name arguments)))
          (log-info "MCP tool executed: ~A/~A" server-name tool-name)
          (list :success t :result result))
      (error (e)
        (log-error "MCP tool execution failed: ~A/~A - ~A" server-name tool-name e)
        (list :success nil :error (format nil "~A" e))))))

;;; ============================================================================
;;; Tool Discovery
;;; ============================================================================

(defun list-all-mcp-tools ()
  "List all available MCP tools.

  Returns:
    List of tool definitions with server info"
  (let ((all-tools nil))
    (maphash (lambda (name server)
               (let ((tools (mcp-list-tools server)))
                 (dolist (tool tools)
                   (push (list :server name
                               :name (getf tool :name)
                               :description (getf tool :description)
                               :schema (getf tool :inputSchema))
                         all-tools))))
             *mcp-registry*)
    (nreverse all-tools)))

(defun get-mcp-tool-definition (server-name tool-name)
  "Get definition of a specific MCP tool.

  Args:
    SERVER-NAME: MCP server name
    TOOL-NAME: Tool name

  Returns:
    Tool definition plist or NIL"
  (let ((server (get-mcp-server server-name)))
    (when server
      (let ((tools (mcp-list-tools server)))
        (find tool-name tools :key (lambda (tool) (getf tool :name)) :test #'string=)))))

;;; ============================================================================
;;; Auto-sync Hook
;;; ============================================================================

(defun setup-mcp-auto-sync ()
  "Setup auto-sync for MCP tools.

  Returns:
    T"
  (when *auto-sync-mcp-tools*
    ;; Register notification handler for all servers
    (maphash (lambda (name server)
               (mcp-on-notification server
                                    (lambda (method params)
                                      (declare (ignore params))
                                      (when (string= method "notifications/tools/list_changed")
                                        (log-info "MCP tools changed for server: ~A" name)
                                        (unregister-mcp-tools name)
                                        (register-mcp-tools name)))))
             *mcp-registry*)
    (log-info "MCP auto-sync enabled")
    t))

;;; ============================================================================
;;; Agent Integration - Tool Discovery for AI
;;; ============================================================================

(defun get-mcp-tools-for-agent ()
  "Get MCP tools formatted for agent system.

  Returns:
    List of tool definitions suitable for AI consumption"
  (mapcar (lambda (tool-info)
            (list :name (getf tool-info :name)
                  :description (getf tool-info :description)
                  :server (getf tool-info :server)
                  :parameters (getf tool-info :schema)))
          (list-all-mcp-tools)))

(defun describe-mcp-capabilities ()
  "Describe MCP capabilities for AI context.

  Returns:
    Description string"
  (let ((tools (list-all-mcp-tools))
        (servers (list-mcp-servers)))
    (if (null tools)
        "No MCP servers connected."
        (format nil "Connected to ~A MCP servers: ~{~A~^, ~}. Available tools: ~{~A~^, ~}."
                (length servers)
                servers
                (mapcar (lambda (tool) (getf tool :name)) tools)))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-mcp-tools-integration ()
  "Initialize MCP tools integration.

  Returns:
    T"
  (setup-mcp-auto-sync)
  (log-info "MCP tools integration initialized")
  t)
