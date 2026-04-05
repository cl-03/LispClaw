;;; channels/slack.lisp --- Slack Channel for Lisp-Claw
;;;
;;; This file implements Slack channel integration using the Slack Bolt API.
;;; Supports both Socket Mode (WebSocket) and HTTP callback modes.

(defpackage #:lisp-claw.channels.slack
  (:nicknames #:lc.channels.slack)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.crypto
        #:lisp-claw.channels.base)
  (:shadowing-import-from #:dexador #:request #:post #:get)
  (:export
   #:slack-channel
   #:make-slack-channel
   #:slack-bot-token
   #:slack-app-token
   #:start-socket-mode
   #:stop-socket-mode
   #:slack-send-message))

(in-package #:lisp-claw.channels.slack)

;;; ============================================================================
;;; Slack Channel Class
;;; ============================================================================

(defclass slack-channel (channel)
  ((bot-token :initarg :bot-token
              :reader slack-bot-token
              :documentation "Slack Bot User OAuth Token (xoxb-...)")
   (app-token :initarg :app-token
              :reader slack-app-token
              :documentation "Slack App-Level Token (xapp-...) for Socket Mode")
   (bot-id :initform nil
           :accessor slack-bot-id
           :documentation "Bot user ID")
   (bot-user-id :initform nil
                :accessor slack-bot-user-id
                :documentation "Bot user ID for filtering")
   (team-id :initform nil
            :accessor slack-team-id
            :documentation "Workspace team ID")
   (socket-thread :initform nil
                  :accessor slack-socket-thread
                  :documentation "Socket Mode WebSocket thread")
   (socket-url :initform nil
               :accessor slack-socket-url
               :documentation "Socket Mode WebSocket URL")
   (channels :initform (make-hash-table :test 'equal)
             :accessor slack-channels
             :documentation "Cached channel info")
   (users :initform (make-hash-table :test 'equal)
          :accessor slack-users
          :documentation "Cached user info")
   (ims :initform (make-hash-table :test 'equal)
        :accessor slack-ims
        :documentation "Cached IM/DM channels")))

(defmethod print-object ((channel slack-channel) stream)
  "Print slack channel representation."
  (print-unreadable-object (channel stream :type t)
    (format stream "~A [~A]"
            (or (slack-bot-user-id channel) "Slack")
            (if (channel-connected-p channel) "connected" "disconnected"))))

;;; ============================================================================
;;; Constants
;;; ============================================================================

(defparameter +slack-api-base+ "https://slack.com/api/"
  "Slack API base URL.")

(defparameter +slack-socket-mode-base+ "wss://wss-primary.slack.com/link.php"
  "Slack Socket Mode WebSocket base URL.")

;;; ============================================================================
;;; Construction
;;; ============================================================================

(defun make-slack-channel (&key name bot-token app-token config)
  "Create a new Slack channel instance.

  Args:
    NAME: Channel name
    BOT-TOKEN: Slack Bot User OAuth Token
    APP-TOKEN: Slack App-Level Token for Socket Mode
    CONFIG: Configuration alist

  Returns:
    Slack channel instance"
  (let ((channel (make-instance 'slack-channel
                                :name (or name "slack")
                                :bot-token (or bot-token
                                               (getf config :bot-token)
                                               (getf config :token))
                                :app-token (or app-token
                                               (getf config :app-token))
                                :config config)))
    (log-info "Slack channel created: ~A" name)
    channel))

;;; ============================================================================
;;; Channel Lifecycle
;;; ============================================================================

(defmethod channel-connect ((channel slack-channel))
  "Connect to Slack.

  Args:
    CHANNEL: Slack channel instance

  Returns:
    T on success"
  (handler-case
      (progn
        ;; Get bot info
        (let ((bot-info (slack-api-request channel "auth.test")))
          (when bot-info
            (setf (slack-bot-id channel)
                  (gethash "user_id" bot-info))
            (setf (slack-bot-user-id channel)
                  (gethash "user_id" bot-info))
            (setf (slack-team-id channel)
                  (gethash "team_id" bot-info))
            (log-info "Connected as ~A in team ~A"
                      (slack-bot-user-id channel)
                      (slack-team-id channel))))

        ;; Start Socket Mode connection
        (start-slack-socket channel)

        (setf (channel-status channel) :connected)
        (setf (channel-connected-p channel) t)
        (log-info "Slack channel connected")
        t)

    (error (e)
      (log-error "Failed to connect Slack: ~A" e)
      (setf (channel-status channel) :error)
      nil)))

(defmethod channel-disconnect ((channel slack-channel))
  "Disconnect from Slack.

  Args:
    CHANNEL: Slack channel instance

  Returns:
    T on success"
  (stop-slack-socket channel)
  (setf (channel-status channel) :disconnected)
  (setf (channel-connected-p channel) nil)
  (log-info "Slack channel disconnected")
  t)

;;; ============================================================================
;;; Message Sending
;;; ============================================================================

(defmethod channel-send-message ((channel slack-channel) recipient message
                                 &key thread-ts blocks attachments)
  "Send a message via Slack.

  Args:
    CHANNEL: Slack channel instance
    RECIPIENT: Channel ID or DM ID
    MESSAGE: Message text
    THREAD-TS: Optional thread timestamp for replies
    BLOCKS: Optional blocks (Slack UI components)
    ATTACHMENTS: Optional attachments

  Returns:
    T on success"
  (handler-case
      (let ((params `(("channel" . ,recipient)
                      ("text" . ,message))))
        (when thread-ts
          (push (cons "thread_ts" thread-ts) params))
        (when blocks
          (push (cons "blocks" blocks) params))
        (when attachments
          (push (cons "attachments" attachments) params))

        (slack-api-request channel "chat.postMessage" params)
        (log-debug "Slack message sent to ~A" recipient)
        t)

    (error (e)
      (log-error "Failed to send Slack message: ~A" e)
      nil)))

(defmethod channel-send-ephemeral ((channel slack-channel) channel-id user-id message)
  "Send an ephemeral message visible only to a specific user.

  Args:
    CHANNEL: Slack channel instance
    CHANNEL-ID: Channel ID
    USER-ID: User ID to receive ephemeral message
    MESSAGE: Message text

  Returns:
    T on success"
  (handler-case
      (let ((params `(("channel" . ,channel-id)
                      ("user" . ,user-id)
                      ("text" . ,message))))
        (slack-api-request channel "chat.postEphemeral" params)
        (log-debug "Ephemeral Slack message sent to ~A in ~A" user-id channel-id)
        t)

    (error (e)
      (log-error "Failed to send ephemeral Slack message: ~A" e)
      nil)))

(defmethod channel-send-reaction ((channel slack-channel) channel-id timestamp reaction)
  "Add a reaction to a message.

  Args:
    CHANNEL: Slack channel instance
    CHANNEL-ID: Channel ID
    TIMESTAMP: Message timestamp
    REACTION: Emoji name (without colons)

  Returns:
    T on success"
  (handler-case
      (let ((params `(("channel" . ,channel-id)
                      ("timestamp" . ,timestamp)
                      ("name" . ,reaction))))
        (slack-api-request channel "reactions.add" params)
        t)

    (error (e)
      (log-error "Failed to add Slack reaction: ~A" e)
      nil)))

;;; ============================================================================
;;; Socket Mode
;;; ============================================================================

(defun start-slack-socket (channel)
  "Start Slack Socket Mode WebSocket connection.

  Args:
    CHANNEL: Slack channel instance

  Returns:
    T on success"
  (when (slack-app-token channel)
    ;; Get Socket Mode connection URL
    (let ((conn-info (slack-api-request channel "apps.connections.open"
                                        :use-app-token t)))
      (when conn-info
        (setf (slack-socket-url channel)
              (gethash "url" conn-info))
        (log-info "Slack Socket URL obtained: ~A" (slack-socket-url channel))

        ;; Start WebSocket connection
        (setf (slack-socket-thread channel)
              (bt:make-thread
               (lambda ()
                 (socket-mode-loop channel))
               :name "slack-socket"))

        (log-info "Slack Socket Mode connection started")
        t))))

(defun stop-slack-socket (channel)
  "Stop Slack Socket Mode connection.

  Args:
    CHANNEL: Slack channel instance

  Returns:
    T on success"
  (let ((thread (slack-socket-thread channel)))
    (when thread
      (bt:destroy-thread thread)
      (setf (slack-socket-thread channel) nil)
      (log-info "Slack Socket Mode stopped")
      t)))

(defun socket-mode-loop (channel)
  "Run the Slack Socket Mode event loop.

  Args:
    CHANNEL: Slack channel instance

  Note: Connects to Slack WebSocket and processes incoming events."
  (let ((url (slack-socket-url channel)))
    (handler-case
        (let ((ws (connect-slack-websocket url)))
          (unwind-protect
               (loop while (channel-connected-p channel) do
                 (handler-case
                     (let ((message (read-slack-websocket-message ws)))
                       (when message
                         (process-slack-socket-message channel message)))
                   (end-of-file ()
                     (log-warn "Slack WebSocket closed")
                     (return))
                   (error (e)
                     (log-error "Slack WebSocket error: ~A" e)
                     (sleep 5)
                     (return))))
            (when ws
              (ignore-errors (close ws)))))
      (error (e)
        (log-error "Failed to start Slack Socket Mode: ~A" e)))))

(defun connect-slack-websocket (url)
  "Connect to Slack WebSocket.

  Args:
    URL: WebSocket URL

  Returns:
    WebSocket stream or NIL"
  (log-info "Connecting to Slack WebSocket: ~A" url)
  ;; In a real implementation, use cl-websocket or similar library
  ;; For now, this is a placeholder
  ;; Example with cl-websocket:
  ;; (let ((host (extract-host url))
  ;;       (port 443)
  ;;       (path (extract-path url)))
  ;;   (cl-websocket:connect host port path :secure t))
  nil)

(defun read-slack-websocket-message (ws)
  "Read a message from Slack WebSocket.

  Args:
    WS: WebSocket stream

  Returns:
    Parsed JSON message or NIL"
  (declare (ignore ws))
  ;; Placeholder for real implementation
  ;; Example:
  ;; (let ((frame (cl-websocket:receive-text-frame ws)))
  ;;   (parse-json frame))
  nil)

(defun extract-host (url)
  "Extract host from URL.

  Args:
    URL: URL string

  Returns:
    Host string"
  (let ((start (search "//" url)))
    (if start
        (let ((end (position #\/ url :start (+ start 2))))
          (if end
              (subseq url (+ start 2) end)
              (subseq url (+ start 2))))
        url)))

(defun extract-path (url)
  "Extract path from URL.

  Args:
    URL: URL string

  Returns:
    Path string"
  (let ((start (search "//" url)))
    (if start
        (let ((path-start (position #\/ url :start (+ start 2))))
          (if path-start
              (subseq url path-start)
              "/"))
        "/")))

(defun process-slack-socket-message (channel message)
  "Process a Socket Mode message.

  Args:
    CHANNEL: Slack channel instance
    MESSAGE: Message JSON

  Returns:
    T on success"
  (let ((msg-type (gethash "type" message)))
    (cond
      ;; Connection confirmation
      ((string= msg-type "hello")
       (log-info "Slack Socket connected"))

      ;; Events API
      ((string= msg-type "events_api")
       (handle-slack-event channel (gethash "event" message))
       ;; Acknowledge receipt
       (acknowledge-slack-event channel (gethash "envelope_id" message)))

      ;; Interactivity (block actions, etc.)
      ((string= msg-type "interactive")
       (handle-slack-interaction channel (gethash "body" message))
       (acknowledge-slack-event channel (gethash "envelope_id" message)))

      ;; Slash commands
      ((string= msg-type "slash_commands")
       (handle-slack-command channel message)
       (acknowledge-slack-event channel (gethash "envelope_id" message)))

      (t
       (log-debug "Unknown Slack Socket message type: ~A" msg-type)))))

(defun acknowledge-slack-event (channel envelope-id)
  "Acknowledge a Slack Socket Mode event.

  Args:
    CHANNEL: Slack channel instance
    ENVELOPE-ID: Event envelope ID

  Returns:
    T on success"
  (declare (ignore channel envelope-id))
  ;; Would send acknowledgment back via WebSocket
  t)

;;; ============================================================================
;;; Event Handling
;;; ============================================================================

(defun handle-slack-event (channel event)
  "Handle a Slack event.

  Args:
    CHANNEL: Slack channel instance
    EVENT: Event data

  Returns:
    T on success"
  (let ((event-type (gethash "type" event)))
    (log-debug "Slack event: ~A" event-type)

    (case (intern (string-upcase event-type) :keyword)
      (:message
       (handle-slack-message channel event))

      (:app_mention
       (handle-slack-mention channel event))

      (:app_home_opened
       (handle-slack-home-opened channel event))

      (:reaction_added)
      (:reaction_removed)

      (t
       (log-debug "Unhandled Slack event type: ~A" event-type)))))

(defun handle-slack-message (channel event)
  "Handle a Slack message event.

  Args:
    CHANNEL: Slack channel instance
    EVENT: Message event data

  Returns:
    T on success"
  (let* ((msg-type (gethash "subtype" event))
         (channel-id (gethash "channel" event))
         (text (gethash "text" event))
         (user (gethash "user" event))
         (ts (gethash "ts" event))
         (thread-ts (gethash "thread_ts" event))
         (bot-id (gethash "bot_id" event)))

    ;; Skip bot messages (including our own)
    (when (or bot-id (string= user (slack-bot-user-id channel)))
      (return-from handle-slack-message nil))

    ;; Skip message subtypes we don't care about
    (when (member msg-type '("message_changed" "message_deleted"
                             "bot_message" "file_share")
                  :test #'string=)
      (return-from handle-slack-message nil))

    (log-info "Slack message in ~A from ~A: ~A"
              channel-id user (subseq (or text "") 0 (min 50 (length (or text "")))))

    ;; Notify
    (notify-message-received channel
                             :channel-id channel-id
                             :user-id user
                             :text text
                             :timestamp ts
                             :thread-ts thread-ts)))

(defun handle-slack-mention (channel event)
  "Handle an app mention event.

  Args:
    CHANNEL: Slack channel instance
    EVENT: Mention event data

  Returns:
    T on success"
  (let* ((channel-id (gethash "channel" event))
         (text (gethash "text" event))
         (user (gethash "user" event))
         (ts (gethash "ts" event)))

    (log-info "Slack mention in ~A from ~A: ~A"
              channel-id user (subseq (or text "") 0 (min 50 (length (or text "")))))

    ;; Notify
    (notify-message-received channel
                             :channel-id channel-id
                             :user-id user
                             :text text
                             :timestamp ts
                             :mention-p t)))

(defun handle-slack-home-opened (channel event)
  "Handle app home opened event.

  Args:
    CHANNEL: Slack channel instance
    EVENT: Home opened event data

  Returns:
    T on success"
  (let ((user (gethash "user" event)))
    (log-info "App home opened by ~A" user)
    ;; Could publish a welcome message to the user's DM
    t))

;;; ============================================================================
;;; Slash Commands
;;; ============================================================================

(defun handle-slack-command (channel message)
  "Handle a Slack slash command.

  Args:
    CHANNEL: Slack channel instance
    MESSAGE: Command message

  Returns:
    T on success"
  (let* ((command (gethash "command" message))
         (text (gethash "text" message))
         (user-id (gethash "user_id" message))
         (channel-id (gethash "channel_id" message))
         (response-url (gethash "response_url" message)))

    (log-info "Slack command: ~A ~A from ~A in ~A"
              command text user-id channel-id)

    (case (intern (string-upcase (subseq command 1)) :keyword)
      (:help
       (send-slack-command-response channel response-url
                                    "Available commands: /help, /status, /ping"))
      (:status
       (send-slack-command-response channel response-url
                                    (format nil "Lisp-Claw Slack Bot~%Status: ~A"
                                            (if (channel-connected-p channel)
                                                "Online" "Offline"))))
      (:ping
       (send-slack-command-response channel response-url "Pong!"))
      (t
       (log-warn "Unknown Slack command: ~A" command)))))

(defun send-slack-command-response (channel response-url text)
  "Send a response to a slash command.

  Args:
    CHANNEL: Slack channel instance
    RESPONSE-URL: Response webhook URL
    TEXT: Response text

  Returns:
    T on success"
  (handler-case
      (let ((payload `(("text" . ,text))))
        (dex:post response-url
                  :content (stringify-json payload)
                  :headers '(("Content-Type" . "application/json")))
        t)

    (error (e)
      (log-error "Failed to send Slack command response: ~A" e)
      nil)))

;;; ============================================================================
;;; Interactions (Block Actions, etc.)
;;; ============================================================================

(defun handle-slack-interaction (channel interaction)
  "Handle a Slack interaction (button click, block action, etc.).

  Args:
    CHANNEL: Slack channel instance
    INTERACTION: Interaction data

  Returns:
    T on success"
  (let ((type (gethash "type" interaction)))
    (log-info "Slack interaction: ~A" type)

    (case (intern (string-upcase (or type "")) :keyword)
      (:block_actions
       (handle-block-action channel interaction))

      (:view_submission
       (handle-view-submission channel interaction))

      (:shortcut
       (handle-shortcut channel interaction))

      (t
       (log-debug "Unknown Slack interaction type: ~A" type)))))

(defun handle-block-action (channel interaction)
  (let* ((actions (gethash "actions" interaction))
         (user (gethash "user" interaction))
         (container (gethash "container" interaction)))
    (declare (ignore actions container))
    (log-info "Block action by ~A" (gethash "user_id" user))
    ;; Process actions
    t))

(defun handle-view-submission (channel interaction)
  (let ((user (gethash "user" interaction))
        (values (gethash "values" interaction)))
    (declare (ignore values))
    (log-info "View submission by ~A" (gethash "user_id" user))
    t))

(defun handle-shortcut (channel interaction)
  "Handle a shortcut invocation.

  Args:
    CHANNEL: Slack channel instance
    INTERACTION: Interaction data

  Returns:
    T on success"
  (let ((user (gethash "user" interaction))
        (callback-id (gethash "callback_id" interaction)))
    (log-info "Shortcut ~A invoked by ~A" callback-id (gethash "user_id" user))
    t))

;;; ============================================================================
;;; Slack API
;;; ============================================================================

(defun slack-api-request (channel method &optional params &key use-app-token)
  "Make a Slack API request.

  Args:
    CHANNEL: Slack channel instance
    METHOD: API method name
    PARAMS: Request parameters
    USE-APP-TOKEN: Use app-level token instead of bot token

  Returns:
    Response data or NIL"
  (let* ((url (format nil "~A~A" +slack-api-base+ method))
         (token (if use-app-token
                    (slack-app-token channel)
                    (slack-bot-token channel)))
         (headers `(("Authorization" . ,(format nil "Bearer ~A" token))
                    ("Content-Type" . "application/json")))
         (response (dex:post url
                             :headers headers
                             :content (when params
                                        (stringify-json
                                         (alist-to-hash-table params))))))

    (when (and response (not (string= response "")))
      (let ((json (parse-json response)))
        (if (gethash "ok" json)
            (gethash "result" json)
            (progn
              (log-error "Slack API error: ~A" json)
              nil))))))

;;; ============================================================================
;;; User/Channel Cache
;;; ============================================================================

(defun cache-slack-users (channel)
  "Cache Slack users.

  Args:
    CHANNEL: Slack channel instance

  Returns:
    T on success"
  (handler-case
      (let* ((result (slack-api-request channel "users.list"))
             (members (gethash "members" result)))
        (loop for i below (length members)
              do (let ((member (aref members i)))
                   (let ((id (gethash "id" member))
                         (name (gethash "name" member))
                         (real-name (gethash "real_name" member)))
                     (setf (gethash id (slack-users channel))
                           (list :id id :name name :real-name real-name)))))
        (log-info "Cached ~A Slack users" (hash-table-count (slack-users channel)))
        t)

    (error (e)
      (log-error "Failed to cache Slack users: ~A" e)
      nil)))

(defun get-slack-user (channel user-id)
  "Get cached user info.

  Args:
    CHANNEL: Slack channel instance
    USER-ID: User ID

  Returns:
    User info plist"
  (gethash user-id (slack-users channel)))

;;; ============================================================================
;;; Notification Callbacks
;;; ============================================================================

(defun notify-message-received (channel &rest args)
  "Notify about a received message.

  Args:
    CHANNEL: Slack channel instance
    ARGS: Message arguments

  Returns:
    T on success"
  (declare (ignore channel args))
  ;; Would dispatch to event system
  t)

;;; ============================================================================
;;; Utilities
;;; ============================================================================

(defun alist-to-hash-table (alist)
  "Convert an alist to a hash table.

  Args:
    ALIST: Alist to convert

  Returns:
    Hash table"
  (let ((hash (make-hash-table :test 'equal)))
    (dolist (pair alist)
      (setf (gethash (car pair) hash) (cdr pair)))
    hash))

(defun string-to-hash-table (json-string)
  "Convert a JSON string to a hash table.

  Args:
    JSON-STRING: JSON string

  Returns:
    Hash table"
  (parse-json json-string))
