;;; registry.lisp --- Channel Registry for Lisp-Claw
;;;
;;; This file implements the channel registry that manages
;;; all available messaging channels.

(defpackage #:lisp-claw.channels.registry
  (:nicknames #:lc.channels.registry)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.channels.base)
  (:export
   #:*channel-registry*
   #:register-channel-type
   #:unregister-channel-type
   #:get-channel-type
   #:list-channel-types
   #:create-channel
   #:get-channel
   #:list-channels
   #:start-all-channels
   #:stop-all-channels
   #:stop-channel))

(in-package #:lisp-claw.channels.registry)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *channel-registry* (make-hash-table :test 'equal)
  "Registry of channel types to constructor functions.")

(defvar *active-channels* (make-hash-table :test 'equal)
  "Hash table of active channel instances.
   Key: channel instance ID, Value: channel instance")

(defvar *channel-lock* (bt:make-lock)
  "Lock for channel registry access.")

;;; ============================================================================
;;; Channel Type Registration
;;; ============================================================================

(defun register-channel-type (channel-type constructor)
  "Register a channel type with its constructor.

  Args:
    CHANNEL-TYPE: Channel type symbol or string
    CONSTRUCTOR: Function that creates channel instances

  Returns:
    T on success"
  (bt:with-lock-held (*channel-lock*)
    (setf (gethash (string channel-type) *channel-registry*) constructor)
    (log-info "Registered channel type: ~A" channel-type)
    t))

(defun unregister-channel-type (channel-type)
  "Unregister a channel type.

  Args:
    CHANNEL-TYPE: Channel type symbol or string

  Returns:
    T on success"
  (bt:with-lock-held (*channel-lock*)
    (remhash (string channel-type) *channel-registry*)
    (log-info "Unregistered channel type: ~A" channel-type)
    t))

(defun get-channel-type (channel-type)
  "Get constructor for a channel type.

  Args:
    CHANNEL-TYPE: Channel type symbol or string

  Returns:
    Constructor function or NIL"
  (gethash (string channel-type) *channel-registry*))

(defun list-channel-types ()
  "List all registered channel types.

  Returns:
    List of channel type strings"
  (loop for type being the hash-keys of *channel-registry*
        collect type))

(defun channel-type-registered-p (channel-type)
  "Check if a channel type is registered.

  Args:
    CHANNEL-TYPE: Channel type symbol or string

  Returns:
    T if registered"
  (and (gethash (string channel-type) *channel-registry*) t))

;;; ============================================================================
;;; Channel Instance Management
;;; ============================================================================

(defun create-channel (channel-type &key config id)
  "Create a new channel instance.

  Args:
    CHANNEL-TYPE: Type of channel to create
    CONFIG: Channel configuration
    ID: Optional instance ID (generated if NIL)

  Returns:
    Channel instance or NIL if type not found"
  (let ((constructor (get-channel-type channel-type)))
    (unless constructor
      (log-error "Unknown channel type: ~A" channel-type)
      (return-from create-channel nil))

    (let* ((instance-id (or id (format nil "~A-~A"
                                        channel-type
                                        (get-universal-time))))
           (channel (funcall constructor :config config)))
      ;; Store channel instance
      (bt:with-lock-held (*channel-lock*)
        (setf (gethash instance-id *active-channels*) channel))
      (log-info "Created channel instance: ~A" instance-id)
      channel)))

(defun get-channel (channel-id)
  "Get a channel instance by ID.

  Args:
    CHANNEL-ID: Channel instance ID

  Returns:
    Channel instance or NIL"
  (gethash channel-id *active-channels*))

(defun list-channels (&key type status)
  "List active channel instances.

  Args:
    TYPE: Optional filter by channel type
    STATUS: Optional filter by status

  Returns:
    List of channel instances"
  (let ((channels nil))
    (bt:with-lock-held (*channel-lock*)
      (maphash (lambda (id channel)
                 (declare (ignore id))
                 (when (and (or (null type)
                                (equal (channel-name channel) type))
                            (or (null status)
                                (equal (channel-status channel) status)))
                   (push channel channels)))
               *active-channels*))
    channels))

(defun remove-channel (channel-id)
  "Remove a channel instance.

  Args:
    CHANNEL-ID: Channel instance ID

  Returns:
    T on success"
  (bt:with-lock-held (*channel-lock*)
    (let ((channel (gethash channel-id *active-channels*)))
      (when channel
        (channel-disconnect channel)
        (remhash channel-id *active-channels*)
        (log-info "Removed channel instance: ~A" channel-id)
        t))))

;;; ============================================================================
;;; Channel Lifecycle
;;; ============================================================================

(defun start-channel (channel)
  "Start a channel (connect).

  Args:
    CHANNEL: Channel instance

  Returns:
    T on success"
  (handler-case
      (progn
        (log-info "Starting channel: ~A" (channel-name channel))
        (channel-connect channel)
        (when (channel-connected-p channel)
          (log-info "Channel started: ~A" (channel-name channel))
          t))
    (channel-error (e)
      (log-error "Failed to start channel ~A: ~A"
                 (channel-name channel) e)
      (setf (channel-last-error channel) e)
      (incf (channel-error-count channel))
      nil)))

(defun stop-channel (channel)
  "Stop a channel (disconnect).

  Args:
    CHANNEL: Channel instance

  Returns:
    T on success"
  (log-info "Stopping channel: ~A" (channel-name channel))
  (channel-disconnect channel)
  (log-info "Channel stopped: ~A" (channel-name channel))
  t)

(defun start-all-channels ()
  "Start all registered channels.

  Returns:
    Number of channels started successfully"
  (let ((count 0))
    (maphash (lambda (id channel)
               (declare (ignore id))
               (when (start-channel channel)
                 (incf count)))
             *active-channels*)
    (log-info "Started ~A channels" count)
    count))

(defun stop-all-channels ()
  "Stop all active channels.

  Returns:
    Number of channels stopped"
  (let ((count 0))
    (maphash (lambda (id channel)
               (declare (ignore id))
               (when (stop-channel channel)
                 (incf count)))
             *active-channels*)
    (log-info "Stopped ~A channels" count)
    count))

;;; ============================================================================
;;; Channel Configuration
;;; ============================================================================

(defun configure-channel (channel-id config)
  "Update channel configuration.

  Args:
    CHANNEL-ID: Channel instance ID
    CONFIG: New configuration

  Returns:
    T on success"
  (let ((channel (get-channel channel-id)))
    (unless channel
      (log-error "Channel not found: ~A" channel-id)
      (return-from configure-channel nil))

    (setf (slot-value channel 'config) config)
    (log-info "Updated channel config: ~A" channel-id)
    t))

(defun get-channel-config (channel-id)
  "Get channel configuration.

  Args:
    CHANNEL-ID: Channel instance ID

  Returns:
    Configuration alist or NIL"
  (let ((channel (get-channel channel-id)))
    (when channel
      (channel-config channel))))

;;; ============================================================================
;;; Channel Status
;;; ============================================================================

(defun get-channel-status (channel-id)
  "Get channel status.

  Args:
    CHANNEL-ID: Channel instance ID

  Returns:
    Status alist"
  (let ((channel (get-channel channel-id)))
    (unless channel
      (return-from get-channel-status nil))

    `((:id . ,channel-id)
      (:name . ,(channel-name channel))
      (:status . ,(channel-status channel))
      (:connected-p . ,(channel-connected-p channel))
      (:message-count . ,(channel-message-count channel))
      (:error-count . ,(channel-error-count channel))
      (:last-error . ,(channel-last-error channel))
      (:connect-time . ,(channel-connect-time channel)))))

(defun get-all-statuses ()
  "Get status of all channels.

  Returns:
    List of status alists"
  (loop for channel in (list-channels)
        for status = (get-channel-status
                      (format nil "~A" (channel-name channel)))
        collect status))

;;; ============================================================================
;;; Channel Health
;;; ============================================================================

(defun check-channel-health (channel)
  "Check health of a channel.

  Args:
    CHANNEL: Channel instance

  Returns:
    (values ok message)"
  (cond
    ((not (channel-connected-p channel))
     (values nil "Not connected"))
    ((> (channel-error-count channel) 10)
     (values nil (format nil "High error count: ~A"
                         (channel-error-count channel))))
    (t
     (values t "Healthy"))))

(defun check-all-channel-health ()
  "Check health of all channels.

  Returns:
    Alist of channel health results"
  (loop for channel in (list-channels)
        for id = (format nil "~A" (channel-name channel))
        for (ok message) = (multiple-value-list
                            (check-channel-health channel))
        collect (cons id (list :ok ok :message message))))
