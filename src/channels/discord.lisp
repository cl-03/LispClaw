;;; channels/discord.lisp --- Discord Channel for Lisp-Claw
;;;
;;; This file implements Discord channel integration using the Discord API
;;; with WebSocket gateway for real-time events.

(defpackage #:lisp-claw.channels.discord
  (:nicknames #:lc.channels.discord)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:dexador
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.crypto
        #:lisp-claw.channels.base)
  (:export
   #:discord-channel
   #:make-discord-channel
   #:discord-token
   #:start-discord-gateway
   #:stop-discord-gateway
   #:discord-send-message))

(in-package #:lisp-claw.channels.discord)

;;; ============================================================================
;;; Discord Channel Class
;;; ============================================================================

(defclass discord-channel (channel)
  ((token :initarg :token
          :reader discord-token
          :documentation "Discord bot token")
   (bot-id :initform nil
           :accessor discord-bot-id
           :documentation "Bot user ID")
   (bot-username :initform nil
                 :accessor discord-bot-username
                 :documentation "Bot username")
   (gateway-thread :initform nil
                   :accessor discord-gateway-thread
                   :documentation "WebSocket gateway thread")
   (gateway-url :initform nil
                :accessor discord-gateway-url
                :documentation "WebSocket gateway URL")
   (session-id :initform nil
               :accessor discord-session-id
               :documentation "Gateway session ID")
   (sequence :initform 0
             :accessor discord-sequence
             :documentation "Last sequence number")
   (heartbeat-interval :initform 45000
                       :accessor discord-heartbeat-interval
                       :documentation "Heartbeat interval in ms")
   (heartbeat-thread :initform nil
                     :accessor discord-heartbeat-thread
                     :documentation "Heartbeat thread")
   (guilds :initform (make-hash-table)
           :accessor discord-guilds
           :documentation "Cached guild data")
   (channels :initform (make-hash-table)
             :accessor discord-channels
             :documentation "Cached channel data")))

(defmethod print-object ((channel discord-channel) stream)
  "Print discord channel representation."
  (print-unreadable-object (channel stream :type t)
    (format stream "~A [~A]"
            (or (discord-bot-username channel) "Discord")
            (if (channel-connected-p channel) "connected" "disconnected"))))

;;; ============================================================================
;;; Constants
;;; ============================================================================

(defconstant +discord-api-version+ "10"
  "Discord API version.")

(defconstant +discord-gateway-version+ "9"
  "Discord Gateway version.")

(defconstant +discord-gateway-encoding+ "json"
  "Gateway encoding.")

;;; ============================================================================
;;; Construction
;;; ============================================================================

(defun make-discord-channel (&key name token config)
  "Create a new Discord channel instance.

  Args:
    NAME: Channel name
    TOKEN: Discord bot token
    CONFIG: Configuration alist

  Returns:
    Discord channel instance"
  (let ((channel (make-instance 'discord-channel
                                :name (or name "discord")
                                :token (or token
                                           (getf config :token)
                                           (getf config :bot-token))
                                :config config)))
    (log-info "Discord channel created: ~A" name)
    channel))

;;; ============================================================================
;;; Channel Lifecycle
;;; ============================================================================

(defmethod channel-connect ((channel discord-channel))
  "Connect to Discord.

  Args:
    CHANNEL: Discord channel instance

  Returns:
    T on success"
  (handler-case
      (progn
        ;; Get gateway URL
        (let ((gateway-info (discord-api-request channel "GET" "/gateway")))
          (when gateway-info
            (setf (discord-gateway-url channel)
                  (gethash "url" gateway-info))
            (log-info "Discord gateway URL: ~A" (discord-gateway-url channel))))

        ;; Get bot info
        (let ((bot-info (discord-api-request channel "GET" "/users/@me")))
          (when bot-info
            (setf (discord-bot-id channel)
                  (gethash "id" bot-info))
            (setf (discord-bot-username channel)
                  (gethash "username" bot-info))
            (log-info "Connected as ~A#~A"
                      (discord-bot-username channel)
                      (gethash "discriminator" bot-info))))

        ;; Start gateway connection
        (start-discord-gateway channel)

        (setf (channel-status channel) :connected)
        (setf (channel-connected-p channel) t)
        (log-info "Discord channel connected")
        t)

    (error (e)
      (log-error "Failed to connect Discord: ~A" e)
      (setf (channel-status channel) :error)
      nil)))

(defmethod channel-disconnect ((channel discord-channel))
  "Disconnect from Discord.

  Args:
    CHANNEL: Discord channel instance

  Returns:
    T on success"
  (stop-discord-gateway channel)
  (setf (channel-status channel) :disconnected)
  (setf (channel-connected-p channel) nil)
  (log-info "Discord channel disconnected")
  t)

;;; ============================================================================
;;; Message Sending
;;; ============================================================================

(defmethod channel-send-message ((discord-channel channel) recipient message
                                 &key embeds tts)
  "Send a message to Discord.

  Args:
    CHANNEL: Discord channel instance
    RECIPIENT: Channel ID
    MESSAGE: Message text
    EMBEDS: Optional embed data
    TTS: Whether to use TTS

  Returns:
    T on success"
  (handler-case
      (let ((params `(("content" . ,message))))
        (when tts
          (push (cons "tts" t) params))
        (when embeds
          (push (cons "embeds" embeds) params))

        (discord-api-request channel "POST"
                             (format nil "/channels/~A/messages" recipient)
                             params)
        (log-debug "Discord message sent to ~A" recipient)
        t)

    (error (e)
      (log-error "Failed to send Discord message: ~A" e)
      nil)))

(defmethod channel-send-file ((channel discord-channel) recipient file
                              &key caption)
  "Send a file to Discord.

  Args:
    CHANNEL: Discord channel instance
    RECIPIENT: Channel ID
    FILE: File path or URL
    CAPTION: Optional caption

  Returns:
    T on success"
  (declare (ignore channel recipient file caption))
  ;; TODO: Implement file upload
  (log-warn "Discord file upload not yet implemented")
  nil)

(defmethod channel-get-members ((channel discord-channel) guild-id)
  "Get members of a Discord guild.

  Args:
    CHANNEL: Discord channel instance
    GUILD-ID: Guild ID

  Returns:
    List of member alists"
  (handler-case
      (let ((result (discord-api-request channel "GET"
                                         (format nil "/guilds/~A/members" guild-id))))
        (when result
          (let ((members nil))
            (do-vector (member result)
              (push (parse-discord-member member) members))
            members)))
    (error (e)
      (log-error "Failed to get Discord members: ~A" e)
      nil)))

(defmethod channel-get-chat-info ((channel discord-channel) channel-id)
  "Get information about a Discord channel.

  Args:
    CHANNEL: Discord channel instance
    CHANNEL-ID: Channel ID

  Returns:
    Channel info alist"
  (handler-case
      (let ((result (discord-api-request channel "GET"
                                         (format nil "/channels/~A" channel-id))))
        (when result
          (parse-discord-channel result)))
    (error (e)
      (log-error "Failed to get Discord channel info: ~A" e)
      nil)))

;;; ============================================================================
;;; Discord API
;;; ============================================================================

(defun discord-api-request (channel method path &optional params)
  "Make a Discord API request.

  Args:
    CHANNEL: Discord channel instance
    METHOD: HTTP method (GET, POST, etc.)
    PATH: API path (e.g., "/users/@me")
    PARAMS: Request body params

  Returns:
    Response data or NIL"
  (let* ((url (format nil "https://discord.com/api/v~A~A"
                      +discord-api-version+ path))
         (headers `(("Authorization" . ,(format nil "Bot ~A" (discord-token channel)))
                    ("Content-Type" . "application/json")))
         (response (case (intern (string-upcase method) :keyword)
                     (:get
                      (dex:get url :headers headers))
                     (:post
                      (dex:post url
                                :headers headers
                                :content (when params
                                           (stringify-json
                                            (alist-to-hash-table params)))))
                     (:put
                      (dex:put url
                               :headers headers
                               :content (when params
                                          (stringify-json
                                           (alist-to-hash-table params)))))
                     (:delete
                      (dex:delete url :headers headers))
                     (:patch
                      (dex:patch url
                                 :headers headers
                                 :content (when params
                                            (stringify-json
                                             (alist-to-hash-table params))))))))

    (when (and response (not (string= response "")))
      (let ((json (parse-json response)))
        json))))

;;; ============================================================================
;;; WebSocket Gateway
;;; ============================================================================

(defun start-discord-gateway (channel)
  "Start Discord WebSocket gateway connection.

  Args:
    CHANNEL: Discord channel instance

  Returns:
    T on success"
  (let ((url (discord-gateway-url channel)))
    (unless url
      (log-error "No gateway URL available")
      (return-from start-discord-gateway nil))

    (setf (discord-gateway-thread channel)
          (bt:make-thread
           (lambda ()
             (gateway-connection-loop channel url))
           :name "discord-gateway"))

    (log-info "Discord gateway connection started")
    t))

(defun stop-discord-gateway (channel)
  "Stop Discord WebSocket gateway.

  Args:
    CHANNEL: Discord channel instance

  Returns:
    T on success"
  ;; Stop heartbeat
  (let ((hb-thread (discord-heartbeat-thread channel)))
    (when hb-thread
      (bt:destroy-thread hb-thread)
      (setf (discord-heartbeat-thread channel) nil)))

  ;; Stop gateway
  (let ((gw-thread (discord-gateway-thread channel)))
    (when gw-thread
      (bt:destroy-thread gw-thread)
      (setf (discord-gateway-thread channel) nil)))

  (log-info "Discord gateway stopped")
  t)

(defun gateway-connection-loop (channel url)
  "Run the gateway connection loop.

  Args:
    CHANNEL: Discord channel instance
    URL: Gateway WebSocket URL"
  (let ((ws nil))
    (unwind-protect
         (progn
           ;; Connect to gateway
           (setf ws (connect-to-gateway url))

           ;; Process gateway messages
           (loop while (channel-connected-p channel) do
             (handler-case
                 (let ((message (read-gateway-message ws)))
                   (when message
                     (process-gateway-message channel message)))
               (end-of-file ()
                 (log-warn "Gateway connection closed")
                 (return))
               (error (e)
                 (log-error "Gateway error: ~A" e)
                 (sleep 5)
                 (return)))))
      (when ws
        (ignore-errors (close ws))))))

(defun connect-to-gateway (url)
  "Connect to Discord gateway WebSocket.

  Args:
    URL: WebSocket URL

  Returns:
    WebSocket stream"
  ;; Note: Real implementation would use a WebSocket library
  ;; For now, this is a placeholder
  (log-info "Connecting to Discord gateway: ~A" url)
  ;; Would use usocket + cl-babel or similar
  nil)

(defun read-gateway-message (ws)
  "Read a message from the gateway.

  Args:
    WS: WebSocket stream

  Returns:
    Message JSON or NIL"
  (declare (ignore ws))
  ;; Placeholder for real WebSocket reading
  nil)

(defun process-gateway-message (channel message)
  "Process a gateway message.

  Args:
    CHANNEL: Discord channel instance
    MESSAGE: Message JSON

  Returns:
    T on success"
  (let ((op (gethash "op" message))
        (d (gethash "d" message))
        (s (gethash "s" message))
        (t (gethash "t" message)))

    ;; Update sequence number
    (when s
      (setf (discord-sequence channel) s))

    (case op
      ;; Dispatch
      (0
       (handle-gateway-dispatch channel t d))

      ;; Hello
      (10
       (log-info "Gateway hello received")
       (setf (discord-heartbeat-interval channel) (gethash "heartbeat_interval" d))
       ;; Identify
       (send-identify channel)
       ;; Start heartbeat
       (start-heartbeat channel))

      ;; Heartbeat ACK
      (11
       (log-debug "Heartbeat acknowledged"))

      ;; Heartbeat (server wants heartbeat)
      (1
       (send-heartbeat channel))

      ;; Reconnect
      (7
       (log-warn "Reconnect requested")
       ;; Would reconnect)

      ;; Invalid Session
      (9
       (log-error "Invalid session")
       (setf (discord-session-id channel) nil)
       (send-identify channel))

      (otherwise
       (log-debug "Unknown gateway opcode: ~A" op)))))

(defun handle-gateway-dispatch (channel ready-p data)
  "Handle a gateway dispatch event.

  Args:
    CHANNEL: Discord channel instance
    READY-P: Whether this is a READY event
    DATA: Event data

  Returns:
    T on success"
  (let ((event-type (gethash "t" data)))

    (cond
      ((string= event-type "READY")
       (let ((d (gethash "d" data)))
         (setf (discord-session-id channel) (gethash "session_id" d))
         (log-info "Discord READY: ~A" (gethash "user" d))))

      ((string= event-type "MESSAGE_CREATE")
       (handle-discord-message channel (gethash "d" data)))

      ((string= event-type "MESSAGE_UPDATE")
       (handle-discord-message channel (gethash "d" data) :edited-p t))

      ((string= event-type "INTERACTION_CREATE")
       (handle-discord-interaction channel (gethash "d" data)))

      (t
       (log-debug "Discord event: ~A" event-type)))))

;;; ============================================================================
;;; Heartbeat
;;; ============================================================================

(defun start-heartbeat (channel)
  "Start the heartbeat thread.

  Args:
    CHANNEL: Discord channel instance

  Returns:
    T on success"
  (let ((interval (discord-heartbeat-interval channel)))
    (setf (discord-heartbeat-thread channel)
          (bt:make-thread
           (lambda ()
             (heartbeat-loop channel interval))
           :name "discord-heartbeat")))
  t)

(defun heartbeat-loop (channel interval-ms)
  "Run the heartbeat loop.

  Args:
    CHANNEL: Discord channel instance
    INTERVAL-MS: Heartbeat interval in milliseconds"
  (loop while (channel-connected-p channel) do
    (send-heartbeat channel)
    (sleep (/ interval-ms 1000.0))))

(defun send-heartbeat (channel)
  "Send a heartbeat to the gateway.

  Args:
    CHANNEL: Discord channel instance

  Returns:
    T on success"
  (log-debug "Sending heartbeat")
  ;; Would send OP 1 with sequence number
  t)

(defun send-identify (channel)
  "Send identify payload to gateway.

  Args:
    CHANNEL: Discord channel instance

  Returns:
    T on success"
  (log-info "Identifying with Discord gateway")
  ;; Would send OP 2 with identify payload
  t)

;;; ============================================================================
;;; Event Handlers
;;; ============================================================================

(defun handle-discord-message (channel message &key edited-p)
  "Handle a Discord message event.

  Args:
    CHANNEL: Discord channel instance
    MESSAGE: Message data
    EDITED-P: Whether this is an edited message

  Returns:
    T on success"
  (let* ((id (gethash "id" message))
         (channel-id (gethash "channel_id" message))
         (content (gethash "content" message))
         (author (gethash "author" message))
         (author-id (gethash "id" author))
         (author-username (gethash "username" author))
         (timestamp (gethash "timestamp" message)))

    ;; Ignore bot messages
    (when (gethash "bot" author)
      (return-from handle-discord-message nil))

    (log-info "Discord message from ~A: ~A"
              author-username
              (subseq content 0 (min 50 (length content))))

    ;; Handle commands
    (when (and content (char= (char content 0) #\!))
      (handle-discord-command channel channel-id author-id content id))

    ;; Notify
    (notify-message-received channel
                             :channel-id channel-id
                             :author-id author-id
                             :author-username author-username
                             :content content
                             :message-id id
                             :timestamp timestamp
                             :edited-p edited-p)))

(defun handle-discord-interaction (channel interaction)
  "Handle a Discord interaction (button click, etc.).

  Args:
    CHANNEL: Discord channel instance
    INTERACTION: Interaction data

  Returns:
    T on success"
  (let* ((id (gethash "id" interaction))
         (type (gethash "type" interaction))
         (user (gethash "user" interaction))
         (data (gethash "data" interaction)))

    (log-info "Discord interaction type ~A from ~A"
              type (gethash "username" user))

    ;; Handle interaction
    (notify-interaction-received channel
                                 :interaction-id id
                                 :type type
                                 :user-id (gethash "id" user)
                                 :data data)))

(defun handle-discord-command (channel channel-id user-id command message-id)
  "Handle a Discord bot command.

  Args:
    CHANNEL: Discord channel instance
    CHANNEL-ID: Channel ID
    USER-ID: User ID
    COMMAND: Command string
    MESSAGE-ID: Message ID

  Returns:
    T on success"
  (let* ((parts (split-sequence:split-sequence #\Space command))
         (cmd (string-downcase (subseq (first parts) 1)))
         (args (rest parts)))

    (log-debug "Discord command: ~A ~A" cmd args)

    (case (intern (string-upcase cmd) :keyword)
      (:help
       (channel-send-message channel channel-id
                             "Available commands: !help, !status, !ping"))
      (:status
       (channel-send-message channel channel-id
                             (format nil "Lisp-Claw Discord Bot~%Status: ~A"
                                     (if (channel-connected-p channel)
                                         "Online" "Offline"))))
      (:ping
       (channel-send-message channel channel-id "Pong!"))
      (otherwise
       (log-warn "Unknown Discord command: ~A" cmd)))))

;;; ============================================================================
;;; Notification Callbacks
;;; ============================================================================

(defun notify-message-received (channel &rest args)
  "Notify about a received message."
  (declare (ignore channel args))
  ;; Would dispatch to event system
  t)

(defun notify-interaction-received (channel &rest args)
  "Notify about a received interaction."
  (declare (ignore channel args))
  ;; Would dispatch to event system
  t)

;;; ============================================================================
;;; Parsing Utilities
;;; ============================================================================

(defun parse-discord-member (member-data)
  "Parse a Discord guild member object.

  Args:
    MEMBER-DATA: Member JSON object

  Returns:
    Member plist"
  (let ((user (gethash "user" member-data)))
    (list :id (gethash "id" user)
          :username (gethash "username" user)
          :discriminator (gethash "discriminator" user)
          :nick (gethash "nick" member-data)
          :roles (gethash "roles" member-data))))

(defun parse-discord-channel (channel-data)
  "Parse a Discord channel object.

  Args:
    CHANNEL-DATA: Channel JSON object

  Returns:
    Channel plist"
  (list :id (gethash "id" channel-data)
        :type (gethash "type" channel-data)
        :name (gethash "name" channel-data)
        :guild-id (gethash "guild_id" channel-data)))

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
