;;; events.lisp --- Gateway Event System for Lisp-Claw
;;;
;;; This file implements the event subscription and emission system
;;; for the Lisp-Claw gateway.

(defpackage #:lisp-claw.gateway.events
  (:nicknames #:lc.gateway.events)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.gateway.protocol)
  (:export
   #:*event-subscriptions*
   #:subscribe-event
   #:unsubscribe-event
   #:unsubscribe-all
   #:emit-event
   #:emit-to-subscribers
   #:get-event-history
   #:clear-event-history
   #:event-types))

(in-package #:lisp-claw.gateway.events)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *event-subscriptions* (make-hash-table :test 'equal)
  "Hash table of event subscriptions.
   Key: event-type, Value: list of (client-id . callback)")

(defvar *event-history* (make-array 1000 :fill-pointer 0 :adjustable t)
  "Circular buffer of recent events.")

(defvar *event-history-index* 0
  "Current index in event history buffer.")

(defvar *event-sequence* 0
  "Global event sequence counter.")

(defvar *event-history-lock* (bt:make-lock)
  "Lock for event history access.")

;;; ============================================================================
;;; Event Types
;;; ============================================================================

(defparameter +event-types+
  '(;; Agent events
    "agent"
    "agent.start"
    "agent.end"
    "agent.error"
    ;; Chat events
    "chat"
    "chat.message"
    "chat.typing"
    ;; Presence events
    "presence"
    "presence.online"
    "presence.offline"
    ;; System events
    "health"
    "heartbeat"
    "cron"
    ;; Node events
    "node"
    "node.connected"
    "node.disconnected"
    "node.invoke"
    ;; Channel events
    "channel"
    "channel.status"
    "channel.error")
  "List of all known event types.")

(defun event-types ()
  "Get list of all event types.

  Returns:
    List of event type strings"
  +event-types+)

;;; ============================================================================
;;; Subscription Management
;;; ============================================================================

(defun subscribe-event (event-type client-id &optional callback)
  "Subscribe to an event type.

  Args:
    EVENT-TYPE: Type of event to subscribe to
    CLIENT-ID: Client identifier
    CALLBACK: Optional callback function (NIL means queue events)

  Returns:
    T on success"
  (let ((subscription (cons client-id (or callback #'default-event-handler))))
    (bt:with-lock-held (*event-history-lock*)
      (push subscription (gethash event-type *event-subscriptions*)))
    (log-debug "Client ~A subscribed to event: ~A" client-id event-type)
    t))

(defun unsubscribe-event (event-type client-id)
  "Unsubscribe from an event type.

  Args:
    EVENT-TYPE: Type of event
    CLIENT-ID: Client identifier

  Returns:
    T if unsubscribed, NIL if not subscribed"
  (bt:with-lock-held (*event-history-lock*)
    (let ((subscriptions (gethash event-type *event-subscriptions*)))
      (when subscriptions
        (let ((new-subs (remove-if (lambda (sub)
                                     (equal (car sub) client-id))
                                   subscriptions)))
          (if new-subs
              (setf (gethash event-type *event-subscriptions*) new-subs)
              (remhash event-type *event-subscriptions*))
          (log-debug "Client ~A unsubscribed from event: ~A" client-id event-type)
          t)))))

(defun unsubscribe-all (client-id)
  "Unsubscribe a client from all events.

  Args:
    CLIENT-ID: Client identifier

  Returns:
    Number of subscriptions removed"
  (let ((count 0))
    (bt:with-lock-held (*event-history-lock*)
      (maphash (lambda (event-type subscriptions)
                 (let ((new-subs (remove-if (lambda (sub)
                                              (equal (car sub) client-id))
                                            subscriptions)))
                   (if new-subs
                       (setf (gethash event-type *event-subscriptions*) new-subs)
                       (remhash event-type *event-subscriptions*))
                   (incf count)))
               *event-subscriptions*))
    (log-debug "Client ~A unsubscribed from all events" client-id)
    count))

(defun get-subscribers (event-type)
  "Get list of subscribers for an event type.

  Args:
    EVENT-TYPE: Event type

  Returns:
    List of (client-id . callback) pairs"
  (gethash event-type *event-subscriptions*))

;;; ============================================================================
;;; Event Emission
;;; ============================================================================

(defun emit-event (event-type &key payload target-clients)
  "Emit an event to all subscribers.

  Args:
    EVENT-TYPE: Type of event
    PAYLOAD: Event payload (alist)
    TARGET-CLIENTS: Optional list of specific client IDs (NIL = broadcast)

  Returns:
    Number of subscribers notified"
  (let* ((seq (incf *event-sequence*))
         (timestamp (get-universal-time))
         (event-frame (make-event-frame event-type
                                        :payload payload
                                        :seq seq)))

    ;; Add to history
    (add-to-history event-type payload seq timestamp)

    ;; Get subscribers
    (let ((subscribers (if target-clients
                           ;; Filter to specific clients
                           (remove-if-not (lambda (sub)
                                            (member (car sub) target-clients))
                                          (gethash event-type *event-subscriptions*))
                           ;; All subscribers
                           (gethash event-type *event-subscriptions*))))

      ;; Notify subscribers
      (dolist (sub subscribers)
        (let ((client-id (car sub))
              (callback (cdr sub)))
          (funcall callback client-id event-frame)))

      (length subscribers))))

(defun emit-to-subscribers (event-type client-list payload)
  "Emit an event to specific clients.

  Args:
    EVENT-TYPE: Event type
    CLIENT-LIST: List of client IDs
    PAYLOAD: Event payload

  Returns:
    Number of clients notified"
  (emit-event event-type :payload payload :target-clients client-list))

(defun default-event-handler (client-id event-frame)
  "Default event handler that queues events for clients.

  Args:
    CLIENT-ID: Client identifier
    EVENT-FRAME: Event frame

  Returns:
    NIL"
  (declare (ignore client-id event-frame))
  ;; In a real implementation, this would queue the event
  ;; for later retrieval by the client
  nil)

;;; ============================================================================
;;; Event History
;;; ============================================================================

(defun add-to-history (event-type payload seq timestamp)
  "Add an event to the history buffer.

  Args:
    EVENT-TYPE: Event type
    PAYLOAD: Event payload
    SEQ: Sequence number
    TIMESTAMP: Event timestamp

  Returns:
    NIL"
  (bt:with-lock-held (*event-history-lock*)
    (let ((entry (list :type event-type
                       :payload payload
                       :seq seq
                       :timestamp timestamp)))
      ;; Adjust vector if needed
      (when (>= (length *event-history*) (array-total-size *event-history*))
        (adjust-array *event-history* (* 2 (array-total-size *event-history*))
                      :fill-pointer 0))
      ;; Add entry
      (vector-push-extend entry *event-history*)
      (incf *event-history-index*))))

(defun get-event-history (&key event-type since-seq limit)
  "Get event history.

  Args:
    EVENT-TYPE: Optional event type filter
    SINCE-SEQ: Optional sequence number to get events since
    LIMIT: Optional maximum number of events to return

  Returns:
    List of event entries"
  (bt:with-lock-held (*event-history-lock*)
    (let ((events (coerce *event-history* 'list)))
      (when event-type
        (setf events (remove-if-not (lambda (e)
                                      (equal (plist-get e :type) event-type))
                                    events)))
      (when since-seq
        (setf events (remove-if-not (lambda (e)
                                      (> (plist-get e :seq) since-seq))
                                    events)))
      (when limit
        (setf events (subseq events 0 (min limit (length events)))))
      (nreverse events))))

(defun clear-event-history ()
  "Clear the event history.

  Returns:
    T on success"
  (bt:with-lock-held (*event-history-lock*)
    (setf (fill-pointer *event-history*) 0)
    (setf *event-history-index* 0)
    (log-info "Event history cleared")
    t))

;;; ============================================================================
;;; Heartbeat
;;; ============================================================================

(defun start-heartbeat (&optional (interval-seconds 30))
  "Start heartbeat event emission.

  Args:
    INTERVAL-SECONDS: Heartbeat interval (default 30s)

  Returns:
    Thread object"
  (bt:make-thread
   (lambda ()
     (loop
       (sleep interval-seconds)
       (emit-event "heartbeat"
                   :payload `(:timestamp ,(get-universal-time)
                            :sequence ,*event-sequence*))))
   :name "lisp-claw-heartbeat"))

;;; ============================================================================
;;; Presence Tracking
;;; ============================================================================

(defun emit-presence-update (client-id status &key details)
  "Emit a presence update event.

  Args:
    CLIENT-ID: Client identifier
    STATUS: Presence status (:online, :offline, :away, etc.)
    DETAILS: Optional additional details

  Returns:
    T on success"
  (emit-event "presence"
              :payload (append `(:clientId ,client-id
                             :status ,(string status))
                               details)))

(defun emit-chat-message (message-id channel-id content &key sender timestamp)
  "Emit a chat message event.

  Args:
    MESSAGE-ID: Message identifier
    CHANNEL-ID: Channel identifier
    CONTENT: Message content
    SENDER: Optional sender info
    TIMESTAMP: Optional timestamp

  Returns:
    T on success"
  (emit-event "chat.message"
              :payload `(:messageId ,message-id
                        :channelId ,channel-id
                        :content ,content
                        ,@(when sender `(:sender ,sender))
                        ,@(when timestamp `(:timestamp ,timestamp)))))
