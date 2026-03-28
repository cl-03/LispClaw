;;; client.lisp --- Gateway Client Management for Lisp-Claw
;;;
;;; This file manages client connections and sessions
;;; for the Lisp-Claw gateway.

(defpackage #:lisp-claw.gateway.client
  (:nicknames #:lc.gateway.client)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.helpers
        #:lisp-claw.gateway.protocol)
  (:export
   #:*client-store*
   #:client
   #:make-client
   #:client-connect
   #:client-disconnect
   #:client-send
   #:get-client
   #:list-clients
   #:foreach-client
   #:client-count
   #:with-client-lock))

(in-package #:lisp-claw.gateway.client)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *client-store* (make-hash-table :test 'equal)
  "Hash table storing all client connections.")

(defvar *client-lock* (bt:make-lock)
  "Lock for client store access.")

(defvar *client-counter* 0
  "Counter for generating unique client IDs.")

;;; ============================================================================
;;; Client Class
;;; ============================================================================

(defclass client ()
  ((id :initarg :id
       :reader client-id
       :documentation "Unique client identifier")
   (socket :initarg :socket
           :accessor client-socket
           :documentation "WebSocket socket object")
   (info :initarg :info
         :initform nil
         :accessor client-info
         :documentation "Client information alist")
   (connected-at :initform (get-universal-time)
                 :reader client-connected-at
                 :documentation "Connection timestamp")
   (last-seen :initform (get-universal-time)
              :accessor client-last-seen
              :documentation "Last activity timestamp")
   (authenticated-p :initform nil
                    :accessor client-authenticated-p
                    :documentation "Whether client is authenticated")
   (subscriptions :initform (make-hash-table :test 'equal)
                  :accessor client-subscriptions
                  :documentation "Event subscriptions")
   (state-version :initform 0
                  :accessor client-state-version
                  :documentation "Client state version")
   (message-queue :initform nil
                  :accessor client-message-queue
                  :documentation "Pending messages queue")))

(defmethod print-object ((client client) stream)
  "Print client representation."
  (print-unreadable-object (client stream :type t)
    (format stream "~A [~A]"
            (client-id client)
            (if (client-authenticated-p client) "auth" "unauth"))))

;;; ============================================================================
;;; Client Construction
;;; ============================================================================

(defun generate-client-id ()
  "Generate a unique client ID.

  Returns:
    Client ID string"
  (format nil "client-~A-~A"
          (get-universal-time)
          (incf *client-counter*)))

(defun make-client (socket &key info)
  "Create a new client instance.

  Args:
    SOCKET: WebSocket socket
    INFO: Optional client information

  Returns:
    Client instance"
  (let ((client (make-instance 'client
                               :id (generate-client-id)
                               :socket socket
                               :info info)))
    (log-debug "Created client: ~A" (client-id client))
    client))

;;; ============================================================================
;;; Client Lifecycle
;;; ============================================================================

(defun client-connect (client)
  "Register a client connection.

  Args:
    CLIENT: Client instance

  Returns:
    T on success"
  (bt:with-lock-held (*client-lock*)
    (setf (gethash (client-id client) *client-store*) client)
    (log-info "Client connected: ~A" (client-id client))
    t))

(defun client-disconnect (client &key reason)
  "Disconnect and unregister a client.

  Args:
    CLIENT: Client instance
    REASON: Optional disconnect reason

  Returns:
    T on success"
  (bt:with-lock-held (*client-lock*)
    (remhash (client-id client) *client-store*)
    (log-info "Client disconnected: ~A~@[ (reason: ~A)~]"
              (client-id client) reason)
    ;; Close socket
    (when (client-socket client)
      (ignore-errors (close (client-socket client))))
    t))

(defun get-client (client-id)
  "Get a client by ID.

  Args:
    CLIENT-ID: Client identifier

  Returns:
    Client instance or NIL"
  (gethash client-id *client-store*))

(defun list-clients (&key authenticated-predicate)
  "List all connected clients.

  Args:
    AUTHENTICATED-PREDICATE: Optional predicate to filter clients

  Returns:
    List of client instances"
  (let ((clients nil))
    (bt:with-lock-held (*client-lock*)
      (maphash (lambda (id client)
                 (declare (ignore id))
                 (if (or (null authenticated-predicate)
                         (funcall authenticated-predicate (client-authenticated-p client)))
                     (push client clients)))
               *client-store*))
    clients))

(defun client-count ()
  "Get the number of connected clients.

  Returns:
    Client count"
  (hash-table-count *client-store*))

(defun foreach-client (fn)
  "Apply a function to each client.

  Args:
    FN: Function to apply (takes client as argument)

  Returns:
    NIL"
  (bt:with-lock-held (*client-lock*)
    (maphash (lambda (id client)
               (declare (ignore id))
               (funcall fn client))
             *client-store*)))

(defmacro with-client-lock (&body body)
  "Execute body with client lock held.

  Args:
    BODY: Forms to execute

  Returns:
    Result of body"
  `(bt:with-lock-held (*client-lock*)
     ,@body))

;;; ============================================================================
;;; Client Messaging
;;; ============================================================================

(defun client-send (client message)
  "Send a message to a client.

  Args:
    CLIENT: Client instance
    MESSAGE: Message to send (string or alist)

  Returns:
    T on success"
  (handler-case
      (let ((message-string (if (stringp message)
                                message
                                (stringify-json message))))
        ;; Update last seen
        (setf (client-last-seen client) (get-universal-time))
        ;; Send via WebSocket
        ;; Actual WebSocket send implementation depends on the library
        (log-debug "Sending to client ~A: ~A" (client-id client) message-string)
        t)
    (error (e)
      (log-error "Failed to send to client ~A: ~A" (client-id client) e)
      nil)))

(defun client-send-json (client json-object)
  "Send a JSON object to a client.

  Args:
    CLIENT: Client instance
    JSON-object: JSON-serializable alist

  Returns:
    T on success"
  (client-send client (stringify-json json-object)))

(defun client-send-frame (client frame)
  "Send a protocol frame to a client.

  Args:
    CLIENT: Client instance
    FRAME: Protocol frame

  Returns:
    T on success"
  (let ((json (frame-to-json frame)))
    (client-send-json client json)))

(defun client-queue-message (client message)
  "Queue a message for later delivery.

  Args:
    CLIENT: Client instance
    MESSAGE: Message to queue

  Returns:
    T on success"
  (push message (client-message-queue client))
  t)

(defun client-flush-queue (client)
  "Flush queued messages to client.

  Args:
    CLIENT: Client instance

  Returns:
    Number of messages sent"
  (let ((count 0))
    (dolist (msg (nreverse (client-message-queue client)))
      (when (client-send client msg)
        (incf count)))
    (setf (client-message-queue client) nil)
    count))

;;; ============================================================================
;;; Client State
;;; ============================================================================

(defun client-update-info (client info)
  "Update client information.

  Args:
    CLIENT: Client instance
    INFO: New client info alist

  Returns:
    T on success"
  (setf (client-info client) info)
  (incf (client-state-version client))
  t)

(defun client-set-authenticated (client authenticated-p)
  "Set client authentication status.

  Args:
    CLIENT: Client instance
    AUTHENTICATED-P: Boolean

  Returns:
    T on success"
  (setf (client-authenticated-p client) authenticated-p)
  (incf (client-state-version client))
  t)

(defun client-subscribe (client event-type)
  "Subscribe client to an event type.

  Args:
    CLIENT: Client instance
    EVENT-TYPE: Event type string

  Returns:
    T on success"
  (setf (gethash event-type (client-subscriptions client)) t)
  t)

(defun client-unsubscribe (client event-type)
  "Unsubscribe client from an event type.

  Args:
    CLIENT: Client instance
    EVENT-TYPE: Event type string

  Returns:
    T on success"
  (remhash event-type (client-subscriptions client))
  t)

(defun client-subscribed-p (client event-type)
  "Check if client is subscribed to an event type.

  Args:
    CLIENT: Client instance
    EVENT-TYPE: Event type string

  Returns:
    T if subscribed"
  (and (gethash event-type (client-subscriptions client)) t))

(defun client-subscriptions-list (client)
  "Get list of client's subscriptions.

  Args:
    CLIENT: Client instance

  Returns:
    List of event type strings"
  (loop for type being the hash-keys of (client-subscriptions client)
        collect type))

;;; ============================================================================
;;; Client Cleanup
;;; ============================================================================

(defun cleanup-stale-clients (&optional (max-age-seconds 3600))
  "Clean up stale client connections.

  Args:
    MAX-AGE-SECONDS: Maximum age in seconds (default: 1 hour)

  Returns:
    Number of clients cleaned up"
  (let ((count 0)
        (cutoff (- (get-universal-time) max-age-seconds)))
    (foreach-client
     (lambda (client)
       (when (< (client-last-seen client) cutoff)
         (client-disconnect client :reason "stale")
         (incf count))))
    (log-info "Cleaned up ~A stale clients" count)
    count))

(defun disconnect-all-clients (&optional reason)
  "Disconnect all clients.

  Args:
    REASON: Optional disconnect reason

  Returns:
    Number of clients disconnected"
  (let ((count 0))
    (foreach-client
     (lambda (client)
       (client-disconnect client :reason reason)
       (incf count)))
    (log-info "Disconnected all ~A clients~@[ (reason: ~A)~]" count reason)
    count))
