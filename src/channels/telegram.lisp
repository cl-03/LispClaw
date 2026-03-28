;;; channels/telegram.lisp --- Telegram Channel for Lisp-Claw
;;;
;;; This file implements Telegram channel integration using the Telegram Bot API.
;;; Uses dexador for HTTP requests and bordeaux-threads for long polling.

(defpackage #:lisp-claw.channels.telegram
  (:nicknames #:lc.channels.telegram)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:dexador
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.channels.base)
  (:export
   #:telegram-channel
   #:make-telegram-channel
   #:telegram-bot-token
   #:start-telegram-polling
   #:stop-telegram-polling))

(in-package #:lisp-claw.channels.telegram)

;;; ============================================================================
;;; Telegram Channel Class
;;; ============================================================================

(defclass telegram-channel (channel)
  ((bot-token :initarg :bot-token
              :reader telegram-bot-token
              :documentation "Telegram Bot API token")
   (bot-id :initform nil
           :accessor telegram-bot-id
           :documentation "Bot user ID")
   (bot-username :initform nil
                 :accessor telegram-bot-username
                 :documentation "Bot username")
   (polling-thread :initform nil
                   :accessor telegram-polling-thread
                   :documentation "Long polling thread")
   (offset :initform 0
           :accessor telegram-offset
           :documentation "Update offset for long polling")
   (base-url :initform "https://api.telegram.org/bot"
             :accessor telegram-base-url
             :documentation "Telegram API base URL")))

(defmethod print-object ((channel telegram-channel) stream)
  "Print telegram channel representation."
  (print-unreadable-object (channel stream :type t)
    (format stream "~A [~A]"
            (or (telegram-bot-username channel) "Telegram")
            (if (channel-connected-p channel) "connected" "disconnected"))))

;;; ============================================================================
;;; Construction
;;; ============================================================================

(defun make-telegram-channel (&key name bot-token config)
  "Create a new Telegram channel instance.

  Args:
    NAME: Channel name
    BOT-TOKEN: Telegram Bot API token
    CONFIG: Configuration alist

  Returns:
    Telegram channel instance"
  (let ((channel (make-instance 'telegram-channel
                                :name (or name "telegram")
                                :bot-token (or bot-token
                                               (getf config :bot-token)
                                               (getf config :token))
                                :config config)))
    (log-info "Telegram channel created: ~A" name)
    channel))

;;; ============================================================================
;;; Channel Lifecycle
;;; ============================================================================

(defmethod channel-connect ((channel telegram-channel))
  "Connect to Telegram.

  Args:
    CHANNEL: Telegram channel instance

  Returns:
    T on success"
  (handler-case
      (progn
        ;; Get bot info
        (let ((info (telegram-api-request channel "getMe")))
          (when info
            (setf (telegram-bot-id channel)
                  (gethash "id" info))
            (setf (telegram-bot-username channel)
                  (gethash "username" info))
            (log-info "Connected as @~A" (telegram-bot-username channel))))

        (setf (channel-status channel) :connected)
        (setf (channel-connected-p channel) t)
        (log-info "Telegram channel connected")
        t)

    (error (e)
      (log-error "Failed to connect Telegram: ~A" e)
      (setf (channel-status channel) :error)
      nil)))

(defmethod channel-disconnect ((channel telegram-channel))
  "Disconnect from Telegram.

  Args:
    CHANNEL: Telegram channel instance

  Returns:
    T on success"
  (stop-telegram-polling channel)
  (setf (channel-status channel) :disconnected)
  (setf (channel-connected-p channel) nil)
  (log-info "Telegram channel disconnected")
  t)

;;; ============================================================================
;;; Message Sending
;;; ============================================================================

(defmethod channel-send-message ((channel telegram-channel) recipient message
                                 &key (parse-mode "HTML") reply-to)
  "Send a message via Telegram.

  Args:
    CHANNEL: Telegram channel instance
    RECIPIENT: Chat ID or username
    MESSAGE: Message text
    PARSE-MODE: Parse mode (HTML, Markdown, etc.)
    REPLY-TO: Message ID to reply to

  Returns:
    T on success"
  (handler-case
      (let* ((params `(("chat_id" . ,recipient)
                       ("text" . ,message)))
             (params-with-mode (if parse-mode
                                   (append params `(("parse_mode" . ,parse-mode)))
                                   params))
             (params-final (if reply-to
                               (append params-with-mode `(("reply_to_message_id" . ,reply-to)))
                               params-with-mode)))

        (telegram-api-request channel "sendMessage" params-final)
        (log-debug "Message sent to ~A" recipient)
        t)

    (error (e)
      (log-error "Failed to send Telegram message: ~A" e)
      nil)))

(defmethod channel-send-photo ((channel telegram-channel) recipient photo
                               &key caption)
  "Send a photo via Telegram.

  Args:
    CHANNEL: Telegram channel instance
    RECIPIENT: Chat ID
    PHOTO: Photo URL or file ID
    CAPTION: Optional caption

  Returns:
    T on success"
  (let ((params `(("chat_id" . ,recipient)
                  ("photo" . ,photo))))
    (when caption
      (push (cons "caption" caption) params))
    (telegram-api-request channel "sendPhoto" params)
    t))

(defmethod channel-send-document ((channel telegram-channel) recipient document
                                  &key caption)
  "Send a document via Telegram.

  Args:
    CHANNEL: Telegram channel instance
    RECIPIENT: Chat ID
    DOCUMENT: Document URL or file ID
    CAPTION: Optional caption

  Returns:
    T on success"
  (let ((params `(("chat_id" . ,recipient)
                  ("document" . ,document))))
    (when caption
      (push (cons "caption" caption) params))
    (telegram-api-request channel "sendDocument" params)
    t))

;;; ============================================================================
;;; Group/Channel Management
;;; ============================================================================

(defmethod channel-get-members ((channel telegram-channel) chat-id)
  "Get members of a Telegram group or channel.

  Args:
    CHANNEL: Telegram channel instance
    CHAT-ID: Chat ID

  Returns:
    List of member alists"
  (handler-case
      (let ((result (telegram-api-request channel "getChatAdministrators"
                                          `(("chat_id" . ,chat-id)))))
        (when result
          (let ((members nil))
            (do-vector (member result)
              (push (parse-telegram-user member) members))
            members)))
    (error (e)
      (log-error "Failed to get Telegram members: ~A" e)
      nil)))

(defmethod channel-get-chat-info ((channel telegram-channel) chat-id)
  "Get information about a Telegram chat.

  Args:
    CHANNEL: Telegram channel instance
    CHAT-ID: Chat ID

  Returns:
    Chat info alist"
  (handler-case
      (let ((result (telegram-api-request channel "getChat"
                                          `(("chat_id" . ,chat-id)))))
        (when result
          (parse-telegram-chat result)))
    (error (e)
      (log-error "Failed to get Telegram chat info: ~A" e)
      nil)))

;;; ============================================================================
;;; Telegram API
;;; ============================================================================

(defun telegram-api-request (channel method &optional params)
  "Make a Telegram API request.

  Args:
    CHANNEL: Telegram channel instance
    METHOD: API method name
    PARAMS: Request parameters alist

  Returns:
    Response data or NIL"
  (let* ((url (format nil "~A~A/~A"
                      (telegram-base-url channel)
                      (telegram-bot-token channel)
                      method))
         (json-params (when params
                        (let ((hash (make-hash-table :test 'equal)))
                          (dolist (param params)
                            (setf (gethash (car param) hash) (cdr param)))
                          hash)))
         (response (dex:post url
                             :content (if json-params
                                          (stringify-json json-params)
                                          nil)
                             :headers '(("Content-Type" . "application/json"))
                             :want-stream nil)))

    (let ((json (parse-json response)))
      (if (gethash "ok" json)
          (gethash "result" json)
          (progn
            (log-error "Telegram API error: ~A" json)
            nil)))))

;;; ============================================================================
;;; Long Polling
;;; ============================================================================

(defun start-telegram-polling (channel &key (timeout 30))
  "Start long polling for Telegram updates.

  Args:
    CHANNEL: Telegram channel instance
    TIMEOUT: Poll timeout in seconds

  Returns:
    T on success"
  (when (telegram-polling-thread channel)
    (log-warn "Telegram polling already running")
    (return-from start-telegram-polling nil))

  (setf (telegram-polling-thread channel)
        (bt:make-thread
         (lambda ()
           (telegram-polling-loop channel timeout))
         :name "telegram-polling"))

  (log-info "Telegram polling started")
  t)

(defun stop-telegram-polling (channel)
  "Stop Telegram long polling.

  Args:
    CHANNEL: Telegram channel instance

  Returns:
    T on success"
  (let ((thread (telegram-polling-thread channel)))
    (when thread
      (bt:destroy-thread thread)
      (setf (telegram-polling-thread channel) nil)
      (log-info "Telegram polling stopped")
      t)))

(defun telegram-polling-loop (channel timeout)
  "Run the Telegram polling loop.

  Args:
    CHANNEL: Telegram channel instance
    TIMEOUT: Poll timeout"
  (loop while (channel-connected-p channel) do
    (handler-case
        (let* ((params `(("offset" . ,(telegram-offset channel))
                         ("timeout" . ,timeout)))
               (updates (telegram-api-request channel "getUpdates" params)))

          (when updates
            (do-vector (update updates)
              (process-telegram-update channel update)
              ;; Update offset
              (setf (telegram-offset channel)
                    (1+ (gethash "update_id" update))))))

      (error (e)
        (log-error "Telegram polling error: ~A" e)
        (sleep 5)))
    finally
    (log-info "Telegram polling loop exited")))

;;; ============================================================================
;;; Update Processing
;;; ============================================================================

(defun process-telegram-update (channel update)
  "Process a Telegram update.

  Args:
    CHANNEL: Telegram channel instance
    UPDATE: Update object

  Returns:
    T on success"
  (log-debug "Processing Telegram update")

  (cond
    ;; Message
    ((gethash "message" update)
     (process-telegram-message channel (gethash "message" update)))

    ;; Edited message
    ((gethash "edited_message" update)
     (process-telegram-message channel (gethash "edited_message" update)
                               :edited-p t))

    ;; Callback query
    ((gethash "callback_query" update)
     (process-telegram-callback channel (gethash "callback_query" update)))

    (t
     (log-debug "Unknown update type"))))

(defun process-telegram-message (channel message &key edited-p)
  "Process a Telegram message.

  Args:
    CHANNEL: Telegram channel instance
    MESSAGE: Message object
    EDITED-P: Whether this is an edited message

  Returns:
    T on success"
  (let* ((chat (gethash "chat" message))
         (chat-id (gethash "id" chat))
         (chat-type (gethash "type" chat))
         (from (gethash "from" message))
         (from-id (when from (gethash "id" from)))
         (from-username (when from (gethash "username" from)))
         (message-id (gethash "message_id" message))
         (text (gethash "text" message))
         (date (gethash "date" message)))

    (log-info "Telegram message from ~A in ~A: ~A"
              (or from-username "unknown")
              chat-id
              (subseq text 0 (min 50 (length text))))

    ;; Handle commands
    (when (and text (char= (char text 0) #\/))
      (handle-telegram-command channel chat-id from-id text message-id))

    ;; Notify about new message
    (when text
      (notify-message-received channel
                               :chat-id chat-id
                               :chat-type chat-type
                               :from-id from-id
                               :from-username from-username
                               :text text
                               :message-id message-id
                               :date date
                               :edited-p edited-p))))

(defun process-telegram-callback (channel callback)
  "Process a Telegram callback query.

  Args:
    CHANNEL: Telegram channel instance
    CALLBACK: Callback query object

  Returns:
    T on success"
  (let* ((message (gethash "message" callback))
         (chat-id (gethash "id" (gethash "chat" message)))
         (from (gethash "from" callback))
         (from-id (gethash "id" from))
         (data (gethash "data" callback))
         (message-id (gethash "message_id" message)))

    (log-info "Telegram callback from ~A: ~A" from-id data)

    ;; Handle callback
    (notify-callback-received channel
                              :chat-id chat-id
                              :from-id from-id
                              :data data
                              :message-id message-id)))

(defun handle-telegram-command (channel chat-id from-id command message-id)
  "Handle a Telegram bot command.

  Args:
    CHANNEL: Telegram channel instance
    CHAT-ID: Chat ID
    FROM-ID: User ID
    COMMAND: Command string (e.g., \"/start\")
    MESSAGE-ID: Message ID

  Returns:
    T on success"
  (let* ((parts (split-sequence:split-sequence #\Space command))
         (cmd (string-downcase (subseq (first parts) 1))) ; Remove /
         (args (rest parts)))

    (log-debug "Telegram command: ~A ~A" cmd args)

    (case (intern (string-upcase cmd) :keyword)
      (:start
       (channel-send-message channel chat-id
                             "Welcome to Lisp-Claw! Use /help for commands."
                             :reply-to message-id))
      (:help
       (channel-send-message channel chat-id
                             "Available commands:
/start - Start the bot
/help - Show this help
/status - Bot status
/ping - Ping the bot"
                             :reply-to message-id))
      (:status
       (channel-send-message channel chat-id
                             (format nil "Lisp-Claw Telegram Bot~%Status: ~A"
                                     (if (channel-connected-p channel)
                                         "Online" "Offline"))
                             :reply-to message-id))
      (:ping
       (channel-send-message channel chat-id "Pong!" :reply-to message-id))
      (otherwise
       (log-warn "Unknown Telegram command: ~A" cmd)))))

;;; ============================================================================
;;; Notification Callbacks
;;; ============================================================================

(defun notify-message-received (channel &rest args)
  "Notify about a received message.

  Args:
    CHANNEL: Telegram channel instance
    ARGS: Message arguments

  Returns:
    T on success"
  (declare (ignore channel args))
  ;; Would dispatch to event system
  t)

(defun notify-callback-received (channel &rest args)
  "Notify about a received callback.

  Args:
    CHANNEL: Telegram channel instance
    ARGS: Callback arguments

  Returns:
    T on success"
  (declare (ignore channel args))
  ;; Would dispatch to event system
  t)

;;; ============================================================================
;;; Parsing Utilities
;;; ============================================================================

(defun parse-telegram-user (user-data)
  "Parse a Telegram user object.

  Args:
    USER-DATA: User JSON object

  Returns:
    User plist"
  (list :id (gethash "id" user-data)
        :username (gethash "username" user-data)
        :first-name (gethash "first_name" user-data)
        :last-name (gethash "last_name" user-data)))

(defun parse-telegram-chat (chat-data)
  "Parse a Telegram chat object.

  Args:
    CHAT-DATA: Chat JSON object

  Returns:
    Chat plist"
  (list :id (gethash "id" chat-data)
        :type (gethash "type" chat-data)
        :title (gethash "title" chat-data)
        :username (gethash "username" chat-data)))
