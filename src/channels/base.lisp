;;; base.lisp --- Channel Base Class for Lisp-Claw
;;;
;;; This file defines the base class and interface for all
;;; messaging channels in Lisp-Claw.

(defpackage #:lisp-claw.channels.base
  (:nicknames #:lc.channels.base)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging)
  (:export
   #:channel
   #:channel-name
   #:channel-connected-p
   #:channel-config
   #:channel-status
   #:make-channel
   #:channel-connect
   #:channel-disconnect
   #:channel-send-message
   #:channel-receive-message
   #:channel-get-group-info
   #:channel-get-user-info
   #:channel-unsupported-error))

(in-package #:lisp-claw.channels.base)

;;; ============================================================================
;;; Channel Base Class
;;; ============================================================================

(defclass channel ()
  ((name :initarg :name
         :initform nil
         :reader channel-name
         :documentation "Channel type name (e.g., \"telegram\", \"discord\")")
   (config :initarg :config
           :initform nil
           :reader channel-config
           :documentation "Channel configuration alist")
   (connected-p :initform nil
                :accessor channel-connected-p
                :documentation "Whether channel is connected")
   (status :initform :disconnected
           :accessor channel-status
           :documentation "Channel status keyword")
   (last-error :initform nil
               :accessor channel-last-error
               :documentation "Last error that occurred")
   (connect-time :initform nil
                 :accessor channel-connect-time
                 :documentation "Time when channel was connected")
   (message-count :initform 0
                  :accessor channel-message-count
                  :documentation "Number of messages processed")
   (error-count :initform 0
               :accessor channel-error-count
               :documentation "Number of errors that occurred")
   (handlers :initform (make-hash-table :test 'equal)
             :accessor channel-handlers
             :documentation "Message handlers registry")))

(defmethod print-object ((channel channel) stream)
  "Print channel representation."
  (print-unreadable-object (channel stream :type t)
    (format stream "~A [~A]"
            (or (channel-name channel) "unknown")
            (channel-status channel))))

;;; ============================================================================
;;; Channel Construction
;;; ============================================================================

(defun make-channel (channel-type &key config)
  "Create a new channel instance.

  Args:
    CHANNEL-TYPE: Type of channel to create
    CONFIG: Channel configuration

  Returns:
    Channel instance

  Note: This is a factory function that should be extended by
        specific channel implementations."
  (let ((channel (make-instance 'channel
                                :name channel-type
                                :config config)))
    (log-info "Created channel: ~A" channel-type)
    channel))

;;; ============================================================================
;;; Channel Interface (To be implemented by subclasses)
;;; ============================================================================

(defgeneric channel-connect (channel)
  "Connect the channel.

  Args:
    CHANNEL: Channel instance

  Returns:
    T on success, NIL on failure

  Note: Subclasses must implement this method."
  (:method ((channel channel))
    (declare (ignore channel))
    (error 'channel-unsupported-error
           :operation 'connect
           :message "channel-connect not implemented")))

(defgeneric channel-disconnect (channel)
  "Disconnect the channel.

  Args:
    CHANNEL: Channel instance

  Returns:
    T on success"
  (:method ((channel channel))
    (setf (channel-connected-p channel) nil)
    (setf (channel-status channel) :disconnected)
    (log-info "Channel disconnected: ~A" (channel-name channel))
    t))

(defgeneric channel-send-message (channel recipient message &key options)
  "Send a message through the channel.

  Args:
    CHANNEL: Channel instance
    RECIPIENT: Message recipient (channel-specific format)
    MESSAGE: Message content (string or structured)
    OPTIONS: Optional sending options

  Returns:
    Message ID on success, NIL on failure"
  (:method ((channel channel) recipient message &key options)
    (declare (ignore recipient message options))
    (error 'channel-unsupported-error
           :operation 'send-message
           :message "channel-send-message not implemented")))

(defgeneric channel-receive-message (channel &key timeout)
  "Receive a message from the channel.

  Args:
    CHANNEL: Channel instance
    TIMEOUT: Optional timeout in seconds

  Returns:
    Message object or NIL"
  (:method ((channel channel) &key timeout)
    (declare (ignore timeout))
    (error 'channel-unsupported-error
           :operation 'receive-message
           :message "channel-receive-message not implemented")))

(defgeneric channel-get-group-info (channel group-id)
  "Get information about a group.

  Args:
    CHANNEL: Channel instance
    GROUP-ID: Group identifier

  Returns:
    Group info alist"
  (:method ((channel channel) group-id)
    (declare (ignore group-id))
    (error 'channel-unsupported-error
           :operation 'get-group-info
           :message "channel-get-group-info not implemented")))

(defgeneric channel-get-user-info (channel user-id)
  "Get information about a user.

  Args:
    CHANNEL: Channel instance
    USER-ID: User identifier

  Returns:
    User info alist"
  (:method ((channel channel) user-id)
    (declare (ignore user-id))
    (error 'channel-unsupported-error
           :operation 'get-user-info
           :message "channel-get-user-info not implemented")))

;;; ============================================================================
;;; Channel Utilities
;;; ============================================================================

(defun channel-enabled-p (channel)
  "Check if channel is enabled in config.

  Args:
    CHANNEL: Channel instance

  Returns:
    T if enabled"
  (let ((config (channel-config channel)))
    (and config (equal (cdr (assoc :enabled config)) t))))

(defun register-message-handler (channel event-type handler)
  "Register a message handler.

  Args:
    CHANNEL: Channel instance
    EVENT-TYPE: Type of event to handle
    HANDLER: Handler function

  Returns:
    T on success"
  (setf (gethash event-type (channel-handlers channel)) handler)
  (log-debug "Registered handler for ~A: ~A"
             (channel-name channel) event-type)
  t)

(defun unregister-message-handler (channel event-type)
  "Unregister a message handler.

  Args:
    CHANNEL: Channel instance
    EVENT-TYPE: Event type

  Returns:
    T on success"
  (remhash event-type (channel-handlers channel))
  t)

(defun dispatch-message (channel message)
  "Dispatch a received message to appropriate handlers.

  Args:
    CHANNEL: Channel instance
    MESSAGE: Received message

  Returns:
    Handler result or NIL"
  (let* ((event-type (get-message-type message))
         (handler (gethash event-type (channel-handlers channel))))
    (if handler
        (handler-case
            (funcall handler channel message)
          (error (e)
            (log-error "Handler error for ~A: ~A" event-type e)
            (incf (channel-error-count channel))
            (setf (channel-last-error channel) e)
            nil))
        (progn
          (log-debug "No handler for event type: ~A" event-type)
          nil))))

(defun get-message-type (message)
  "Extract event type from a message.

  Args:
    MESSAGE: Message object

  Returns:
    Event type string"
  (etypecase message
    (string "message")
    (alist (or (cdr (assoc :type message)) "message"))))

;;; ============================================================================
;;; Message helpers
;;; ============================================================================

(defun make-message (&key id channel-id sender content timestamp type attachments)
  "Create a standardized message object.

  Args:
    ID: Message ID
    CHANNEL-ID: Channel/group ID
    SENDER: Sender info
    CONTENT: Message content
    TIMESTAMP: Message timestamp
    TYPE: Message type
    ATTACHMENTS: Optional attachments

  Returns:
    Message alist"
  `((:id . ,id)
    (:channel-id . ,channel-id)
    (:sender . ,sender)
    (:content . ,content)
    (:timestamp . ,timestamp)
    (:type . ,type)
    ,@(when attachments `((:attachments . ,attachments)))))

(defun message-text (message)
  "Get text content from a message.

  Args:
    MESSAGE: Message object

  Returns:
    Text content"
  (etypecase message
    (string message)
    (alist (or (cdr (assoc :content message))
               (cdr (assoc :text message))
               ""))))

(defun message-sender (message)
  "Get sender info from a message.

  Args:
    MESSAGE: Message object

  Returns:
    Sender info"
  (etypecase message
    (string nil)
    (alist (or (cdr (assoc :sender message))
               (cdr (assoc :from message))))))

(defun message-id (message)
  "Get message ID.

  Args:
    MESSAGE: Message object

  Returns:
    Message ID"
  (etypecase message
    (string nil)
    (alist (or (cdr (assoc :id message))
               (cdr (assoc :message-id message))))))

;;; ============================================================================
;;; Channel Conditions
;;; ============================================================================

(define-condition channel-error (error)
  ((channel :initarg :channel :reader error-channel)
   (message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "Channel Error (~A): ~A"
                     (error-channel condition)
                     (error-message condition)))))

(define-condition channel-connection-error (channel-error)
  ((message :initform "Connection failed")))

(define-condition channel-send-error (channel-error)
  ((message :initform "Send failed")))

(define-condition channel-unsupported-error (channel-error)
  ((operation :initarg :operation :reader error-operation)
   (message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "Channel ~A unsupported: ~A"
                     (error-operation condition)
                     (error-message condition)))))

(define-condition channel-auth-error (channel-error)
  ((message :initform "Authentication failed")))

(define-condition channel-rate-limit-error (channel-error)
  ((retry-after :initarg :retry-after :reader error-retry-after)
   (message :initform "Rate limit exceeded")))
