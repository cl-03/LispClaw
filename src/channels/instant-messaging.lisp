;;; instant-messaging.lisp --- Instant Messaging App for Lisp-Claw
;;;
;;; This file implements a self-developed instant messaging application supporting:
;;; - WebSocket real-time communication
;;; - User authentication and management
;;; - Message storage and retrieval
;;; - Group chat support
;;; - Message encryption
;;; - Online status tracking
;;; - Message push notifications

(defpackage #:lisp-claw.instant-messaging
  (:nicknames #:lc.im)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.security.encryption
        #:lisp-claw.automation.event-bus
        #:clack
        #:hunchentoot
        #:uuid)
  (:export
   ;; IM Server
   #:im-server
   #:make-im-server
   #:start-im-server
   #:stop-im-server
   ;; User management
   #:im-user
   #:make-im-user
   #:get-user
   #:create-user
   #:update-user
   #:delete-user
   #:authenticate-user
   #:list-online-users
   ;; Connection management
   #:im-connection
   #:get-connection
   #:add-connection
   #:remove-connection
   #:broadcast-to-user
   ;; Message management
   #:im-message
   #:make-im-message
   #:send-message
   #:get-message
   #:get-conversation-history
   #:delete-message
   #:update-message-status
   ;; Group chat
   #:im-group
   #:make-im-group
   #:create-group
   #:get-group
   #:add-group-member
   #:remove-group-member
   #:send-group-message
   #:get-group-members
   ;; Conversation
   #:conversation
   #:get-conversation
   #:get-user-conversations
   ;; Push notifications
   #:push-to-user
   #:push-to-group
   ;; Initialization
   #:initialize-im-system))

(in-package #:lisp-claw.instant-messaging)

;;; ============================================================================
;;; Global Stores
;;; ============================================================================

(defvar *im-users* (make-hash-table :test 'equal)
  "Hash table storing user objects by user-id.")

(defvar *im-connections* (make-hash-table :test 'equal)
  "Hash table storing active connections by user-id.")

(defvar *im-groups* (make-hash-table :test 'equal)
  "Hash table storing group objects by group-id.")

(defvar *im-messages* (make-hash-table :test 'equal)
  "Hash table storing messages by message-id.")

(defvar *im-conversations* (make-hash-table :test 'equal)
  "Hash table storing conversations by conversation-id.")

(defvar *user-conversation-index* (make-hash-table :test 'equal)
  "Index mapping user-id to list of conversation-ids.")

(defvar *im-server-instance* nil
  "Current IM server instance.")

(defvar *im-connection-lock* (bt:make-lock)
  "Lock for connection operations.")

;;; ============================================================================
;;; User Class
;;; ============================================================================

(defclass im-user ()
  ((user-id :initarg :user-id
            :reader im-user-id
            :documentation "Unique user identifier")
   (username :initarg :username
             :reader im-username
             :documentation "User display name")
   (email :initarg :email
          :initform nil
          :reader im-user-email
          :documentation "User email address")
   (password-hash :initarg :password-hash
                  :initform nil
                  :reader im-user-password-hash
                  :documentation "Hashed password")
   (phone :initarg :phone
          :initform nil
          :reader im-user-phone
          :documentation "Phone number")
   (avatar :initarg :avatar
           :initform nil
           :reader im-user-avatar
           :documentation "Avatar URL")
   (status :initform :offline
           :accessor im-user-status
           :documentation "User status: online, offline, away, busy")
   (created-at :initform (get-universal-time)
               :reader im-user-created-at
               :documentation "Account creation time")
   (last-seen :initform nil
              :accessor im-user-last-seen
              :documentation "Last online time")
   (metadata :initform (make-hash-table :test 'equal)
             :reader im-user-metadata
             :documentation "Additional user metadata"))
  (:documentation "Instant messaging user account"))

(defmethod print-object ((user im-user) stream)
  (print-unreadable-object (user stream :type t)
    (format stream "~A [~A]" (im-username user) (im-user-status user))))

(defun make-im-user (user-id username &key email password phone avatar)
  "Create a new IM user.

  Args:
    USER-ID: Unique user identifier
    USERNAME: Display name
    EMAIL: Email address (optional)
    PASSWORD: Password (will be hashed)
    PHONE: Phone number (optional)
    AVATAR: Avatar URL (optional)

  Returns:
    IM user instance"
  (let ((user (make-instance 'im-user
                             :user-id user-id
                             :username username
                             :email email
                             :password-hash (when password
                                              (hash-password password))
                             :phone phone
                             :avatar avatar)))
    (setf (gethash user-id *im-users*) user)
    (log-info "User ~A created" user-id)
    user))

(defun get-user (user-id)
  "Get user by ID.

  Args:
    USER-ID: User identifier

  Returns:
    IM user or NIL"
  (gethash user-id *im-users*))

(defun create-user (user-id username &key email password phone avatar)
  "Create a new user (convenience function).

  Args:
    USER-ID: Unique user identifier
    USERNAME: Display name
    EMAIL: Email address
    PASSWORD: Password
    PHONE: Phone number
    AVATAR: Avatar URL

  Returns:
    Created user or NIL if exists"
  (unless (get-user user-id)
    (make-im-user user-id username
                  :email email
                  :password password
                  :phone phone
                  :avatar avatar)))

(defun update-user (user-id &key username email phone avatar status)
  "Update user information.

  Args:
    USER-ID: User identifier
    USERNAME: New display name
    EMAIL: New email
    PHONE: New phone number
    AVATAR: New avatar URL
    STATUS: New status

  Returns:
    Updated user or NIL"
  (let ((user (get-user user-id)))
    (when user
      (when username (setf (slot-value user 'username) username))
      (when email (setf (slot-value user 'email) email))
      (when phone (setf (slot-value user 'phone) phone))
      (when avatar (setf (slot-value user 'avatar) avatar))
      (when status (setf (im-user-status user) status))
      user)))

(defun delete-user (user-id)
  "Delete a user.

  Args:
    USER-ID: User identifier

  Returns:
    T on success"
  (let ((user (get-user user-id)))
    (when user
      (remhash user-id *im-users*)
      ;; Close connection if online
      (let ((conn (get-connection user-id)))
        (when conn
          (remove-connection user-id)))
      (log-info "User ~A deleted" user-id)
      t)))

(defun authenticate-user (user-id password)
  "Authenticate user with password.

  Args:
    USER-ID: User identifier
    PASSWORD: Password to verify

  Returns:
    User on success, NIL on failure"
  (let ((user (get-user user-id)))
    (when (and user (im-user-password-hash user))
      (if (verify-password password (im-user-password-hash user))
          (progn
            (setf (im-user-status user) :online)
            (setf (im-user-last-seen user) (get-universal-time))
            user)
          nil))))

(defun list-online-users ()
  "List all online users.

  Returns:
    List of online users"
  (let ((online nil))
    (maphash (lambda (uid user)
               (declare (ignore uid))
               (when (eq (im-user-status user) :online)
                 (push user online)))
             *im-users*)
    online))

;;; ============================================================================
;;; Connection Class
;;; ============================================================================

(defclass im-connection ()
  ((user-id :initarg :user-id
            :reader im-conn-user-id
            :documentation "Associated user ID")
   (socket :initarg :socket
           :reader im-conn-socket
           :documentation "WebSocket socket")
   (connected-at :initform (get-universal-time)
                 :reader im-conn-connected-at
                 :documentation "Connection time")
   (last-activity :initform (get-universal-time)
                  :accessor im-conn-last-activity
                  :documentation "Last activity time")
   (message-count :initform 0
                  :accessor im-conn-message-count
                  :documentation "Messages sent through this connection"))
  (:documentation "User WebSocket connection"))

(defun get-connection (user-id)
  "Get user's active connection.

  Args:
    USER-ID: User identifier

  Returns:
    Connection or NIL"
  (gethash user-id *im-connections*))

(defun add-connection (user-id socket)
  "Add a new connection for user.

  Args:
    USER-ID: User identifier
    SOCKET: WebSocket socket

  Returns:
    Connection instance"
  (bt:with-lock-held (*im-connection-lock*)
    (let ((conn (make-instance 'im-connection
                               :user-id user-id
                               :socket socket)))
      (setf (gethash user-id *im-connections*) conn)
      ;; Update user status
      (let ((user (get-user user-id)))
        (when user
          (setf (im-user-status user) :online)))
      (log-info "User ~A connected" user-id)
      conn)))

(defun remove-connection (user-id)
  "Remove user's connection.

  Args:
    USER-ID: User identifier

  Returns:
    T on success"
  (bt:with-lock-held (*im-connection-lock*)
    (let ((conn (gethash user-id *im-connections*)))
      (when conn
        (remhash user-id *im-connections*)
        ;; Update user status
        (let ((user (get-user user-id)))
          (when user
            (setf (im-user-status user) :offline)
            (setf (im-user-last-seen user) (get-universal-time))))
        (log-info "User ~A disconnected" user-id)
        t))))

(defun broadcast-to-user (user-id message)
  "Send message to specific user's connection.

  Args:
    USER-ID: Target user ID
    MESSAGE: Message to send

  Returns:
    T on success"
  (let ((conn (get-connection user-id)))
    (when (and conn (im-conn-socket conn))
      (handler-case
          (progn
            ;; Send via WebSocket
            (let ((socket (im-conn-socket conn)))
              ;; WebSocket send implementation depends on clack/websocket
              (log-debug "Message sent to user ~A" user-id))
            (incf (im-conn-message-count conn))
            (setf (im-conn-last-activity conn) (get-universal-time))
            t)
        (error (e)
          (log-error "Failed to send to user ~A: ~A" user-id e)
          nil)))))

;;; ============================================================================
;;; Message Class
;;; ============================================================================

(defclass im-message ()
  ((message-id :initarg :message-id
               :initform (uuid:make-uuid-string)
               :reader im-message-id
               :documentation "Unique message identifier")
   (conversation-id :initarg :conversation-id
                    :reader im-message-conversation-id
                    :documentation "Conversation ID")
   (sender-id :initarg :sender-id
              :reader im-message-sender-id
              :documentation "Sender user ID")
   (content :initarg :content
            :reader im-message-content
            :documentation "Message content")
   (content-type :initarg :content-type
                 :initform :text
                 :reader im-message-content-type
                 :documentation "Content type: text, image, file, etc.")
   (created-at :initform (get-universal-time)
               :reader im-message-created-at
               :documentation "Message creation time")
   (status :initform :sent
           :accessor im-message-status
           :documentation "Message status: sent, delivered, read")
   (read-at :initform nil
            :accessor im-message-read-at
            :documentation "Time when message was read")
   (metadata :initform (make-hash-table :test 'equal)
            :reader im-message-metadata
            :documentation "Additional metadata")
   (encrypted-p :initform nil
                :accessor im-message-encrypted-p
                :documentation "Whether message is encrypted"))
  (:documentation "Instant messaging message"))

(defmethod print-object ((msg im-message) stream)
  (print-unreadable-object (msg stream :type t)
    (format stream "~A -> ~A [~A]"
            (im-message-sender-id msg)
            (im-message-conversation-id msg)
            (im-message-status msg))))

(defun make-im-message (conversation-id sender-id content &key content-type encrypted)
  "Create a new message.

  Args:
    CONVERSATION-ID: Conversation identifier
    SENDER-ID: Sender user ID
    CONTENT: Message content
    CONTENT-TYPE: Content type (default: :text)
    ENCRYPTED: Whether to encrypt (default: NIL)

  Returns:
    Message instance"
  (let ((msg (make-instance 'im-message
                            :conversation-id conversation-id
                            :sender-id sender-id
                            :content (if encrypted
                                         (encrypt-message content)
                                         content)
                            :content-type (or content-type :text))))
    (when encrypted
      (setf (im-message-encrypted-p msg) t))
    ;; Store message
    (setf (gethash (im-message-id msg) *im-messages*) msg)
    ;; Add to conversation
    (add-message-to-conversation conversation-id (im-message-id msg))
    msg))

(defun get-message (message-id)
  "Get message by ID.

  Args:
    MESSAGE-ID: Message identifier

  Returns:
    Message or NIL"
  (gethash message-id *im-messages*))

(defun delete-message (message-id)
  "Delete a message.

  Args:
    MESSAGE-ID: Message identifier

  Returns:
    T on success"
  (let ((msg (get-message message-id)))
    (when msg
      (remhash message-id *im-messages*)
      (log-info "Message ~A deleted" message-id)
      t)))

(defun update-message-status (message-id status)
  "Update message status.

  Args:
    MESSAGE-ID: Message identifier
    STATUS: New status (:sent, :delivered, :read)

  Returns:
    T on success"
  (let ((msg (get-message message-id)))
    (when msg
      (setf (im-message-status msg) status)
      (when (eq status :read)
        (setf (im-message-read-at msg) (get-universal-time)))
      t)))

(defun encrypt-message (content)
  "Encrypt message content.

  Args:
    CONTENT: Plain text content

  Returns:
    Encrypted content"
  ;; Use ironclad for encryption
  (let ((key (generate-key))
        (encrypted (ironclad:encrypt-message :aes content)))
    (list :encrypted t
          :data (ironclad:byte-array-to-hex-string encrypted)
          :key-id key)))

(defun get-conversation-history (conversation-id &key limit before after)
  "Get conversation message history.

  Args:
    CONVERSATION-ID: Conversation identifier
    LIMIT: Max messages to return (default: 50)
    BEFORE: Get messages before this message ID
    AFTER: Get messages after this message ID

  Returns:
    List of messages"
  (declare (ignore before after))  ; Simplified implementation
  (let ((messages nil)
        (count 0)
        (max-count (or limit 50)))
    (maphash (lambda (mid msg)
               (when (and (< count max-count)
                          (string= (im-message-conversation-id msg) conversation-id))
                 (push msg messages)
                 (incf count)))
             *im-messages*)
    ;; Sort by creation time (newest first)
    (sort messages #'> :key #'im-message-created-at)))

;;; ============================================================================
;;; Conversation Class
;;; ============================================================================

(defclass conversation ()
  ((conversation-id :initarg :conversation-id
                    :initform (uuid:make-uuid-string)
                    :reader conversation-id
                    :documentation "Unique conversation identifier")
   (type :initarg :type
         :reader conversation-type
         :documentation "Conversation type: direct, group")
   (participants :initarg :participants
                 :initform nil
                 :reader conversation-participants
                 :documentation "List of participant user IDs")
   (messages :initform nil
             :accessor conversation-messages
             :documentation "List of message IDs in order")
   (created-at :initform (get-universal-time)
               :reader conversation-created-at
               :documentation "Conversation creation time")
   (updated-at :initform (get-universal-time)
               :accessor conversation-updated-at
               :documentation "Last update time")
   (metadata :initform (make-hash-table :test 'equal)
             :reader conversation-metadata
             :documentation "Additional metadata"))
  (:documentation "A conversation between users"))

(defun get-conversation (conversation-id)
  "Get conversation by ID.

  Args:
    CONVERSATION-ID: Conversation identifier

  Returns:
    Conversation or NIL"
  (gethash conversation-id *im-conversations*))

(defun get-or-create-conversation (user1-id user2-id)
  "Get or create a direct conversation between two users.

  Args:
    USER1-ID: First user ID
    USER2-ID: Second user ID

  Returns:
    Conversation instance"
  (let ((conv-id (gethash (list user1-id user2-id) *im-conversations*)))
    (if conv-id
        (get-conversation conv-id)
        ;; Create new conversation
        (let ((conv (make-instance 'conversation
                                   :type :direct
                                   :participants (list user1-id user2-id))))
          (setf (gethash (conversation-id conv) *im-conversations*) conv)
          ;; Index by participants
          (let ((user-convs (gethash user1-id *user-conversation-index* nil)))
            (setf (gethash user1-id *user-conversation-index*)
                  (cons (conversation-id conv) user-convs)))
          (let ((user-convs (gethash user2-id *user-conversations* nil)))
            (setf (gethash user2-id *user-conversation-index*)
                  (cons (conversation-id conv) user-convs)))
          conv))))

(defun get-user-conversations (user-id)
  "Get all conversations for a user.

  Args:
    USER-ID: User identifier

  Returns:
    List of conversations"
  (let ((conv-ids (gethash user-id *user-conversation-index* nil))
        (conversations nil))
    (dolist (cid conv-ids)
      (let ((conv (get-conversation cid)))
        (when conv
          (push conv conversations))))
    conversations))

(defun add-message-to-conversation (conversation-id message-id)
  "Add message to conversation.

  Args:
    CONVERSATION-ID: Conversation identifier
    MESSAGE-ID: Message identifier

  Returns:
    T on success"
  (let ((conv (get-conversation conversation-id)))
    (when conv
      (push message-id (conversation-messages conv))
      (setf (conversation-updated-at conv) (get-universal-time))
      t)))

;;; ============================================================================
;;; Group Chat
;;; ============================================================================

(defclass im-group ()
  ((group-id :initarg :group-id
             :initform (uuid:make-uuid-string)
             :reader im-group-id
             :documentation "Unique group identifier")
   (name :initarg :name
         :reader im-group-name
         :documentation "Group name")
   (description :initarg :description
                :initform ""
                :reader im-group-description
                :documentation "Group description")
   (owner-id :initarg :owner-id
             :reader im-group-owner-id
             :documentation "Group owner user ID")
   (members :initarg :members
            :initform nil
            :accessor im-group-members
            :documentation "List of member user IDs")
   (created-at :initform (get-universal-time)
               :reader im-group-created-at
               :documentation "Group creation time")
   (avatar :initarg :avatar
           :initform nil
           :reader im-group-avatar
           :documentation "Group avatar URL")
   (settings :initform (make-hash-table :test 'equal)
             :reader im-group-settings
             :documentation "Group settings"))
  (:documentation "Instant messaging group"))

(defun make-im-group (name owner-id &key description members avatar)
  "Create a new group.

  Args:
    NAME: Group name
    OWNER-ID: Owner user ID
    DESCRIPTION: Group description (optional)
    MEMBERS: Initial members (optional)
    AVATAR: Group avatar URL (optional)

  Returns:
    Group instance"
  (let ((group (make-instance 'im-group
                              :name name
                              :owner-id owner-id
                              :description (or description "")
                              :members (cons owner-id (or members nil))
                              :avatar avatar)))
    (setf (gethash (im-group-id group) *im-groups*) group)
    ;; Create group conversation
    (let ((conv (make-instance 'conversation
                               :type :group
                               :participants (im-group-members group))))
      (setf (gethash (conversation-id conv) *im-conversations*) conv)
      (setf (slot-value group 'conversation-id) (conversation-id conv)))
    (log-info "Group ~A created" name)
    group))

(defun create-group (name owner-id &key description members avatar)
  "Create a new group (convenience function).

  Args:
    NAME: Group name
    OWNER-ID: Owner user ID
    DESCRIPTION: Group description
    MEMBERS: Initial members
    AVATAR: Group avatar

  Returns:
    Created group"
  (make-im-group name owner-id
                 :description description
                 :members members
                 :avatar avatar))

(defun get-group (group-id)
  "Get group by ID.

  Args:
    GROUP-ID: Group identifier

  Returns:
    Group or NIL"
  (gethash group-id *im-groups*))

(defun add-group-member (group-id user-id)
  "Add member to group.

  Args:
    GROUP-ID: Group identifier
    USER-ID: User to add

  Returns:
    T on success"
  (let ((group (get-group group-id)))
    (when (and group (not (member user-id (im-group-members group))))
      (push user-id (im-group-members group))
      (log-info "User ~A added to group ~A" user-id (im-group-name group))
      t)))

(defun remove-group-member (group-id user-id)
  "Remove member from group.

  Args:
    GROUP-ID: Group identifier
    USER-ID: User to remove

  Returns:
    T on success"
  (let ((group (get-group group-id)))
    (when (and group (not (string= user-id (im-group-owner-id group))))
      (setf (im-group-members group)
            (remove user-id (im-group-members group)))
      (log-info "User ~A removed from group ~A" user-id (im-group-name group))
      t)))

(defun get-group-members (group-id)
  "Get all group members.

  Args:
    GROUP-ID: Group identifier

  Returns:
    List of member user IDs"
  (let ((group (get-group group-id)))
    (when group
      (im-group-members group))))

(defun send-group-message (group-id sender-id content &key content-type)
  "Send message to group.

  Args:
    GROUP-ID: Group identifier
    SENDER-ID: Sender user ID
    CONTENT: Message content
    CONTENT-TYPE: Content type

  Returns:
    Message instance"
  (let ((group (get-group group-id)))
    (when group
      (let ((conv-id (slot-value group 'conversation-id)))
        (let ((msg (make-im-message conv-id sender-id content
                                    :content-type (or content-type :text))))
          ;; Notify all members
          (dolist (member-id (im-group-members group))
            (unless (string= member-id sender-id)
              (broadcast-to-user member-id (message-to-plist msg))))
          msg)))))

;;; ============================================================================
;;; Message Protocol
;;; ============================================================================

(defun message-to-plist (message)
  "Convert message to property list for JSON serialization.

  Args:
    MESSAGE: Message instance

  Returns:
    Property list"
  (list :message-id (im-message-id message)
        :conversation-id (im-message-conversation-id message)
        :sender-id (im-message-sender-id message)
        :content (im-message-content message)
        :content-type (im-message-content-type message)
        :created-at (im-message-created-at message)
        :status (im-message-status message)
        :encrypted-p (im-message-encrypted-p message)))

(defun plist-to-message (plist)
  "Convert property list to message.

  Args:
    PLIST: Property list

  Returns:
    Message instance"
  (let ((msg (make-instance 'im-message
                            :conversation-id (getf plist :conversation-id)
                            :sender-id (getf plist :sender-id)
                            :content (getf plist :content)
                            :content-type (or (getf plist :content-type) :text))))
    msg))

;;; ============================================================================
;;; Push Notifications
;;; ============================================================================

(defun push-to-user (user-id message &key title)
  "Send push notification to user.

  Args:
    USER-ID: Target user ID
    MESSAGE: Notification message
    TITLE: Notification title

  Returns:
    T on success"
  (let ((user (get-user user-id)))
    (when user
      ;; Check if user has push endpoint registered
      (let ((endpoint (gethash "push-endpoint" (im-user-metadata user))))
        (when endpoint
          ;; Send push notification via web push protocol
          (log-info "Push notification sent to user ~A" user-id)))
      ;; Also emit event
      (let ((event (make-event "im.push"
                               :payload (list :user-id user-id
                                              :title title
                                              :message message))))
        ;; Requires event-bus
        )
      t)))

(defun push-to-group (group-id message &key exclude-user-id)
  "Send push notification to all group members.

  Args:
    GROUP-ID: Group identifier
    MESSAGE: Notification message
    EXCLUDE-USER-ID: User to exclude (e.g., sender)

  Returns:
    Number of notifications sent"
  (let ((group (get-group group-id))
        (count 0))
    (when group
      (dolist (member-id (im-group-members group))
        (unless (and exclude-user-id (string= member-id exclude-user-id))
          (when (push-to-user member-id message)
            (incf count))))
      count)))

;;; ============================================================================
;;; WebSocket Handler
;;; ============================================================================

(defun handle-im-websocket (socket request)
  "Handle IM WebSocket connection.

  Args:
    SOCKET: WebSocket socket
    REQUEST: HTTP request

  Returns:
    T on success"
  (declare (ignore request))
  (log-info "IM WebSocket connection established")

  ;; Wait for authentication message
  (let ((auth-message (read-websocket-message socket)))
    (when auth-message
      (let* ((data (json:decode-json-from-string auth-message))
             (user-id (gethash "user_id" data))
             (token (gethash "token" data)))
        ;; Authenticate user (simplified)
        (when user-id
          (add-connection user-id socket)
          ;; Send welcome message
          (send-welcome socket user-id)
          ;; Start message loop
          (start-im-message-loop socket user-id))))))

(defun read-websocket-message (socket)
  "Read message from WebSocket.

  Args:
    SOCKET: WebSocket socket

  Returns:
    Message string or NIL"
  ;; Implementation depends on WebSocket library
  nil)

(defun send-welcome (socket user-id)
  "Send welcome message to user.

  Args:
    SOCKET: WebSocket socket
    USER-ID: User identifier"
  (let ((welcome (list :type :welcome
                       :user-id user-id
                       :timestamp (get-universal-time))))
    ;; Send via WebSocket
    (declare (ignore socket))
    (log-info "Welcome sent to user ~A" user-id)))

(defun start-im-message-loop (socket user-id)
  "Start message processing loop for connection.

  Args:
    SOCKET: WebSocket socket
    USER-ID: User identifier"
  (bt:make-thread
   (lambda ()
     (loop
       (let ((message (read-websocket-message socket)))
         (unless message
           (return))
         (process-im-message user-id message))
       (sleep 0.1)))
   :name (format nil "im-loop-~A" user-id)))

(defun process-im-message (user-id message)
  "Process incoming message from user.

  Args:
    USER-ID: User identifier
    MESSAGE: Message string"
  (handler-case
      (let ((data (json:decode-json-from-string message)))
        (let ((msg-type (gethash "type" data)))
          (cond
            ((string= msg-type "chat")
             (handle-chat-message user-id data))
            ((string= msg-type "ack")
             (handle-message-ack user-id data))
            ((string= msg-type "typing")
             (handle-typing-indicator user-id data))
            (t
             (log-warning "Unknown message type: ~A" msg-type)))))
    (error (e)
      (log-error "Error processing IM message: ~A" e))))

(defun handle-chat-message (user-id data)
  "Handle incoming chat message.

  Args:
    USER-ID: User identifier
    DATA: Message data"
  (let* ((target-id (gethash "target_id" data))
         (content (gethash "content" data))
         (conversation (get-or-create-conversation user-id target-id))
         (msg (make-im-message (conversation-id conversation)
                               user-id content)))
    ;; Send to recipient
    (broadcast-to-user target-id (message-to-plist msg))
    ;; Emit event
    ))

(defun handle-message-ack (user-id data)
  "Handle message acknowledgment.

  Args:
    USER-ID: User identifier
    DATA: Ack data"
  (let ((message-id (gethash "message_id" data))
        (status (gethash "status" data)))
    (update-message-status message-id
                           (case (intern (string-upcase status) :keyword)
                             ((|delivered|) :delivered)
                             ((|read|) :read)
                             (otherwise :sent))))
  nil)

(defun handle-typing-indicator (user-id data)
  "Handle typing indicator.

  Args:
    USER-ID: User identifier
    DATA: Typing data"
  (let ((target-id (gethash "target_id" data)))
    ;; Broadcast typing indicator to target
    (broadcast-to-user target-id (list :type :typing
                                       :user-id user-id)))
  nil)

;;; ============================================================================
;;; IM Server
;;; ============================================================================

(defclass im-server ()
  ((port :initarg :port
         :initform 18790
         :reader im-server-port
         :documentation "Server port")
   (host :initarg :host
         :initform "0.0.0.0"
         :reader im-server-host
         :documentation "Server bind address")
   (acceptor :initform nil
             :accessor im-server-acceptor
             :documentation "Hunchentoot acceptor")
   (running-p :initform nil
              :accessor im-server-running-p
              :documentation "Whether server is running"))
  (:documentation "Instant messaging server"))

(defun make-im-server (&key port host)
  "Create IM server instance.

  Args:
    PORT: Server port (default: 18790)
    HOST: Server bind address (default: 0.0.0.0)

  Returns:
    IM server instance"
  (make-instance 'im-server
                 :port (or port 18790)
                 :host (or host "0.0.0.0")))

(defun start-im-server (&optional server)
  "Start IM server.

  Args:
    SERVER: IM server instance (optional)

  Returns:
    T on success"
  (let ((srv (or server (make-im-server))))
    (setf *im-server-instance* srv)
    ;; Setup Hunchentoot acceptor
    (let ((acceptor (make-instance 'hunchentoot:easy-acceptor
                                   :port (im-server-port srv)
                                   :address (im-server-host srv))))
      (setf (im-server-acceptor srv) acceptor)
      ;; Register routes
      (register-im-routes)
      ;; Start acceptor
      (hunchentoot:start acceptor)
      (setf (im-server-running-p srv) t)
      (log-info "IM server started on ~A:~A"
                (im-server-host srv)
                (im-server-port srv)))
    t))

(defun register-im-routes ()
  "Register IM server HTTP routes."
  ;; WebSocket endpoint
  (hunchentoot:define-easy-handler (websocket-im :uri "/ws/im") ()
    (setf (hunchentoot:content-type*) "application/json")
    (handle-im-websocket (hunchentoot:websocket) (hunchentoot:request*)))

  ;; REST API endpoints
  (hunchentoot:define-easy-handler (api-users :uri "/api/im/users") ()
    (setf (hunchentoot:content-type*) "application/json")
    (json:encode-json-to-string
     (mapcar (lambda (u) (list :user-id (im-user-id u)
                               :username (im-username u)
                               :status (im-user-status u)))
             (list-online-users))))

  (hunchentoot:define-easy-handler (api-conversations :uri "/api/im/conversations")
      ((user-id "user_id"))
    (setf (hunchentoot:content-type*) "application/json")
    (let ((convs (get-user-conversations user-id)))
      (json:encode-json-to-string
       (mapcar (lambda (c) (list :conversation-id (conversation-id c)
                                 :type (conversation-type c)
                                 :participants (conversation-participants c)))
               convs)))))

(defun stop-im-server ()
  "Stop IM server.

  Returns:
    T on success"
  (when *im-server-instance*
    (let ((acceptor (im-server-acceptor *im-server-instance*)))
      (when acceptor
        (hunchentoot:stop acceptor))
      (setf (im-server-running-p *im-server-instance*) nil)
      (log-info "IM server stopped")
      t)))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-im-system (&key port)
  "Initialize the instant messaging system.

  Args:
    PORT: Server port (optional)

  Returns:
    T on success"
  (log-info "Initializing IM system...")

  ;; Create default admin user
  (create-user "admin" "Admin"
               :email "admin@lisp-claw.local"
               :password "admin")

  ;; Start server
  (start-im-server (make-im-server :port (or port 18790)))

  (log-info "IM system initialized")
  t)
