;;; web/control-ui.lisp --- Gateway Control Web Interface
;;;
;;; This file provides a web-based control UI for managing the Lisp-Claw gateway.
;;; Includes dashboard, settings, channel management, and monitoring.

(defpackage #:lisp-claw.web.control-ui
  (:nicknames #:lc.web.ui)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:hunchentoot
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.gateway.health
        #:lisp-claw.channels.registry)
  (:export
   #:start-control-ui
   #:stop-control-ui
   :*control-ui-port*
   :*control-ui-acceptor*))

(in-package #:lisp-claw.web.control-ui)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *control-ui-port* 18790
  "Port for the control UI web server.")

(defvar *control-ui-acceptor* nil
  "Control UI acceptor instance.")

(defvar *control-ui-running* nil
  "Whether control UI is running.")

;;; ============================================================================
;;; Server Lifecycle
;;; ============================================================================

(defun start-control-ui (&key (port 18790) (bind "127.0.0.1"))
  "Start the control UI web server.

  Args:
    PORT: Port to bind (default: 18790)
    BIND: Bind address (default: 127.0.0.1)

  Returns:
    T on success"
  (when *control-ui-running*
    (log-warn "Control UI already running")
    (return-from start-control-ui nil))

  (setf *control-ui-port* port)
  (setf *control-ui-acceptor*
        (make-instance 'easy-acceptor
                       :port port
                       :address bind))

  ;; Define routes
  (setf (dispatcher *control-ui-acceptor*)
        (lambda ()
          (dispatch-control-ui-request)))

  (start *control-ui-acceptor*)
  (setf *control-ui-running* t)

  (log-info "Control UI started on http://~A:~A" bind port)
  t)

(defun stop-control-ui ()
  "Stop the control UI web server.

  Returns:
    T on success"
  (when *control-ui-acceptor*
    (stop *control-ui-acceptor*)
    (setf *control-ui-acceptor* nil))
  (setf *control-ui-running* nil)
  (log-info "Control UI stopped")
  t)

;;; ============================================================================
;;; Request Dispatch
;;; ============================================================================

(defun dispatch-control-ui-request ()
  "Dispatch control UI requests to handlers.

  Returns:
    Response body, content-type, and status"
  (let* ((uri (request-uri*))
         (method (request-method*)))

    (cond
      ;; Static assets
      ((string-prefix-p "/static/" uri)
       (handle-static-file uri))

      ;; API endpoints
      ((string-prefix-p "/api/" uri)
       (handle-api-request uri method))

      ;; Main page
      ((string= uri "/")
       (handle-control-ui-page))

      ;; 404
      (t
       (set-status 404)
       "Not Found"))))

(defun handle-static-file (uri)
  "Serve static files.

  Args:
    URI: Request URI

  Returns:
    File content"
  (let* ((path (subseq uri (length "/static/")))
         (content-type (cond
                         ((string-suffix-p path ".css") "text/css")
                         ((string-suffix-p path ".js") "application/javascript")
                         ((string-suffix-p path ".html") "text/html")
                         (t "text/plain"))))
    (set-content-type content-type)
    ;; In a real implementation, would read from static/ directory
    (format nil "/* Static file: ~A */" path)))

;;; ============================================================================
;;; API Handlers
;;; ============================================================================

(defun handle-api-request (uri method)
  "Handle API requests.

  Args:
    URI: Request URI
    METHOD: HTTP method

  Returns:
    JSON response"
  (set-content-type "application/json")

  (let ((response (cond
                    ((string= uri "/api/health")
                     (api-get-health))
                    ((string= uri "/api/status")
                     (api-get-status))
                    ((string= uri "/api/channels")
                     (case method
                       (:get (api-get-channels))
                       (:post (api-add-channel))
                       (otherwise (error "Method not allowed"))))
                    ((string= uri "/api/channels/delete")
                     (api-delete-channel))
                    ((string= uri "/api/settings")
                     (case method
                       (:get (api-get-settings))
                       (:post (api-update-settings))))
                    ((string= uri "/api/logs")
                     (api-get-logs))
                    (t
                     (set-status 404)
                     `((:error . "Not found"))))))

    (stringify-json response)))

(defun api-get-health ()
  "Get health status.

  Returns:
    Health data"
  (get-health-status))

(defun api-get-status ()
  "Get gateway status.

  Returns:
    Status data"
  `((:running . t)
    (:uptime . ,(get-universal-time))
    (:clients . 0)
    (:channels . ,(hash-table-count (gethash 'channels (get-health-status))))
    (:version . "0.1.0")))

(defun api-get-channels ()
  "Get list of configured channels.

  Returns:
    Channel list"
  `((:channels . [])))

(defun api-add-channel ()
  "Add a new channel.

  Returns:
    Result"
  `((:status . "ok")))

(defun api-delete-channel ()
  "Delete a channel.

  Returns:
    Result"
  `((:status . "ok")))

(defun api-get-settings ()
  "Get gateway settings.

  Returns:
    Settings"
  `((:port . 18789)
    (:bind . "0.0.0.0")
    (:auth-enabled . t)))

(defun api-update-settings ()
  "Update gateway settings.

  Returns:
    Result"
  `((:status . "ok")))

(defun api-get-logs ()
  "Get recent logs.

  Returns:
    Log entries"
  `((:logs . [])))

;;; ============================================================================
;;; HTML Pages
;;; ============================================================================

(defun handle-control-ui-page ()
  "Render the main control UI page.

  Returns:
    HTML content"
  (set-content-type "text/html")
  (generate-control-ui-html))

(defun generate-control-ui-html ()
  "Generate the control UI HTML.

  Returns:
    HTML string"
  #+(or)
  (with-output-to-string (s)
    (format s "<!DOCTYPE html>
<html lang=\"en\">
<head>
    <meta charset=\"UTF-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
    <title>Lisp-Claw Control Panel</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #1a1a2e; color: #eee; }
        .header { background: #16213e; padding: 1rem 2rem; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #0f3460; }
        .header h1 { color: #e94560; }
        .status-bar { display: flex; gap: 1rem; padding: 1rem 2rem; background: #16213e; margin-bottom: 1rem; }
        .status-item { background: #0f3460; padding: 0.5rem 1rem; border-radius: 4px; }
        .status-item.online { border-left: 3px solid #00ff88; }
        .container { display: grid; grid-template-columns: 250px 1fr; gap: 1rem; padding: 1rem 2rem; }
        .sidebar { background: #16213e; border-radius: 8px; padding: 1rem; }
        .sidebar h3 { color: #e94560; margin-bottom: 1rem; }
        .sidebar ul { list-style: none; }
        .sidebar li { padding: 0.5rem; cursor: pointer; border-radius: 4px; margin-bottom: 0.5rem; }
        .sidebar li:hover { background: #0f3460; }
        .sidebar li.active { background: #e94560; }
        .main-content { background: #16213e; border-radius: 8px; padding: 1.5rem; }
        .card { background: #0f3460; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }
        .card h4 { color: #e94560; margin-bottom: 0.5rem; }
        .btn { background: #e94560; color: white; border: none; padding: 0.5rem 1rem; border-radius: 4px; cursor: pointer; }
        .btn:hover { background: #ff6b6b; }
    </style>
</head>
<body>
    <div class=\"header\">
        <h1>🐱 Lisp-Claw Control Panel</h1>
        <div>
            <span class=\"btn\" onclick=\"location.reload()\">Refresh</span>
        </div>
    </div>
    <div class=\"status-bar\">
        <div class=\"status-item online\">Gateway: Online</div>
        <div class=\"status-item\">Port: 18789</div>
        <div class=\"status-item\">Clients: 0</div>
        <div class=\"status-item\">Channels: 0</div>
    </div>
    <div class=\"container\">
        <div class=\"sidebar\">
            <h3>Navigation</h3>
            <ul>
                <li class=\"active\">Dashboard</li>
                <li>Channels</li>
                <li>Agents</li>
                <li>Settings</li>
                <li>Logs</li>
            </ul>
        </div>
        <div class=\"main-content\">
            <div class=\"card\">
                <h4>Gateway Status</h4>
                <p>The gateway is running and healthy.</p>
            </div>
            <div class=\"card\">
                <h4>Quick Actions</h4>
                <button class=\"btn\">Restart Gateway</button>
                <button class=\"btn\">Clear Logs</button>
            </div>
        </div>
    </div>
</body>
</html>"))
  ;; Return placeholder
  "<!DOCTYPE html><html><head><title>Lisp-Claw Control Panel</title></head><body><h1>Lisp-Claw Control Panel</h1><p>Coming soon...</p></body></html>")

;;; ============================================================================
;;; WebSocket Integration
;;; ============================================================================

(defun broadcast-ui-event (event payload)
  "Broadcast an event to connected UI clients.

  Args:
    EVENT: Event type
    PAYLOAD: Event data

  Returns:
    T on success"
  (declare (ignore event payload))
  ;; Would use WebSocket to push updates
  t)

(defun ui-notify-channel-added (channel-info)
  "Notify UI about a new channel.

  Args:
    CHANNEL-INFO: Channel information

  Returns:
    T on success"
  (broadcast-ui-event "channel.added" channel-info))

(defun ui-notify-channel-removed (channel-id)
  "Notify UI about a removed channel.

  Args:
    CHANNEL-ID: Channel ID

  Returns:
    T on success"
  (broadcast-ui-event "channel.removed" (list :id channel-id)))

(defun ui-notify-status-change (status)
  "Notify UI about status change.

  Args:
    STATUS: New status

  Returns:
    T on success"
  (broadcast-ui-event "status.changed" status))
