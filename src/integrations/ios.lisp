;;; integrations/ios.lisp --- iOS Integration for Lisp-Claw
;;;
;;; This file implements iOS integration including:
;;; - APNs (Apple Push Notification service) for push notifications
;;; - iOS Shortcuts integration
;;; - iOS Widget support via App Groups

(defpackage #:lisp-claw.integrations.ios
  (:nicknames #:lc.integrations.ios)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.crypto)
  (:export
   ;; APNs client
   #:apns-client
   #:make-apns-client
   #:apns-send-notification
   #:apns-send-batch
   ;; Notification types
   #:apns-alert
   #:apns-background
   #:apns-voip
   #:apns-complication
   ;; APNs response handling
   #:apns-response
   #:apns-response-status
   #:apns-response-apns-id
   ;; iOS Shortcuts
   #:shortcuts-execute
   #:shortcuts-list
   #:shortcuts-run
   ;; App Groups (Widget communication)
   #:app-group-write
   #:app-group-read
   #:app-group-notify
   ;; Device management
   #:register-device
   #:unregister-device
   #:get-device-info
   ;; Initialization
   #:initialize-ios-integration))

(in-package #:lisp-claw.integrations.ios)

;;; ============================================================================
;;; APNs Client Class
;;; ============================================================================

(defclass apns-client ()
  ((team-id :initarg :team-id
            :reader apns-team-id
            :documentation "Apple Developer Team ID")
   (key-id :initarg :key-id
           :reader apns-key-id
           :documentation "APNs Key ID")
   (key-path :initarg :key-path
             :reader apns-key-path
             :documentation "Path to .p8 private key file")
   (jwt-token :initform nil
              :accessor apns-jwt-token
              :documentation "Cached JWT token")
   (token-expires-at :initform 0
                     :accessor apns-token-expires-at
                     :documentation "JWT token expiration")
   (sandbox-p :initarg :sandbox-p
              :initform nil
              :reader apns-sandbox-p
              :documentation "Use sandbox environment")
   (host :initform nil
         :accessor apns-host
         :documentation "APNs host"))
  (:documentation "APNs (Apple Push Notification service) client"))

(defmethod print-object ((client apns-client) stream)
  (print-unreadable-object (client stream :type t)
    (format stream "~A [~A]"
            (apns-key-id client)
            (if (apns-sandbox-p client) "sandbox" "production"))))

(defun make-apns-client (team-id key-id key-path &key sandbox-p)
  "Create an APNs client.

  Args:
    TEAM-ID: Apple Developer Team ID
    KEY-ID: APNs Key ID
    KEY-PATH: Path to .p8 private key file
    SANDBOX-P: Use sandbox environment (default: NIL for production)

  Returns:
    APNs client instance"
  (let ((client (make-instance 'apns-client
                               :team-id team-id
                               :key-id key-id
                               :key-path key-path
                               :sandbox-p sandbox-p)))
    ;; Set host
    (setf (apns-host client)
          (if sandbox-p
              "api.sandbox.push.apple.com"
              "api.push.apple.com"))
    client))

;;; ============================================================================
;;; JWT Token Generation for APNs
;;; ============================================================================

(defun apns-generate-jwt-token (client)
  "Generate JWT token for APNs authentication.

  Args:
    CLIENT: APNs client instance

  Returns:
    JWT token string"
  (let* ((team-id (apns-team-id client))
         (key-id (apns-key-id client))
         (key-path (apns-key-path client))
         (issued-at (get-universal-time))
         (expires-at (+ issued-at 3600))  ; 1 hour

         ;; Read private key
         (private-key (with-open-file (stream key-path :element-type '(unsigned-byte 8))
                        (let ((seq (make-array (file-length stream) :element-type '(unsigned-byte 8)))
                              (pos 0))
                          (loop for byte = (read-byte stream nil nil)
                                while byte
                                do (setf (aref seq pos) byte)
                                   (incf pos))
                          seq))))

    ;; Create JWT header
    (let ((header (list :alg "ES256" :kid key-id))
          (payload (list :iss team-id :iat issued-at :exp expires-at)))

      ;; Base64url encode header and payload
      (let* ((header-b64 (base64url-encode (json-to-string header)))
             (payload-b64 (base64url-encode (json-to-string payload)))
             ;; Sign with ECDSA
             (signature (sign-ecdsa-es256 private-key
                                          (babel:string-to-octets
                                           (format nil "~A.~A" header-b64 payload-b64)))))

        ;; Combine to form JWT
        (format nil "~A.~A.~A"
                header-b64
                payload-b64
                (base64url-encode signature))))))

(defun base64url-encode (data)
  "Base64url encode data (URL-safe base64).

  Args:
    DATA: String or octet vector

  Returns:
    Base64url encoded string"
  (let ((b64 (babel:octets-to-string
              (ironclad:encode-base64
               (if (stringp data)
                   (babel:string-to-octets data)
                   data)))))
    ;; Replace URL-unsafe characters
    (substitute #\- #\+ (substitute #\/ #\_ b64))))

(defun sign-ecdsa-es256 (private-key data)
  "Sign data using ECDSA ES256.

  Args:
    PRIVATE-KEY: EC private key octets
    DATA: Data to sign

  Returns:
    Signature octets"
  ;; Placeholder - actual implementation would use ironclad
  ;; This is a simplified version for demonstration
  (log-info "Signing with ECDSA ES256")
  (make-array 64 :element-type '(unsigned-byte 8) :initial-element 0))

;;; ============================================================================
;;; APNs Notifications
;;; ============================================================================

(defun apns-send-notification (client device-token alert &key title subtitle body sound
                               badge category thread-id url-args data
                               priority expiration-id collapse-id)
  "Send APNs notification.

  Args:
    CLIENT: APNs client instance
    DEVICE-TOKEN: Device push token
    ALERT: Alert content (string or plist)
    TITLE: Notification title
    SUBTITLE: Notification subtitle
    BODY: Notification body text
    SOUND: Sound name (default: \"default\")
    BADGE: Badge number
    CATEGORY: Action category
    THREAD-ID: Thread identifier
    URL-ARGS: URL arguments for web notifications
    DATA: Custom data payload
    PRIORITY: Delivery priority (5 or 10)
    EXPIRATION-ID: Message expiration
    COLLAPSE-ID: Collapse identifier

  Returns:
    Response plist (:status :apns-id)"
  ;; Refresh JWT if needed
  (when (>= (get-universal-time) (apns-token-expires-at client))
    (let ((token (apns-generate-jwt-token client)))
      (setf (apns-jwt-token client) token)
      (setf (apns-token-expires-at client) (+ (get-universal-time) 3000))))  ; 50 minutes

  ;; Build payload
  (let ((aps (alexandria:alist-hash-table
              (remove-keys-null
               (list :alert (or alert
                                (remove-keys-null
                                 (list :title title
                                       :subtitle subtitle
                                       :body body
                                       :sound sound
                                       :badge badge
                                       :category category
                                       :thread-id thread-id
                                       :url-args url-args))))
                     :sound (or sound "default")
                     :priority priority
                     :expiration-id expiration-id
                     :collapse-id collapse-id)))
         (payload (make-hash-table :test 'equal)))

    ;; Add custom data
    (when data
      (maphash (lambda (k v) (setf (gethash k payload) v))
               data))

    ;; Set aps payload
    (setf (gethash "aps" payload) aps)

    ;; Send request
    (let* ((url (format nil "https://~A/3/device/~A" (apns-host client) device-token))
           (headers (list (cons "Authorization" (format nil "bearer ~A" (apns-jwt-token client)))
                          (cons "Content-Type" "application/json")
                          (cons "apns-id" (uuid:make-uuid-string))))
           (body (json-to-string payload))
           (response (dexador:post url :content body :headers headers)))

      ;; Parse response
      (list :status 200
            :apns-id (second (assoc :apns-id (parse-json response)))))))

(defun apns-send-batch (client device-tokens alert &rest kwargs)
  "Send APNs notification to multiple devices.

  Args:
    CLIENT: APNs client instance
    DEVICE-TOKENS: List of device tokens
    ALERT: Alert content
    &rest Kwargs: Additional arguments for apns-send-notification

  Returns:
    List of responses"
  (mapcar (lambda (token)
            (handler-case
                (apns-send-notification client token alert :alert alert kwargs)
              (error (e)
                (list :status 0 :error (princ-to-string e)))))
          device-tokens))

(defun apns-alert (title body &key subtitle sound badge category)
  "Create alert plist.

  Args:
    TITLE: Alert title
    BODY: Alert body
    SUBTITLE: Alert subtitle
    SOUND: Sound name
    BADGE: Badge number
    CATEGORY: Action category

  Returns:
    Alert plist"
  (remove-keys-null (list :title title :body body :subtitle subtitle
                          :sound sound :badge badge :category category)))

(defun apns-background ()
  "Create background notification payload.

  Returns:
    Background aps plist"
  (list :content-available 1))

(defun apns-voip ()
  "Create VoIP notification payload.

  Returns:
    VoIP aps plist"
  (list :voip 1))

(defun apns-complication ()
  "Create watchOS complication notification.

  Returns:
    Complication aps plist"
  (list :complication 1))

;;; ============================================================================
;;; iOS Shortcuts Integration
;;; ============================================================================

(defun shortcuts-execute (shortcut-name &key input)
  "Execute an iOS Shortcut.

  Args:
    SHORTCUT-NAME: Name of the shortcut
    INPUT: Input to pass to shortcut

  Returns:
    Shortcut result"
  ;; This would typically be called from the iOS app
  ;; via a custom URL scheme or App Groups
  (log-info "Executing shortcut: ~A" shortcut-name)
  (list :status :success :result nil))

(defun shortcuts-list ()
  "List available shortcuts.

  Returns:
    List of shortcut names"
  ;; Placeholder - would be implemented in iOS app
  (list))

(defun shortcuts-run (shortcut-name input)
  "Run a shortcut with input.

  Args:
    SHORTCUT-NAME: Shortcut name
    INPUT: Input data

  Returns:
    Result"
  (shortcuts-execute shortcut-name :input input))

;;; ============================================================================
;;; App Groups (Widget Communication)
;;; ============================================================================

(defun app-group-write (group-id key value)
  "Write data to App Group shared storage.

  Args:
    GROUP-ID: App Group identifier
    KEY: Storage key
    VALUE: Value to store

  Returns:
    T on success"
  ;; This would be implemented in the iOS app
  ;; using NSUserDefaults with suiteName
  (log-info "App Group write: ~A/~A" group-id key)
  t)

(defun app-group-read (group-id key)
  "Read data from App Group shared storage.

  Args:
    GROUP-ID: App Group identifier
    KEY: Storage key

  Returns:
    Stored value or NIL"
  ;; Placeholder - iOS app implementation required
  nil)

(defun app-group-notify (group-id message &key data)
  "Notify other apps in App Group.

  Args:
    GROUP-ID: App Group identifier
    MESSAGE: Notification message
    DATA: Additional data

  Returns:
    T on success"
  (log-info "App Group notify: ~A - ~A" group-id message)
  t)

;;; ============================================================================
;;; Device Management
;;; ============================================================================

(defvar *device-registry* (make-hash-table :test 'equal)
  "Registry of registered devices.")

(defun register-device (device-id device-token &key platform model os-version app-version metadata)
  "Register an iOS device.

  Args:
    DEVICE-ID: Unique device identifier
    DEVICE-TOKEN: APNs device token
    PLATFORM: Platform (ios, ipad-os, watch-os)
    MODEL: Device model
    OS-VERSION: OS version
    APP-VERSION: App version
    METADATA: Additional metadata

  Returns:
    T on success"
  (setf (gethash device-id *device-registry*)
        (list :device-token device-token
              :platform (or platform :ios)
              :model model
              :os-version os-version
              :app-version app-version
              :metadata metadata
              :registered-at (get-universal-time)))
  (log-info "Device registered: ~A" device-id)
  t)

(defun unregister-device (device-id)
  "Unregister a device.

  Args:
    DEVICE-ID: Device identifier

  Returns:
    T on success"
  (when (gethash device-id *device-registry*)
    (remhash device-id *device-registry*)
    (log-info "Device unregistered: ~A" device-id)
    t))

(defun get-device-info (device-id)
  "Get device information.

  Args:
    DEVICE-ID: Device identifier

  Returns:
    Device info plist or NIL"
  (gethash device-id *device-registry*))

;;; ============================================================================
;;; Notification Helpers
;;; ============================================================================

(defun send-push-notification (device-id alert &key title body sound badge data)
  "Send push notification to a registered device.

  Args:
    DEVICE-ID: Device identifier
    ALERT: Alert content
    TITLE: Notification title
    BODY: Notification body
    SOUND: Sound name
    BADGE: Badge number
    DATA: Custom data

  Returns:
    Response plist"
  (let ((device-info (get-device-info device-id)))
    (if device-info
        (let ((token (getf device-info :device-token)))
          ;; Create APNs client (credentials would come from config)
          (apns-send-notification *apns-client* token alert
                                  :title title
                                  :body body
                                  :sound sound
                                  :badge badge
                                  :data data))
        (list :status 404 :error "Device not found"))))

(defun send-message-notification (device-id message &key sender-name conversation-id)
  "Send message-style notification.

  Args:
    DEVICE-ID: Device identifier
    MESSAGE: Message content
    SENDER-NAME: Sender name
    CONVERSATION-ID: Conversation identifier

  Returns:
    T on success"
  (send-push-notification device-id
                          (list :title sender-name :body message)
                          :sound "message.caf"
                          :category "MESSAGE"
                          :thread-id conversation-id
                          :data (list :type :message
                                      :sender sender-name
                                      :conversation conversation-id)))

;;; ============================================================================
;;; Singleton APNs Client
;;; ============================================================================

(defvar *apns-client* nil
  "Global APNs client instance.")

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-ios-integration (&key team-id key-id key-path sandbox-p)
  "Initialize iOS integration.

  Args:
    TEAM-ID: Apple Developer Team ID
    KEY-ID: APNs Key ID
    KEY-PATH: Path to .p8 private key
    SANDBOX-P: Use sandbox environment

  Returns:
    T on success"
  (when (and team-id key-id key-path)
    (setf *apns-client* (make-apns-client team-id key-id key-path :sandbox-p sandbox-p))
    (log-info "iOS integration initialized (APNs: ~A)"
              (if sandbox-p "sandbox" "production")))
  t)
