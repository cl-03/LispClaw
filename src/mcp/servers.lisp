;;; mcp/servers.lisp --- Pre-configured MCP Servers for Lisp-Claw
;;;
;;; This file provides pre-configured MCP server definitions
;;; for common MCP servers like filesystem, database, etc.

(defpackage #:lisp-claw.mcp.servers
  (:nicknames #:lc.mcp.servers)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.mcp.client)
  (:export
   ;; Filesystem server
   #:connect-filesystem-server
   ;; Database server
   #:connect-database-server
   ;; Git server
   #:connect-git-server
   ;; HTTP server
   #:connect-http-server
   ;; Memory server
   #:connect-memory-server
   ;; Time server
   #:connect-time-server
   ;; Generic connection
   #:connect-mcp-server))

(in-package #:lisp-claw.mcp.servers)

;;; ============================================================================
;;; Filesystem Server
;;; ============================================================================

(defun connect-filesystem-server (&key (name "filesystem") root-directory)
  "Connect to a filesystem MCP server.

  Args:
    NAME: Server name
    ROOT-DIRECTORY: Root directory to serve

  Returns:
    MCP client instance or NIL"
  (let* ((args (if root-directory
                   `("--dir" ,root-directory)
                   '()))
         (client (make-mcp-client name "npx" "-y" "@modelcontextprotocol/server-filesystem" args)))
    (when (mcp-connect client)
      (register-mcp-server name client)
      (log-info "Connected to filesystem MCP server: ~A" name)
      client)))

;;; ============================================================================
;;; Database Server
;;; ============================================================================

(defun connect-database-server (&key (name "database") database-url)
  "Connect to a database MCP server.

  Args:
    NAME: Server name
    DATABASE-URL: Database connection URL

  Returns:
    MCP client instance or NIL"
  (unless database-url
    (log-error "Database URL required for MCP database server")
    (return-from connect-database-server nil))

  (let ((client (make-mcp-client name "npx" "-y" "@modelcontextprotocol/server-memory" "--uri" database-url)))
    (when (mcp-connect client)
      (register-mcp-server name client)
      (log-info "Connected to database MCP server: ~A" name)
      client)))

;;; ============================================================================
;;; Git Server
;;; ============================================================================

(defun connect-git-server (&key (name "git") repository-path)
  "Connect to a Git MCP server.

  Args:
    NAME: Server name
    REPOSITORY-PATH: Path to Git repository

  Returns:
    MCP client instance or NIL"
  (let* ((args (if repository-path
                   `("--repo" ,repository-path)
                   '()))
         (client (make-mcp-client name "npx" "-y" "@modelcontextprotocol/server-git" args)))
    (when (mcp-connect client)
      (register-mcp-server name client)
      (log-info "Connected to Git MCP server: ~A" name)
      client)))

;;; ============================================================================
;;; HTTP/REST Server
;;; ============================================================================

(defun connect-http-server (&key (name "http") base-url)
  "Connect to an HTTP MCP server.

  Args:
    NAME: Server name
    BASE-URL: Base URL for HTTP requests

  Returns:
    MCP client instance or NIL"
  (unless base-url
    (log-error "Base URL required for MCP HTTP server")
    (return-from connect-http-server nil))

  (let ((client (make-mcp-client name "npx" "-y" "@modelcontextprotocol/server-fetch" "--url" base-url)))
    (when (mcp-connect client)
      (register-mcp-server name client)
      (log-info "Connected to HTTP MCP server: ~A" name)
      client)))

;;; ============================================================================
;;; Memory Server (SQLite)
;;; ============================================================================

(defun connect-memory-server (&key (name "memory") database-path)
  "Connect to a memory MCP server (SQLite-based).

  Args:
    NAME: Server name
    DATABASE-PATH: Path to SQLite database

  Returns:
    MCP client instance or NIL"
  (let* ((db-path (or database-path
                      (format nil "~A/.lisp-claw/memory.db" (user-homedir-pathname)))))
    (let ((client (make-mcp-client name "python" "-m" "mcp_server_memory" "--db" db-path)))
      (when (mcp-connect client)
        (register-mcp-server name client)
        (log-info "Connected to memory MCP server: ~A" name)
        client))))

;;; ============================================================================
;;; Time Server
;;; ============================================================================

(defun connect-time-server (&key (name "time"))
  "Connect to a time MCP server.

  Args:
    NAME: Server name

  Returns:
    MCP client instance or NIL"
  (let ((client (make-mcp-client name "npx" "-y" "@modelcontextprotocol/server-time")))
    (when (mcp-connect client)
      (register-mcp-server name client)
      (log-info "Connected to time MCP server: ~A" name)
      client)))

;;; ============================================================================
;;; Generic Connection
;;; ============================================================================

(defun connect-mcp-server (name server-cmd &rest server-args)
  "Connect to a generic MCP server.

  Args:
    NAME: Server name
    SERVER-CMD: Server command
    SERVER-ARGS: Server arguments

  Returns:
    MCP client instance or NIL"
  (let ((client (apply #'make-mcp-client name server-cmd server-args)))
    (when (mcp-connect client)
      (register-mcp-server name client)
      (log-info "Connected to MCP server: ~A" name)
      client)))

;;; ============================================================================
;;; Convenience Functions
;;; ============================================================================

(defun call-mcp-tool (server-name tool-name &rest arguments)
  "Call a tool on an MCP server.

  Args:
    SERVER-NAME: Registered server name
    TOOL-NAME: Tool name
    ARGUMENTS: Tool arguments

  Returns:
    Tool result or NIL"
  (let ((server (get-mcp-server server-name)))
    (if server
        (mcp-call-tool server tool-name arguments)
        (progn
          (log-error "MCP server not found: ~A" server-name)
          nil))))

(defun list-mcp-tools (server-name)
  "List tools from an MCP server.

  Args:
    SERVER-NAME: Registered server name

  Returns:
    List of tool definitions"
  (let ((server (get-mcp-server server-name)))
    (if server
        (mcp-list-tools server)
        (progn
          (log-error "MCP server not found: ~A" server-name)
          nil))))

(defun get-mcp-resource (server-name uri)
  "Get a resource from an MCP server.

  Args:
    SERVER-NAME: Registered server name
    URI: Resource URI

  Returns:
    Resource content or NIL"
  (let ((server (get-mcp-server server-name)))
    (if server
        (mcp-get-resource server uri)
        (progn
          (log-error "MCP server not found: ~A" server-name)
          nil))))

;;; ============================================================================
;;; Auto-disconnect on Exit
;;; ============================================================================

(defun disconnect-all-mcp-servers ()
  "Disconnect from all MCP servers.

  Returns:
    T"
  (maphash (lambda (name client)
             (declare (ignore name))
             (mcp-disconnect client))
           *mcp-registry*)
  (log-info "All MCP servers disconnected")
  t)
