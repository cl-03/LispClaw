;;; web/webchat.lisp --- Web Chat Interface for Lisp-Claw
;;;
;;; This file provides a web-based chat interface for interacting with
;;; the Lisp-Claw AI assistant. Supports WebSocket for real-time messaging.

(defpackage #:lisp-claw.web.webchat
  (:nicknames #:lc.web.chat)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:hunchentoot
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.gateway.protocol)
  (:export
   #:start-webchat
   #:stop-webchat
   #:*webchat-port*
   #:*webchat-acceptor*
   #:*webchat-sessions*))

(in-package #:lisp-claw.web.webchat)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *webchat-port* 18791
  "Port for the webchat web server.")

(defvar *webchat-acceptor* nil
  "WebChat acceptor instance.")

(defvar *webchat-running* nil
  "Whether webchat is running.")

(defvar *webchat-sessions* (make-hash-table :test 'equal)
  "Hash table of chat sessions: session-id -> session data.")

(defvar *webchat-clients* (make-hash-table :test 'equal)
  "Hash table of WebSocket clients: client-id -> stream.")

;;; ============================================================================
;;; Server Lifecycle
;;; ============================================================================

(defun start-webchat (&key (port 18791) (bind "127.0.0.1"))
  "Start the webchat web server.

  Args:
    PORT: Port to bind (default: 18791)
    BIND: Bind address (default: 127.0.0.1)

  Returns:
    T on success"
  (when *webchat-running*
    (log-warn "WebChat already running")
    (return-from start-webchat nil))

  (setf *webchat-port* port)
  (setf *webchat-acceptor*
        (make-instance 'easy-acceptor
                       :port port
                       :address bind))

  ;; Define routes
  (setf (dispatcher *webchat-acceptor*)
        (lambda ()
          (dispatch-webchat-request)))

  (start *webchat-acceptor*)
  (setf *webchat-running* t)

  (log-info "WebChat started on http://~A:~A" bind port)
  t)

(defun stop-webchat ()
  "Stop the webchat web server.

  Returns:
    T on success"
  (when *webchat-acceptor*
    (stop *webchat-acceptor*)
    (setf *webchat-acceptor* nil))

  ;; Close all client connections
  (maphash (lambda (client-id stream)
             (declare (ignore client-id))
             (ignore-errors (close stream)))
           *webchat-clients*)
  (clrhash *webchat-clients*)
  (clrhash *webchat-sessions*)

  (setf *webchat-running* nil)
  (log-info "WebChat stopped")
  t)

;;; ============================================================================
;;; Request Dispatch
;;; ============================================================================

(defun dispatch-webchat-request ()
  "Dispatch webchat requests to handlers.

  Returns:
    Response body, content-type, and status"
  (let* ((uri (request-uri*))
         (method (request-method*)))

    (cond
      ;; Static assets
      ((string-prefix-p "/static/" uri)
       (handle-webchat-static uri))

      ;; WebSocket upgrade
      ((string= uri "/ws")
       (handle-webchat-websocket))

      ;; API endpoints
      ((string-prefix-p "/api/" uri)
       (handle-webchat-api uri method))

      ;; Main chat page
      ((string= uri "/")
       (handle-webchat-page))

      ;; 404
      (t
       (set-status 404)
       "Not Found"))))

(defun handle-webchat-static (uri)
  "Serve static files for webchat.

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
    (format nil "/* WebChat static: ~A */" path)))

;;; ============================================================================
;;; Chat Page
;;; ============================================================================

(defun handle-webchat-page ()
  "Render the webchat page.

  Returns:
    HTML content"
  (set-content-type "text/html")
  (generate-webchat-html))

(defun generate-webchat-html ()
  "Generate the webchat HTML page.

  Returns:
    HTML string"
  #+(or)
  (with-output-to-string (s)
    (format s "<!DOCTYPE html>
<html lang=\"en\">
<head>
    <meta charset=\"UTF-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
    <title>Lisp-Claw Chat</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f0f23; color: #eee; height: 100vh; display: flex; flex-direction: column; }
        .header { background: #1a1a2e; padding: 1rem 2rem; border-bottom: 1px solid #333; display: flex; justify-content: space-between; align-items: center; }
        .header h1 { color: #e94560; font-size: 1.5rem; }
        .chat-container { flex: 1; display: flex; overflow: hidden; }
        .sidebar { width: 250px; background: #1a1a2e; border-right: 1px solid #333; display: flex; flex-direction: column; }
        .sidebar-header { padding: 1rem; border-bottom: 1px solid #333; font-weight: bold; }
        .chat-list { flex: 1; overflow-y: auto; }
        .chat-item { padding: 1rem; cursor: pointer; border-bottom: 1px solid #222; }
        .chat-item:hover { background: #16213e; }
        .chat-item.active { background: #e94560; }
        .main-chat { flex: 1; display: flex; flex-direction: column; }
        .messages { flex: 1; overflow-y: auto; padding: 1rem; }
        .message { margin-bottom: 1rem; display: flex; gap: 0.5rem; }
        .message.user { justify-content: flex-end; }
        .message-content { background: #16213e; padding: 0.75rem 1rem; border-radius: 8px; max-width: 70%%; }
        .message.user .message-content { background: #e94560; }
        .message-avatar { width: 36px; height: 36px; border-radius: 50%%; background: #333; display: flex; align-items: center; justify-content: center; }
        .input-area { padding: 1rem; background: #1a1a2e; border-top: 1px solid #333; display: flex; gap: 0.5rem; }
        .input-area input { flex: 1; background: #0f0f23; border: 1px solid #333; border-radius: 8px; padding: 0.75rem 1rem; color: #eee; font-size: 1rem; }
        .input-area input:focus { outline: none; border-color: #e94560; }
        .input-area button { background: #e94560; color: white; border: none; padding: 0.75rem 1.5rem; border-radius: 8px; cursor: pointer; font-size: 1rem; }
        .input-area button:hover { background: #ff6b6b; }
        .input-area button:disabled { background: #333; cursor: not-allowed; }
        .typing-indicator { color: #666; font-size: 0.875rem; padding: 0.5rem 1rem; }
    </style>
</head>
<body>
    <div class=\"header\">
        <h1>🐱 Lisp-Claw Chat</h1>
        <div id=\"connection-status\" style=\"color: #00ff88;\">Connected</div>
    </div>
    <div class=\"chat-container\">
        <div class=\"sidebar\">
            <div class=\"sidebar-header\">Conversations</div>
            <div class=\"chat-list\" id=\"chat-list\"></div>
        </div>
        <div class=\"main-chat\">
            <div class=\"messages\" id=\"messages\"></div>
            <div class=\"typing-indicator\" id=\"typing\"></div>
            <div class=\"input-area\">
                <input type=\"text\" id=\"message-input\" placeholder=\"Type a message...\" autocomplete=\"off\">
                <button id=\"send-btn\" onclick=\"sendMessage()\">Send</button>
            </div>
        </div>
    </div>
    <script>
        // WebSocket connection
        const ws = new WebSocket('ws://' + window.location.host + '/ws');
        const messagesEl = document.getElementById('messages');
        const inputEl = document.getElementById('message-input');
        const sendBtn = document.getElementById('send-btn');
        const typingEl = document.getElementById('typing');

        ws.onopen = () => {
            document.getElementById('connection-status').textContent = 'Connected';
            document.getElementById('connection-status').style.color = '#00ff88';
        };

        ws.onclose = () => {
            document.getElementById('connection-status').textContent = 'Disconnected';
            document.getElementById('connection-status').style.color = '#ff4444';
        };

        ws.onmessage = (event) => {
            const data = JSON.parse(event.data);
            if (data.type === 'message') {
                addMessage(data.content, data.role === 'user' ? 'user' : 'assistant');
            }
        };

        function addMessage(content, role) {
            const msgDiv = document.createElement('div');
            msgDiv.className = 'message' + (role === 'user' ? ' user' : '');
            msgDiv.innerHTML = role === 'user'
                ? '<div class=\"message-content\">' + escapeHtml(content) + '</div><div class=\"message-avatar\">👤</div>'
                : '<div class=\"message-avatar\">🐱</div><div class=\"message-content\">' + escapeHtml(content) + '</div>';
            messagesEl.appendChild(msgDiv);
            messagesEl.scrollTop = messagesEl.scrollHeight;
        }

        function sendMessage() {
            const text = inputEl.value.trim();
            if (!text) return;
            ws.send(JSON.stringify({ type: 'message', content: text }));
            addMessage(text, 'user');
            inputEl.value = '';
        }

        inputEl.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') sendMessage();
        });

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }
    </script>
</body>
</html>"))
  ;; Return placeholder
  "<!DOCTYPE html><html><head><title>Lisp-Claw Chat</title></head><body><h1>Lisp-Claw Chat</h1><p>Chat interface coming soon...</p></body></html>")

;;; ============================================================================
;;; WebSocket Handling
;;; ============================================================================

(defun handle-webchat-websocket ()
  "Handle WebSocket connection for webchat.

  Returns:
    WebSocket response"
  (let* ((headers (headers-in*))
         (key (gethash "sec-websocket-key" headers)))

    (unless key
      (set-status 400)
      (return-from handle-webchat-websocket "Bad Request")))

  ;; Generate accept key
  (let* ((accept-key (compute-websocket-accept-key key))
         (response-headers `(("Upgrade" . "websocket")
                             ("Connection" . "Upgrade")
                             ("Sec-WebSocket-Accept" . ,accept-key))))

    ;; Send handshake
    (send-websocket-handshake response-headers)

    ;; Handle messages
    (let ((client-id (generate-client-id)))
      (register-webchat-client client-id)
      (handle-webchat-messages client-id)
      (unregister-webchat-client client-id))))

(defun compute-websocket-accept-key (client-key)
  "Compute WebSocket accept key.

  Args:
    CLIENT-KEY: Sec-WebSocket-Key from client

  Returns:
    Accept key string"
  (let* ((magic-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
         (concatenated (concatenate 'string client-key magic-guid))
         (sha1-hash (ironclad:digest-sequence :sha1
                     (babel:string-to-octets concatenated)))
         (base64-encoded (babel:octets-to-string sha1-hash :encoding :base64)))
    base64-encoded))

(defun send-websocket-handshake (headers)
  "Send WebSocket handshake response.

  Args:
    HEADERS: Response headers alist"
  (let ((response "HTTP/1.1 101 Switching Protocols~%~{~A: ~A~%~}~%"))
    (format t response
            (loop for (key . value) in headers
                  appending (list key value)))
    (finish-output t)))

(defun handle-webchat-messages (client-id)
  "Handle WebSocket messages from a chat client.

  Args:
    CLIENT-ID: Client identifier"
  (let ((stream *standard-output*))
    (unwind-protect
         (loop while (and *webchat-running* (open-stream-p stream)) do
           (handler-case
               (let* ((frame (read-websocket-frame stream)))
                 (when frame
                   (process-webchat-message client-id frame)))
             (end-of-file ()
               (log-info "WebChat client ~A disconnected" client-id)
               (return))
             (error (e)
               (log-error "WebChat error: ~A" e)
               (return))))
      (ignore-errors (close stream)))))

(defun read-websocket-frame (stream)
  "Read a WebSocket frame.

  Args:
    STREAM: Input stream

  Returns:
    Frame data or NIL"
  (let* ((byte1 (read-byte stream))
         (byte2 (read-byte stream))
         (opcode (logand #b1111 byte1))
         (mask-p (logbitp 7 byte2))
         (payload-len (logand #b1111111 byte2))
         (mask-key (if mask-p (read-sequence 4 stream) nil))
         (actual-len (cond
                       ((= payload-len 126)
                        (let ((b1 (read-byte stream))
                              (b2 (read-byte stream)))
                          (+ (* b1 256) b2)))
                       ((= payload-len 127)
                        (let ((len 0))
                          (dotimes (i 8)
                            (setf len (+ (* len 256) (read-byte stream))))
                          len))
                       (t payload-len)))
         (data (read-sequence actual-len stream))))

    ;; Unmask
    (when mask-p
      (dotimes (i (length data))
        (setf (aref data i) (logxor (aref data i) (aref mask-key (mod i 4))))))

    (case opcode
      (#x1 ; Text
       (babel:octets-to-string data :encoding :utf-8))
      (#x2 ; Binary
       data)
      (#x8 ; Close
       nil)
      (#x9 ; Ping
       (send-websocket-pong stream data)
       nil)
      (#xA ; Pong
       nil)
      (otherwise nil))))

(defun send-websocket-pong (stream data)
  "Send WebSocket pong.

  Args:
    STREAM: Output stream
    DATA: Ping data"
  (write-byte #b10001010 stream)
  (write-byte (length data) stream)
  (write-sequence data stream)
  (finish-output stream))

(defun process-webchat-message (client-id message)
  "Process a webchat message.

  Args:
    CLIENT-ID: Client ID
    MESSAGE: Message string"
  (when (stringp message)
    (handler-case
        (let* ((json (parse-json message))
               (type (gethash "type" json))
               (content (gethash "content" json)))

          (cond
            ((string= type "message")
             (handle-chat-message client-id content))
            ((string= type "typing")
             (handle-typing-indicator client-id))
            (t
             (log-warn "Unknown webchat message type: ~A" type))))
      (error (e)
        (log-error "WebChat message error: ~A" e)))))

(defun handle-chat-message (client-id content)
  "Handle a chat message.

  Args:
    CLIENT-ID: Client ID
    CONTENT: Message content

  Returns:
    T on success"
  (log-info "WebChat message from ~A: ~A" client-id content)

  ;; Get or create session
  (let ((session (gethash client-id *webchat-sessions*)))
    (unless session
      (setf session (list :messages nil
                          :created-at (get-universal-time)))
      (setf (gethash client-id *webchat-sessions*) session))

    ;; Add user message to session
    (push (list :role :user
                :content content
                :timestamp (get-universal-time))
          (getf session :messages))

    ;; Send to agent for processing
    ;; (let ((response (agent-chat content)))
    ;;   (send-to-client client-id response)
    ;;   (push response (getf session :messages)))
    )

  t)

(defun handle-typing-indicator (client-id)
  "Handle typing indicator from client.

  Args:
    CLIENT-ID: Client ID

  Returns:
    T on success"
  (declare (ignore client-id))
  ;; Could broadcast typing status to other clients
  t)

;;; ============================================================================
;;; Client Management
;;; ============================================================================

(defun generate-client-id ()
  "Generate a unique client ID.

  Returns:
    Client ID string"
  (format nil "webchat-~A-~A"
          (get-universal-time)
          (uuid:make-uuid :random)))

(defun register-webchat-client (client-id)
  "Register a webchat client.

  Args:
    CLIENT-ID: Client ID

  Returns:
    T on success"
  (setf (gethash client-id *webchat-clients*) *standard-output*)
  (setf (gethash client-id *webchat-sessions*)
        (list :messages nil
              :created-at (get-universal-time)
              :client-id client-id))
  (log-info "WebChat client registered: ~A" client-id)
  t)

(defun unregister-webchat-client (client-id)
  "Unregister a webchat client.

  Args:
    CLIENT-ID: Client ID

  Returns:
    T on success"
  (remhash client-id *webchat-clients*)
  (remhash client-id *webchat-sessions*)
  (log-info "WebChat client unregistered: ~A" client-id)
  t)

(defun send-to-client (client-id message)
  "Send a message to a client.

  Args:
    CLIENT-ID: Client ID
    MESSAGE: Message string

  Returns:
    T on success"
  (let ((stream (gethash client-id *webchat-clients*)))
    (when (and stream (open-stream-p stream))
      (let* ((data (babel:string-to-octets message :encoding :utf-8))
             (len (length data)))
        (write-byte #b10000001 stream)
        (cond
          ((< len 126)
           (write-byte len stream))
          ((< len 65536)
           (write-byte 126 stream)
           (write-byte (ash len -8) stream)
           (write-byte (logand len #xFF) stream))
          (t
           (write-byte 127 stream)
           (dotimes (i 8)
             (write-byte (ldb (byte 8 (* 56 (* 7 i))) len) stream))))
        (write-sequence data stream)
        (finish-output stream)
        t))))

(defun broadcast-to-chat-clients (message)
  "Broadcast to all chat clients.

  Args:
    MESSAGE: Message string

  Returns:
    Number of clients notified"
  (let ((count 0))
    (maphash (lambda (client-id stream)
               (declare (ignore stream))
               (when (send-to-client client-id message)
                 (incf count)))
             *webchat-clients*)
    count))

;;; ============================================================================
;;; API Handlers
;;; ============================================================================

(defun handle-webchat-api (uri method)
  "Handle webchat API requests.

  Args:
    URI: Request URI
    METHOD: HTTP method

  Returns:
    JSON response"
  (set-content-type "application/json")

  (let ((response (cond
                    ((string= uri "/api/sessions")
                     (case method
                       (:get (api-get-sessions))
                       (:post (api-create-session))))
                    ((string= uri "/api/message")
                     (case method
                       (:post (api-send-message))))
                    (t
                     (set-status 404)
                     `((:error . "Not found"))))))

    (stringify-json response)))

(defun api-get-sessions ()
  "Get chat sessions.

  Returns:
    Session list"
  `((:sessions . [])))

(defun api-create-session ()
  "Create a new chat session.

  Returns:
    Session data"
  (let ((session-id (generate-client-id)))
    `((:status . "ok")
      (:sessionId . ,session-id))))

(defun api-send-message ()
  "Send a chat message.

  Returns:
    Response"
  `((:status . "ok")))
