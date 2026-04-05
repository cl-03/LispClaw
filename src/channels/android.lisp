;;; channels/android.lisp --- Android Channel for Lisp-Claw
;;;
;;; This file implements Android messaging integration:
;;; - Android Intents for local app communication
;;; - Firebase Cloud Messaging (FCM) for push notifications
;;; - Android notification support
;;; - Deep linking for app navigation
;;;
;;; Features:
;;; - Send messages to Android apps via Intents
;;; - Receive messages from Android apps
;;; - FCM push notification support
;;; - Android-specific message formatting

(defpackage #:lisp-claw.channels.android
  (:nicknames #:lc.channels.android)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.crypto
        #:lisp-claw.channels.base)
  (:export
   ;; Android Channel class
   #:android-channel
   #:make-android-channel
   #:android-package-name
   #:android-fcm-server-key
   #:android-fcm-sender-id
   ;; Android Intents
   #:android-send-intent
   #:android-send-broadcast
   #:android-start-activity
   #:android-show-notification
   ;; FCM
   #:fcm-send-message
   #:fcm-send-topic-message
   #:fcm-send-condition-message
   ;; Device management
   #:android-get-device-info
   #:android-register-device
   #:android-unregister-device
   ;; Message handling
   #:handle-android-message
   #:register-android-handler))

(in-package #:lisp-claw.channels.android)

;;; ============================================================================
;;; Android Channel Class
;;; ============================================================================

(defclass android-channel (channel)
  ((package-name :initarg :package-name
                 :reader android-package-name
                 :documentation "Android app package name")
   (fcm-server-key :initarg :fcm-server-key
                   :initform nil
                   :reader android-fcm-server-key
                   :documentation "FCM server key for push notifications")
   (fcm-sender-id :initarg :fcm-sender-id
                  :initform nil
                  :reader android-fcm-sender-id
                  :documentation "FCM sender ID")
   (device-tokens :initform (make-hash-table :test 'equal)
                  :accessor android-device-tokens
                  :documentation "Registered device FCM tokens")
   (notification-channel :initarg :notification-channel
                         :initform "default"
                         :reader android-notification-channel
                         :documentation "Default notification channel ID")
   (adb-device :initarg :adb-device
               :initform nil
               :reader android-adb-device
               :documentation "ADB device ID for local debugging")
   (message-queue :initform (make-instance 'bt:condition-variable
                                           :name "android-message-queue-cv")
                  :accessor android-message-queue
                  :documentation "Message queue for received messages")
   (message-queue-lock :initform (bt:make-lock "android-message-queue-lock")
                       :accessor android-message-queue-lock
                       :documentation "Message queue lock")))

(defmethod print-object ((channel android-channel) stream)
  "Print android channel representation."
  (print-unreadable-object (channel stream :type t)
    (format t "~A [~A]"
            (or (android-package-name channel) "Android")
            (if (channel-connected-p channel) "connected" "disconnected"))))

;;; ============================================================================
;;; Construction
;;; ============================================================================

(defun make-android-channel (&key name package-name fcm-server-key fcm-sender-id config)
  "Create a new Android channel instance.

  Args:
    NAME: Channel name
    PACKAGE-NAME: Android app package name
    FCM-SERVER-KEY: FCM server key
    FCM-SENDER-ID: FCM sender ID
    CONFIG: Configuration alist

  Returns:
    Android channel instance"
  (let ((channel (make-instance 'android-channel
                                :name (or name "android")
                                :package-name (or package-name
                                                  (getf config :package-name))
                                :fcm-server-key (or fcm-server-key
                                                    (getf config :fcm-server-key))
                                :fcm-sender-id (or fcm-sender-id
                                                   (getf config :fcm-sender-id))
                                :config config)))
    (log-info "Android channel created: ~A" (android-package-name channel))
    channel))

;;; ============================================================================
;;; Channel Lifecycle
;;; ============================================================================

(defmethod channel-connect ((channel android-channel))
  "Connect to Android messaging system.

  Args:
    CHANNEL: Android channel instance

  Returns:
    T on success"
  (handler-case
      (progn
        ;; Verify FCM configuration if provided
        (when (android-fcm-server-key channel)
          (log-info "FCM configured for package: ~A" (android-package-name channel)))

        (setf (channel-connected-p channel) t)
        (setf (channel-status channel) :connected)
        (setf (channel-connect-time channel) (get-universal-time))

        (log-info "Android channel connected: ~A" (android-package-name channel))
        t)
    (error (e)
      (log-error "Failed to connect Android channel: ~A" e)
      (setf (channel-last-error channel) e)
      (incf (channel-error-count channel))
      nil)))

(defmethod channel-disconnect ((channel android-channel))
  "Disconnect from Android.

  Args:
    CHANNEL: Android channel instance

  Returns:
    T on success"
  (setf (channel-connected-p channel) nil)
  (setf (channel-status channel) :disconnected)
  (log-info "Android channel disconnected: ~A" (android-package-name channel))
  t)

;;; ============================================================================
;;; Android Intents
;;; ============================================================================

(defun android-send-intent (channel action &key data type flags package)
  "Send an Android Intent.

  Args:
    CHANNEL: Android channel instance
    ACTION: Intent action string
    DATA: Intent data URI
    TYPE: MIME type
    FLAGS: Intent flags
    PACKAGE: Target package

  Returns:
    T on success"
  (declare (ignore channel))
  ;; This would use ADB or a local Android service
  ;; For now, log the intent
  (log-info "Android Intent: ~A [~A] ~A" action package data)
  t)

(defun android-send-broadcast (channel action &key data extras)
  "Send a broadcast Intent.

  Args:
    CHANNEL: Android channel instance
    ACTION: Broadcast action
    DATA: Optional data
    EXTRAS: Extra parameters (plist)

  Returns:
    T on success"
  (let ((intent-data (list :action action
                           :package (android-package-name channel)
                           :extras extras
                           :data data)))
    (log-info "Android Broadcast: ~A" action)
    (log-debug "Broadcast data: ~A" intent-data)
    t))

(defun android-start-activity (channel action &key data flags)
  "Start an Android Activity.

  Args:
    CHANNEL: Android channel instance
    ACTION: Activity action
    DATA: Activity data URI
    FLAGS: Activity flags

  Returns:
    T on success"
  (let ((intent-flags (or flags '(:new-task :clear-top))))
    (log-info "Android Activity: ~A [~A]" action (android-package-name channel))
    (android-send-intent channel action
                         :data data
                         :flags intent-flags
                         :package (android-package-name channel))))

(defun android-show-notification (channel title message &key icon channel-id priority
                                  pending-intent actions visibility)
  "Show an Android notification.

  Args:
    CHANNEL: Android channel instance
    TITLE: Notification title
    MESSAGE: Notification message
    ICON: Notification icon resource
    CHANNEL-ID: Notification channel ID
    PRIORITY: Notification priority (high, default, low)
    PENDING-INTENT: PendingIntent action
    ACTIONS: Notification actions
    VISIBILITY: Lock screen visibility

  Returns:
    T on success"
  (let ((notification (list :type :notification
                            :title title
                            :message message
                            :icon (or icon "ic_notification")
                            :channel-id (or channel-id (android-notification-channel channel))
                            :priority (or priority :default)
                            :timestamp (get-universal-time)
                            :pending-intent pending-intent
                            :actions actions)))
    (log-info "Android Notification: ~A - ~A" title message)

    ;; If FCM is configured, send as push notification
    (when (android-fcm-server-key channel)
      (fcm-send-notification channel title message
                             :channel-id channel-id
                             :priority priority))
    t))

;;; ============================================================================
;;; Firebase Cloud Messaging
;;; ============================================================================

(defun fcm-send-message (channel device-token message &key data notification priority ttl)
  "Send FCM message to a specific device.

  Args:
    CHANNEL: Android channel instance
    DEVICE-TOKEN: Device FCM registration token
    MESSAGE: Message payload (string or plist)
    DATA: Optional data payload (plist)
    NOTIFICATION: Optional notification object (plist)
    PRIORITY: Message priority (high, normal)
    TTL: Time to live in seconds

  Returns:
    Response plist or NIL on error"
  (unless (android-fcm-server-key channel)
    (log-error "FCM server key not configured")
    (return-from fcm-send-message nil))

  (let* ((url "https://fcm.googleapis.com/fcm/send")
         (headers (list (cons "Authorization" (format nil "key=~A" (android-fcm-server-key channel)))
                        (cons "Content-Type" "application/json")))
         (body (list :to device-token)))

    ;; Add message content
    (when (stringp message)
      (setf (getf body :notification) (list :body message
                                            :title "Lisp-Claw")))

    ;; Add data payload
    (when data
      (setf (getf body :data) data))

    ;; Add notification override
    (when notification
      (setf (getf body :notification)
            (merge (getf body :notification) notification)))

    ;; Add priority
    (when priority
      (setf (getf body :priority) (string-downcase (symbol-name priority))))

    ;; Add TTL
    (when ttl
      (setf (getf body :time_to_live) ttl))

    (handler-case
        (let ((response (dex:post url
                                  :headers headers
                                  :content (stringify-json body))))
          (log-info "FCM message sent to: ~A..." (subseq device-token 0 10))
          (parse-json response))
      (error (e)
        (log-error "FCM send failed: ~A" e)
        (incf (channel-error-count channel))
        nil))))

(defun fcm-send-topic-message (channel topic message &key data notification)
  "Send FCM message to a topic.

  Args:
    CHANNEL: Android channel instance
    TOPIC: Topic name (e.g., \"news\", \"updates\")
    MESSAGE: Message payload
    DATA: Optional data
    NOTIFICATION: Optional notification

  Returns:
    Response plist or NIL"
  (unless (android-fcm-server-key channel)
    (return-from fcm-send-topic-message nil))

  (let* ((url "https://fcm.googleapis.com/fcm/send")
         (headers (list (cons "Authorization" (format nil "key=~A" (android-fcm-server-key channel)))
                        (cons "Content-Type" "application/json")))
         (body (list :to (format nil "/topics/~A" topic))))

    (when (stringp message)
      (setf (getf body :notification) (list :body message)))

    (when data
      (setf (getf body :data) data))

    (when notification
      (setf (getf body :notification)
            (merge (getf body :notification) notification)))

    (handler-case
        (let ((response (dex:post url
                                  :headers headers
                                  :content (stringify-json body))))
          (log-info "FCM topic message sent: ~A" topic)
          (parse-json response))
      (error (e)
        (log-error "FCM topic send failed: ~A" e)
        nil))))

(defun fcm-send-condition-message (channel condition message &key data notification)
  "Send FCM message to devices matching a condition.

  Args:
    CHANNEL: Android channel instance
    CONDITION: Condition string (e.g., \"'foo' in topics && 'bar' in topics\")
    MESSAGE: Message payload
    DATA: Optional data
    NOTIFICATION: Optional notification

  Returns:
    Response plist or NIL"
  (unless (android-fcm-server-key channel)
    (return-from fcm-send-condition-message nil))

  (let* ((url "https://fcm.googleapis.com/fcm/send")
         (headers (list (cons "Authorization" (format nil "key=~A" (android-fcm-server-key channel)))
                        (cons "Content-Type" "application/json")))
         (body (list :condition condition)))

    (when (stringp message)
      (setf (getf body :notification) (list :body message)))

    (when data
      (setf (getf body :data) data))

    (when notification
      (setf (getf body :notification)
            (merge (getf body :notification) notification)))

    (handler-case
        (let ((response (dex:post url
                                  :headers headers
                                  :content (stringify-json body))))
          (log-info "FCM condition message sent: ~A" condition)
          (parse-json response))
      (error (e)
        (log-error "FCM condition send failed: ~A" e)
        nil))))

(defun fcm-send-notification (channel title body &key channel-id priority sound badge click-action)
  "Send FCM notification.

  Args:
    CHANNEL: Android channel instance
    TITLE: Notification title
    BODY: Notification body
    CHANNEL-ID: Android notification channel ID
    PRIORITY: Notification priority
    SOUND: Sound file name
    BADGE: Badge count
    CLICK-ACTION: Click action

  Returns:
    Response plist or NIL"
  (fcm-send-message channel nil ""
                    :notification (list :title title
                                        :body body
                                        :channel-id channel-id
                                        :sound sound
                                        :badge badge
                                        :click-action click-action)
                    :priority priority))

;;; ============================================================================
;;; Device Management
;;; ============================================================================

(defun android-register-device (channel device-id token &key user-id metadata)
  "Register an Android device.

  Args:
    CHANNEL: Android channel instance
    DEVICE-ID: Device identifier
    TOKEN: FCM registration token
    USER-ID: Optional user ID
    METADATA: Optional metadata

  Returns:
    T on success"
  (setf (gethash device-id (android-device-tokens channel))
        (list :token token
              :user-id user-id
              :registered-at (get-universal-time)
              :metadata metadata))
  (log-info "Android device registered: ~A" device-id)
  t)

(defun android-unregister-device (channel device-id)
  "Unregister an Android device.

  Args:
    CHANNEL: Android channel instance
    DEVICE-ID: Device identifier

  Returns:
    T on success"
  (when (gethash device-id (android-device-tokens channel))
    (remhash device-id (android-device-tokens channel))
    (log-info "Android device unregistered: ~A" device-id)
    t))

(defun android-get-device-info (channel device-id)
  "Get device information.

  Args:
    CHANNEL: Android channel instance
    DEVICE-ID: Device identifier

  Returns:
    Device info plist or NIL"
  (gethash device-id (android-device-tokens channel)))

(defun list-android-devices (channel)
  "List all registered devices.

  Args:
    CHANNEL: Android channel instance

  Returns:
    List of device info plists"
  (let ((devices nil))
    (maphash (lambda (id info)
               (push (list :id id
                           :token (getf info :token)
                           :user-id (getf info :user-id)
                           :registered-at (getf info :registered-at))
                     devices))
             (android-device-tokens channel))
    devices))

;;; ============================================================================
;;; Message Handling
;;; ============================================================================

(defun handle-android-message (channel message)
  "Handle an incoming Android message.

  Args:
    CHANNEL: Android channel instance
    MESSAGE: Message object

  Returns:
    Handler result"
  (log-info "Android message received: ~A" message)
  (dispatch-message channel message))

(defun register-android-handler (channel event-type handler)
  "Register an Android message handler.

  Args:
    CHANNEL: Android channel instance
    EVENT-TYPE: Event type to handle
    HANDLER: Handler function

  Returns:
    T"
  (register-message-handler channel event-type handler))

;;; ============================================================================
;;; Message Sending
;;; ============================================================================

(defmethod channel-send-message ((channel android-channel) recipient message &rest args &key &allow-other-keys)
  "Send a message to an Android device.

  Args:
    CHANNEL: Android channel instance
    RECIPIENT: Device ID or token
    MESSAGE: Message content
    ARGS: Additional arguments

  Returns:
    T on success"
  (let ((device-info (gethash recipient (android-device-tokens channel))))
    (if device-info
        (let ((token (getf device-info :token)))
          (fcm-send-message channel token message))
        ;; If no device info, try using recipient as token directly
        (fcm-send-message channel recipient message))))

(defmethod channel-receive-message ((channel android-channel) &key timeout)
  "Receive a message from Android.

  Args:
    CHANNEL: Android channel instance
    TIMEOUT: Timeout in seconds

  Returns:
    Message or NIL"
  (declare (ignore timeout))
  ;; In a full implementation, this would poll for messages
  ;; or use a WebSocket connection for real-time updates
  (log-debug "Android channel receive called (no messages pending)")
  nil)

;;; ============================================================================
;;; ADB Integration (for local debugging)
;;; ============================================================================

(defun adb-command (device command &key timeout)
  "Execute an ADB command.

  Args:
    DEVICE: Device ID
    COMMAND: ADB command
    TIMEOUT: Timeout in seconds

  Returns:
    Command output or NIL"
  (let ((cmd (format nil "adb -s ~A ~A" device command)))
    (handler-case
        (let ((output (uiop:run-program cmd :output :string)))
          (log-debug "ADB output: ~A" output)
          output)
      (error (e)
        (log-error "ADB command failed: ~A" e)
        nil))))

(defun adb-send-message (device package message)
  "Send message via ADB.

  Args:
    DEVICE: Device ID
    PACKAGE: App package name
    MESSAGE: Message content

  Returns:
    T on success"
  (let ((cmd (format nil "shell am broadcast -a ~A --es message \"~A\""
                     (format nil "~A.MESSAGE" package)
                     message)))
    (adb-command device cmd)))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-android-channel (&key package-name fcm-server-key fcm-sender-id config)
  "Initialize the Android channel.

  Args:
    PACKAGE-NAME: Android package name
    FCM-SERVER-KEY: FCM server key
    FCM-SENDER-ID: FCM sender ID
    CONFIG: Additional configuration

  Returns:
    Android channel instance"
  (let ((channel (make-android-channel
                  :package-name package-name
                  :fcm-server-key fcm-server-key
                  :fcm-sender-id fcm-sender-id
                  :config config)))
    (channel-connect channel)
    channel))
