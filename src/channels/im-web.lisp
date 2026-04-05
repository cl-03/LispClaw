;;; im-web.lisp --- Instant Messaging Web Interface for Lisp-Claw
;;;
;;; This file provides the web interface for the instant messaging app.

(defpackage #:lisp-claw.im.web
  (:nicknames #:lc.im.web)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:hunchentoot)
  (:export
   #:start-im-web
   #:stop-im-web
   #:register-im-web-routes))

(in-package #:lisp-claw.im.web)

;;; ============================================================================
;;; Web Routes
;;; ============================================================================

(defun register-im-web-routes ()
  "Register IM web interface routes."

  ;; Main IM app page
  (hunchentoot:define-easy-handler (im-app :uri "/im") ()
    (setf (hunchentoot:content-type*) "text/html")
    (render-im-app-page))

  ;; IM static resources
  (hunchentoot:define-easy-handler (im-static :uri "/im/static/") ()
    (serve-im-static))

  ;; IM API endpoints
  (hunchentoot:define-easy-handler (im-api-login :uri "/api/im/login") ()
    (setf (hunchentoot:content-type*) "application/json")
    (handle-im-login))

  (hunchentoot:define-easy-handler (im-api-send :uri "/api/im/send") ()
    (setf (hunchentoot:content-type*) "application/json")
    (handle-im-send))

  (hunchentoot:define-easy-handler (im-api-messages :uri "/api/im/messages") ()
    (setf (hunchentoot:content-type*) "application/json")
    (handle-im-messages))

  (hunchentoot:define-easy-handler (im-api-users :uri "/api/im/users") ()
    (setf (hunchentoot:content-type*) "application/json")
    (handle-im-users))

  (hunchentoot:define-easy-handler (im-api-groups :uri "/api/im/groups") ()
    (setf (hunchentoot:content-type*) "application/json")
    (handle-im-groups))

  (log-info "IM web routes registered"))

;;; ============================================================================
;;; HTML Page Renderer
;;; ============================================================================

(defun render-im-app-page ()
  "Render the IM application HTML page."
  (with-output-to-string (s)
    (format s "~
<!DOCTYPE html>
<html lang=\"en\">
<head>
    <meta charset=\"UTF-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
    <title>Lisp-Claw IM - Instant Messaging</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #1a1a2e;
            color: #eee;
            height: 100vh;
            display: flex;
        }
        .sidebar {
            width: 280px;
            background: #16213e;
            border-right: 1px solid #0f3460;
            display: flex;
            flex-direction: column;
        }
        .sidebar-header {
            padding: 20px;
            background: #0f3460;
            text-align: center;
        }
        .sidebar-header h2 { color: #e94560; }
        .search-box {
            padding: 10px;
            border-bottom: 1px solid #0f3460;
        }
        .search-box input {
            width: 100%;
            padding: 10px;
            border: none;
            border-radius: 5px;
            background: #1a1a2e;
            color: #eee;
        }
        .conversation-list {
            flex: 1;
            overflow-y: auto;
        }
        .conversation-item {
            padding: 15px;
            border-bottom: 1px solid #0f3460;
            cursor: pointer;
            transition: background 0.2s;
        }
        .conversation-item:hover { background: #0f3460; }
        .conversation-item.active { background: #0f3460; }
        .conversation-name { font-weight: bold; margin-bottom: 5px; }
        .conversation-preview { color: #888; font-size: 0.9em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .main-content {
            flex: 1;
            display: flex;
            flex-direction: column;
        }
        .chat-header {
            padding: 20px;
            background: #16213e;
            border-bottom: 1px solid #0f3460;
        }
        .chat-messages {
            flex: 1;
            overflow-y: auto;
            padding: 20px;
        }
        .message {
            margin-bottom: 15px;
            display: flex;
            align-items: flex-start;
        }
        .message.sent { flex-direction: row-reverse; }
        .message-avatar {
            width: 40px;
            height: 40px;
            border-radius: 50%;
            background: #e94560;
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: bold;
        }
        .message-content {
            max-width: 60%;
            margin: 0 10px;
        }
        .message-bubble {
            background: #0f3460;
            padding: 12px 15px;
            border-radius: 15px;
            word-wrap: break-word;
        }
        .message.sent .message-bubble { background: #e94560; }
        .message-meta {
            font-size: 0.8em;
            color: #888;
            margin-top: 5px;
        }
        .message-input-container {
            padding: 20px;
            background: #16213e;
            border-top: 1px solid #0f3460;
        }
        .message-input-wrapper {
            display: flex;
            gap: 10px;
        }
        .message-input {
            flex: 1;
            padding: 15px;
            border: none;
            border-radius: 25px;
            background: #1a1a2e;
            color: #eee;
            font-size: 1em;
        }
        .message-input:focus { outline: 2px solid #e94560; }
        .send-button {
            padding: 15px 30px;
            background: #e94560;
            border: none;
            border-radius: 25px;
            color: #fff;
            cursor: pointer;
            font-weight: bold;
            transition: background 0.2s;
        }
        .send-button:hover { background: #c43d52; }
        .login-container {
            display: none;
            position: fixed;
            top: 0; left: 0;
            width: 100%; height: 100%;
            background: rgba(0,0,0,0.8);
            justify-content: center;
            align-items: center;
            z-index: 1000;
        }
        .login-box {
            background: #16213e;
            padding: 40px;
            border-radius: 10px;
            width: 400px;
        }
        .login-box h2 { text-align: center; color: #e94560; margin-bottom: 30px; }
        .form-group { margin-bottom: 20px; }
        .form-group label { display: block; margin-bottom: 5px; }
        .form-group input {
            width: 100%;
            padding: 12px;
            border: 1px solid #0f3460;
            border-radius: 5px;
            background: #1a1a2e;
            color: #eee;
        }
        .login-button {
            width: 100%;
            padding: 15px;
            background: #e94560;
            border: none;
            border-radius: 5px;
            color: #fff;
            cursor: pointer;
            font-size: 1.1em;
            font-weight: bold;
        }
        .online-indicator {
            width: 10px;
            height: 10px;
            background: #4caf50;
            border-radius: 50%;
            display: inline-block;
            margin-right: 5px;
        }
        .offline .online-indicator { background: #888; }
        .new-message-indicator {
            background: #e94560;
            color: #fff;
            padding: 2px 8px;
            border-radius: 10px;
            font-size: 0.8em;
            float: right;
        }
    </style>
</head>
<body>
    <div class=\"login-container\" id=\"loginContainer\">
        <div class=\"login-box\">
            <h2>🔐 Lisp-Claw IM Login</h2>
            <div class=\"form-group\">
                <label>User ID</label>
                <input type=\"text\" id=\"userId\" placeholder=\"Enter your user ID\">
            </div>
            <div class=\"form-group\">
                <label>Password</label>
                <input type=\"password\" id=\"password\" placeholder=\"Enter your password\">
            </div>
            <button class=\"login-button\" onclick=\"login()\">Login</button>
        </div>
    </div>

    <div class=\"sidebar\">
        <div class=\"sidebar-header\">
            <h2>💬 Lisp-Claw IM</h2>
        </div>
        <div class=\"search-box\">
            <input type=\"text\" placeholder=\"Search conversations...\" id=\"searchBox\">
        </div>
        <div class=\"conversation-list\" id=\"conversationList\">
            <!-- Conversations will be loaded here -->
        </div>
    </div>

    <div class=\"main-content\">
        <div class=\"chat-header\">
            <h3 id=\"chatTitle\">Select a conversation</h3>
        </div>
        <div class=\"chat-messages\" id=\"chatMessages\">
            <!-- Messages will be loaded here -->
        </div>
        <div class=\"message-input-container\">
            <div class=\"message-input-wrapper\">
                <input type=\"text\" class=\"message-input\" id=\"messageInput\" placeholder=\"Type a message...\" onkeypress=\"handleKeyPress(event)\">
                <button class=\"send-button\" onclick=\"sendMessage()\">Send</button>
            </div>
        </div>
    </div>

    <script>
        let currentUser = null;
        let currentConversation = null;
        let ws = null;

        // Show login on load
        document.getElementById('loginContainer').style.display = 'flex';

        async function login() {
            const userId = document.getElementById('userId').value;
            const password = document.getElementById('password').value;

            try {
                const response = await fetch('/api/im/login', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ user_id: userId, password: password })
                });
                const data = await response.json();

                if (data.status === 'success') {
                    currentUser = data.user;
                    document.getElementById('loginContainer').style.display = 'none';
                    connectWebSocket();
                    loadConversations();
                } else {
                    alert('Login failed: ' + data.message);
                }
            } catch (error) {
                alert('Login error: ' + error.message);
            }
        }

        function connectWebSocket() {
            const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
            ws = new WebSocket(protocol + '//' + window.location.host + '/ws/im');

            ws.onopen = function() {
                console.log('WebSocket connected');
                // Send authentication
                ws.send(JSON.stringify({
                    type: 'auth',
                    user_id: currentUser.user_id,
                    token: currentUser.token
                }));
            };

            ws.onmessage = function(event) {
                const data = JSON.parse(event.data);
                handleMessage(data);
            };

            ws.onclose = function() {
                console.log('WebSocket disconnected');
                setTimeout(connectWebSocket, 3000);
            };
        }

        function handleMessage(data) {
            switch(data.type) {
                case 'welcome':
                    console.log('Welcome received');
                    break;
                case 'chat':
                    if (currentConversation && data.conversation_id === currentConversation.conversation_id) {
                        appendMessage(data);
                    }
                    loadConversations(); // Update preview
                    break;
                case 'typing':
                    showTypingIndicator(data.user_id);
                    break;
            }
        }

        async function loadConversations() {
            try {
                const response = await fetch('/api/im/conversations?user_id=' + currentUser.user_id);
                const conversations = await response.json();

                const list = document.getElementById('conversationList');
                list.innerHTML = '';

                conversations.forEach(function(conv) {
                    const item = document.createElement('div');
                    item.className = 'conversation-item';
                    item.onclick = function() { selectConversation(conv); };
                    item.innerHTML = '<div class=\"conversation-name\">' + conv.participants.join(', ') + '</div>' +
                                    '<div class=\"conversation-preview\">Click to chat</div>';
                    list.appendChild(item);
                });
            } catch (error) {
                console.error('Failed to load conversations:', error);
            }
        }

        function selectConversation(conv) {
            currentConversation = conv;
            document.getElementById('chatTitle').textContent = conv.participants.join(', ');
            loadMessages(conv.conversation_id);

            // Update active state
            document.querySelectorAll('.conversation-item').forEach(function(item) {
                item.classList.remove('active');
            });
            event.target.classList.add('active');
        }

        async function loadMessages(conversationId) {
            try {
                const response = await fetch('/api/im/messages?conversation_id=' + conversationId);
                const messages = await response.json();

                const container = document.getElementById('chatMessages');
                container.innerHTML = '';

                messages.forEach(function(msg) {
                    appendMessage(msg);
                });

                container.scrollTop = container.scrollHeight;
            } catch (error) {
                console.error('Failed to load messages:', error);
            }
        }

        function appendMessage(msg) {
            const container = document.getElementById('chatMessages');
            const isSent = msg.sender_id === currentUser.user_id;

            const messageDiv = document.createElement('div');
            messageDiv.className = 'message' + (isSent ? ' sent' : '');
            messageDiv.innerHTML =
                '<div class=\"message-avatar\">' + msg.sender_id.charAt(0).toUpperCase() + '</div>' +
                '<div class=\"message-content\">' +
                    '<div class=\"message-bubble\">' + escapeHtml(msg.content) + '</div>' +
                    '<div class=\"message-meta\">' + formatTime(msg.created_at) + ' • ' + msg.status + '</div>' +
                '</div>';

            container.appendChild(messageDiv);
            container.scrollTop = container.scrollHeight;
        }

        async function sendMessage() {
            const input = document.getElementById('messageInput');
            const content = input.value.trim();

            if (!content || !currentConversation) return;

            try {
                await fetch('/api/im/send', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        conversation_id: currentConversation.conversation_id,
                        content: content
                    })
                });
                input.value = '';
            } catch (error) {
                console.error('Failed to send message:', error);
            }
        }

        function handleKeyPress(event) {
            if (event.key === 'Enter') {
                sendMessage();
            }
        }

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }

        function formatTime(timestamp) {
            const date = new Date(timestamp * 1000);
            return date.toLocaleTimeString();
        }

        function showTypingIndicator(userId) {
            // Could show a typing indicator here
        }
    </script>
</body>
</html>
")
    s))

;;; ============================================================================
;;; API Handlers
;;; ============================================================================

(defun handle-im-login ()
  "Handle IM login request."
  (let* ((body (hunchentoot:raw-post-data))
         (data (when body (json:decode-json-from-string body)))
         (user-id (gethash "user_id" data))
         (password (gethash "password" data)))
    (if (and user-id password)
        (let ((user (lisp-claw.instant-messaging:authenticate-user user-id password)))
          (if user
              (json:encode-json-to-string
               (list :status "success"
                     :user (list :user-id (lisp-claw.instant-messaging:im-user-id user)
                                 :username (lisp-claw.instant-messaging:im-username user)
                                 :token (uuid:make-uuid-string))))
              (json:encode-json-to-string
               (list :status "error" :message "Invalid credentials"))))
        (json:encode-json-to-string
         (list :status "error" :message "Missing credentials")))))

(defun handle-im-send ()
  "Handle send message request."
  (let* ((body (hunchentoot:raw-post-data))
         (data (when body (json:decode-json-from-string body)))
         (conversation-id (gethash "conversation_id" data))
         (content (gethash "content" data)))
    (if (and conversation-id content)
        ;; Send message logic
        (json:encode-json-to-string (list :status "success"))
        (json:encode-json-to-string (list :status "error" :message "Missing parameters")))))

(defun handle-im-messages ()
  "Handle get messages request."
  (let* ((params (hunchentoot:get-parameters*))
         (conversation-id (cdr (assoc "conversation_id" params :test #'string=))))
    (if conversation-id
        ;; Get messages logic
        (json:encode-json-to-string (list :status "success" :messages nil))
        (json:encode-json-to-string (list :status "error" :message "Missing conversation_id")))))

(defun handle-im-users ()
  "Handle get users request."
  (let ((users (lisp-claw.instant-messaging:list-online-users)))
    (json:encode-json-to-string
     (mapcar (lambda (u) (list :user-id (lisp-claw.instant-messaging:im-user-id u)
                               :username (lisp-claw.instant-messaging:im-username u)
                               :status (lisp-claw.instant-messaging:im-user-status u)))
             users))))

(defun handle-im-groups ()
  "Handle get groups request."
  (json:encode-json-to-string (list :status "success" :groups nil)))

(defun serve-im-static ()
  "Serve static IM resources."
  (setf (hunchentoot:content-type*) "text/plain")
  "Static resources would be served here")

;;; ============================================================================
;;; Start/Stop Functions
;;; ============================================================================

(defun start-im-web (&key port)
  "Start IM web interface.

  Args:
    PORT: Port to run on (optional)

  Returns:
    T on success"
  (log-info "Starting IM web interface on port ~A" (or port 18791))
  (register-im-web-routes)
  t)

(defun stop-im-web ()
  "Stop IM web interface.

  Returns:
    T on success"
  (log-info "Stopping IM web interface")
  t)
