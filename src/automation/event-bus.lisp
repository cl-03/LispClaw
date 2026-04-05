;;; automation/event-bus.lisp --- Event Bus for Lisp-Claw
;;;
;;; This file implements a publish/subscribe event bus system supporting:
;;; - Event publishing and subscription
;;; - Event filtering by topic and pattern
;;; - Event persistence and replay
;;; - Async event processing
;;; - Event handlers with priority

(defpackage #:lisp-claw.automation.event-bus
  (:nicknames #:lc.automation.event-bus)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:cl-ppcre)
  (:export
   ;; Event bus class
   #:event-bus
   #:make-event-bus
   #:event-bus-name
   #:event-bus-subscriptions
   #:event-bus-event-store
   ;; Event class
   #:event
   #:make-event
   #:event-id
   #:event-topic
   #:event-type
   #:event-payload
   #:event-timestamp
   #:event-source
   #:event-priority
   #:event-headers
   ;; Subscription class
   #:subscription
   #:make-subscription
   #:subscription-id
   #:subscription-topic
   #:subscription-handler
   #:subscription-filter
   #:subscription-priority
   #:subscription-active-p
   ;; Core operations
   #:publish
   #:publish-async
   #:subscribe
   #:unsubscribe
   #:subscribe-pattern
   ;; Event store
   #:store-event
   #:get-event
   #:replay-events
   #:purge-events
   ;; Monitoring
   #:get-event-stats
   #:list-topics
   #:list-subscriptions
   #:get-subscription-stats
   ;; Initialization
   #:initialize-event-bus-system))

(in-package #:lisp-claw.automation.event-bus)

;;; ============================================================================
;;; Event Class
;;; ============================================================================

(defclass event ()
  ((id :initarg :id
       :initform (uuid:make-uuid-string)
       :reader event-id
       :documentation "Unique event identifier")
   (topic :initarg :topic
          :reader event-topic
          :documentation "Event topic/name")
   (type :initarg :type
         :initform :info
         :reader event-type
         :documentation "Event type: info, warning, error, debug")
   (payload :initarg :payload
            :initform (make-hash-table :test 'equal)
            :reader event-payload
            :documentation "Event payload data")
   (timestamp :initform (get-universal-time)
              :reader event-timestamp
              :documentation "Event creation timestamp")
   (source :initarg :source
           :initform nil
           :reader event-source
           :documentation "Event source component")
   (priority :initarg :priority
             :initform 0
             :reader event-priority
             :documentation "Event priority (higher = more urgent)")
   (headers :initarg :headers
            :initform (make-hash-table :test 'equal)
            :reader event-headers
            :documentation "Event metadata headers"))
  (:documentation "Represents an event in the bus"))

(defmethod print-object ((event event) stream)
  (print-unreadable-object (event stream :type t)
    (format stream "~A [~A]" (event-topic event) (event-type event))))

(defun make-event (topic &key type payload source priority headers)
  "Create a new event.

  Args:
    TOPIC: Event topic/name (e.g., \"user.login\", \"task.completed\")
    TYPE: Event type (default: :info)
    PAYLOAD: Event data (plist or hash-table)
    SOURCE: Event source component (optional)
    PRIORITY: Event priority (default: 0)
    HEADERS: Event metadata (optional)

  Returns:
    Event instance"
  (make-instance 'event
                 :topic topic
                 :type (or type :info)
                 :payload (if (listp payload)
                              (alexandria:alist-hash-table payload :test 'equal)
                              payload)
                 :source source
                 :priority (or priority 0)
                 :headers (or headers (make-hash-table :test 'equal))))

;;; ============================================================================
;;; Subscription Class
;;; ============================================================================

(defclass subscription ()
  ((id :initarg :id
       :initform (uuid:make-uuid-string)
       :reader subscription-id
       :documentation "Unique subscription identifier")
   (topic :initarg :topic
          :reader subscription-topic
          :documentation "Topic pattern to subscribe to")
   (handler :initarg :handler
            :reader subscription-handler
            :documentation "Event handler function")
   (filter :initarg :filter
           :initform nil
           :reader subscription-filter
           :documentation "Additional filter function")
   (priority :initarg :priority
             :initform 0
             :reader subscription-priority
             :documentation "Subscription priority (higher = called first)")
   (active-p :initform t
             :accessor subscription-active-p
             :documentation "Whether subscription is active")
   (event-count :initform 0
                :accessor subscription-event-count
                :documentation "Number of events handled"))
  (:documentation "Represents an event subscription"))

(defmethod print-object ((sub subscription) stream)
  (print-unreadable-object (sub stream :type t)
    (format stream "~A [~A]" (subscription-topic sub)
            (if (subscription-active-p sub) "active" "inactive"))))

(defun make-subscription (topic handler &key filter priority)
  "Create a new subscription.

  Args:
    TOPIC: Topic pattern (supports wildcards: *, **)
    HANDLER: Handler function (lambda (event) ...)
    FILTER: Optional filter function (lambda (event) -> boolean)
    PRIORITY: Subscription priority (default: 0)

  Returns:
    Subscription instance"
  (make-instance 'subscription
                 :topic topic
                 :handler handler
                 :filter filter
                 :priority (or priority 0)))

;;; ============================================================================
;;; Event Bus Class
;;; ============================================================================

(defclass event-bus ()
  ((name :initarg :name
         :initform "default"
         :reader event-bus-name
         :documentation "Event bus name")
   (subscriptions :initform (make-hash-table :test 'equal)
                  :accessor event-bus-subscriptions
                  :documentation "Subscriptions by topic pattern")
   (event-store :initform (make-hash-table :test 'equal)
                :accessor event-bus-event-store
                :documentation "Stored events by ID")
   (topic-index :initform (make-hash-table :test 'equal)
                :accessor event-bus-topic-index
                :documentation "Events indexed by topic")
   (lock :initform (bt:make-lock)
         :reader event-bus-lock
         :documentation "Bus lock")
   (async-queue :initform nil
                :accessor event-bus-async-queue
                :documentation "Queue for async processing")
   (async-workers :initform nil
                  :accessor event-bus-async-workers
                  :documentation "Async worker threads")
   (stats :initform (make-hash-table :test 'equal)
          :accessor event-bus-stats
          :documentation "Event statistics"))
  (:documentation "Publish/Subscribe event bus"))

(defun make-event-bus (&key name)
  "Create an event bus.

  Args:
    NAME: Bus name (default: \"default\")

  Returns:
    Event bus instance"
  (let ((bus (make-instance 'event-bus
                            :name (or name "default"))))
    (log-info "Event bus '~A' created" (or name "default"))
    bus))

;;; ============================================================================
;;; Pattern Matching
;;; ============================================================================

(defun topic-match-p (pattern topic)
  "Check if a topic matches a pattern.

  Patterns support:
    * - matches single level (e.g., \"user.*\" matches \"user.login\")
    ** - matches multiple levels (e.g., \"user.**\" matches \"user.login.success\")

  Args:
    PATTERN: Topic pattern
    TOPIC: Actual topic string

  Returns:
    T if matches, NIL otherwise"
  (cond
    ;; Exact match
    ((string= pattern topic) t)
    ;; Double wildcard - matches everything below
    ((search "**" pattern)
     (let ((prefix (subseq pattern 0 (search "**" pattern))))
       (or (string= prefix topic)
           (and (> (length topic) (length prefix))
                (string= prefix (subseq topic 0 (length prefix)))
                (or (char= (char topic (length prefix)) #\.)
                    (string= (subseq topic (1+ (length prefix))) ""))))))
    ;; Single wildcard - matches single level
    ((search "*" pattern)
     (let ((parts-pattern (split-sequence:split-sequence #\. pattern))
           (parts-topic (split-sequence:split-sequence #\. topic)))
       (when (= (length parts-pattern) (length parts-topic))
         (every (lambda (p t)
                  (or (string= p "*")
                      (string= p t)))
                parts-pattern parts-topic))))
    ;; No match
    (t nil)))

(defun compile-pattern (pattern)
  "Compile a topic pattern to a regex.

  Args:
    PATTERN: Topic pattern with wildcards

  Returns:
    Compiled regex string"
  (let ((regex (cl-ppcre:quote-meta-chars pattern)))
    ;; Replace \*\* with .* for multi-level wildcard
    (setf regex (cl-ppcre:regex-replace-all "\\\\*\\\\*" regex ".*"))
    ;; Replace \* with [^.]* for single-level wildcard
    (setf regex (cl-ppcre:regex-replace-all "\\\\*" regex "[^.]*"))
    (format nil "^~A$" regex)))

;;; ============================================================================
;;; Core Operations
;;; ============================================================================

(defun publish (bus event)
  "Publish an event to the bus (synchronous).

  Args:
    BUS: Event bus instance
    EVENT: Event to publish

  Returns:
    Number of handlers called"
  (bt:with-lock-held ((event-bus-lock bus))
    (let ((handlers nil)
          (count 0))
      ;; Find matching subscriptions
      (maphash (lambda (pattern subs)
                 (declare (ignore pattern))
                 (dolist (sub subs)
                   (when (and (subscription-active-p sub)
                              (topic-match-p (subscription-topic sub)
                                             (event-topic event)))
                     ;; Apply additional filter if present
                     (unless (and (subscription-filter sub)
                                  (not (funcall (subscription-filter sub) event)))
                       (push (cons (subscription-priority sub) sub) handlers)))))
               (event-bus-subscriptions bus))

      ;; Sort by priority (higher first)
      (setf handlers (sort handlers #'> :key #'car))

      ;; Call handlers
      (dolist (handler-info handlers)
        (let ((sub (cdr handler-info)))
          (handler-case
              (progn
                (funcall (subscription-handler sub) event)
                (incf (subscription-event-count sub))
                (incf count))
            (error (e)
              (log-error "Event handler error: ~A" e)))))

      ;; Store event
      (store-event bus event)

      ;; Update stats
      (let ((topic (event-topic event)))
        (incf (gethash topic (event-bus-stats bus) 0)))

      count)))

(defun publish-async (bus event)
  "Publish an event asynchronously.

  Args:
    BUS: Event bus instance
    EVENT: Event to publish

  Returns:
    T on success"
  (let ((queue (event-bus-async-queue bus)))
    (if queue
        (progn
          (bt:with-lock-held ((event-bus-lock bus))
            (vector-push-extend event queue))
          t)
        ;; Fallback to sync if async not configured
        (publish bus event))))

(defun subscribe (bus topic handler &key filter priority)
  "Subscribe to an event topic.

  Args:
    BUS: Event bus instance
    TOPIC: Topic pattern (supports wildcards)
    HANDLER: Handler function (lambda (event) ...)
    FILTER: Optional filter function
    PRIORITY: Subscription priority

  Returns:
    Subscription instance"
  (bt:with-lock-held ((event-bus-lock bus))
    (let ((sub (make-subscription topic handler
                                   :filter filter
                                   :priority priority)))
      ;; Add to subscriptions
      (let ((subs (gethash topic (event-bus-subscriptions bus) nil)))
        (setf (gethash topic (event-bus-subscriptions bus))
              (cons sub subs)))
      (log-info "Subscription created for topic '~A'" topic)
      sub)))

(defun unsubscribe (bus subscription)
  "Unsubscribe from events.

  Args:
    BUS: Event bus instance
    SUBSCRIPTION: Subscription to remove

  Returns:
    T on success"
  (bt:with-lock-held ((event-bus-lock bus))
    (setf (subscription-active-p subscription) nil)
    (log-info "Subscription cancelled for '~A'" (subscription-topic subscription))
    t))

(defun subscribe-pattern (bus pattern handler &key priority)
  "Subscribe using a compiled regex pattern.

  Args:
    BUS: Event bus instance
    PATTERN: Regex pattern string
    HANDLER: Handler function
    PRIORITY: Subscription priority

  Returns:
    Subscription instance"
  (let ((regex (compile-pattern pattern)))
    (subscribe bus pattern handler
               :filter (lambda (event)
                         (cl-ppcre:scan regex (event-topic event)))
               :priority priority)))

;;; ============================================================================
;;; Event Store
;;; ============================================================================

(defun store-event (bus event)
  "Store an event for replay.

  Args:
    BUS: Event bus instance
    EVENT: Event to store

  Returns:
    Event ID"
  (bt:with-lock-held ((event-bus-lock bus))
    ;; Store by ID
    (setf (gethash (event-id event) (event-bus-event-store bus)) event)
    ;; Index by topic
    (let ((topic (event-topic event)))
      (let ((events (gethash topic (event-bus-topic-index bus) nil)))
        (setf (gethash topic (event-bus-topic-index bus))
              (cons event events))))
    (event-id event)))

(defun get-event (bus event-id)
  "Get an event by ID.

  Args:
    BUS: Event bus instance
    EVENT-ID: Event ID

  Returns:
    Event or NIL"
  (gethash event-id (event-bus-event-store bus)))

(defun replay-events (bus &key topic from-id limit handler)
  "Replay stored events.

  Args:
    BUS: Event bus instance
    TOPIC: Filter by topic (optional)
    FROM-ID: Start from event ID (optional)
    LIMIT: Max events to replay (default: 100)
    HANDLER: Handler function (optional, defaults to publishing)

  Returns:
    Number of events replayed"
  (let ((events nil)
        (count 0))
    (if topic
        ;; Replay specific topic
        (let ((topic-events (gethash topic (event-bus-topic-index bus) nil)))
          (setf events (subseq (or topic-events nil)
                               0
                               (min (length (or topic-events nil)) (or limit 100)))))
        ;; Replay all events
        (let ((i 0))
          (maphash (lambda (id event)
                     (declare (ignore id))
                     (when (< i (or limit 100))
                       (push event events)
                       (incf i)))
                   (event-bus-event-store bus))))

    ;; Replay events
    (dolist (event (reverse events))
      (when (or (null from-id)
                (string> (event-id event) from-id))
        (if handler
            (funcall handler event)
            (publish bus event))
        (incf count)))

    count))

(defun purge-events (bus &key topic older-than)
  "Purge stored events.

  Args:
    BUS: Event bus instance
    TOPIC: Filter by topic (optional)
    OLDER-THAN: Purge events older than timestamp (optional)

  Returns:
    Number of events purged"
  (let ((count 0)
        (current-time (get-universal-time)))
    (if topic
        ;; Purge specific topic
        (let ((events (gethash topic (event-bus-topic-index bus) nil)))
          (dolist (event events)
            (when (or (null older-than)
                      (>= (- current-time (event-timestamp event)) older-than))
              (remhash (event-id event) (event-bus-event-store bus))
              (incf count)))
          (remhash topic (event-bus-topic-index bus)))
        ;; Purge all
        (maphash (lambda (id event)
                   (when (or (null older-than)
                             (>= (- current-time (event-timestamp event)) older-than))
                     (remhash id (event-bus-event-store bus))
                     (incf count)))
                 (event-bus-event-store bus))
          (clrhash (event-bus-topic-index bus))))
    (log-info "Purged ~A events" count)
    count))

;;; ============================================================================
;;; Monitoring
;;; ============================================================================

(defun get-event-stats (bus)
  "Get event statistics.

  Args:
    BUS: Event bus instance

  Returns:
    Stats plist"
  (let ((total-events (hash-table-count (event-bus-event-store bus)))
        (total-subs 0)
        (active-subs 0)
        (topics nil))
    (maphash (lambda (topic subs)
               (declare (ignore topic))
               (dolist (sub subs)
                 (incf total-subs)
                 (when (subscription-active-p sub)
                   (incf active-subs))))
             (event-bus-subscriptions bus))
    (maphash (lambda (topic count)
               (push (cons topic count) topics))
             (event-bus-stats bus))
    (list :total-events total-events
          :total-subscriptions total-subs
          :active-subscriptions active-subs
          :topics (sort topics #'> :key #'cdr))))

(defun list-topics (bus)
  "List all topics with events.

  Args:
    BUS: Event bus instance

  Returns:
    List of topic names"
  (let ((topics nil))
    (maphash (lambda (topic events)
               (declare (ignore events))
               (push topic topics))
             (event-bus-topic-index bus))
    topics))

(defun list-subscriptions (bus &key active-only)
  "List all subscriptions.

  Args:
    BUS: Event bus instance
    ACTIVE-ONLY: Only active subscriptions (default: NIL)

  Returns:
    List of subscriptions"
  (let ((subs nil))
    (maphash (lambda (topic topic-subs)
               (dolist (sub topic-subs)
                 (when (or (null active-only)
                           (subscription-active-p sub))
                   (push sub subs))))
             (event-bus-subscriptions bus))
    subs))

(defun get-subscription-stats (bus subscription)
  "Get statistics for a subscription.

  Args:
    BUS: Event bus instance
    SUBSCRIPTION: Subscription instance

  Returns:
    Stats plist"
  (list :id (subscription-id subscription)
        :topic (subscription-topic subscription)
        :active (subscription-active-p subscription)
        :events-handled (subscription-event-count subscription)
        :priority (subscription-priority subscription)))

;;; ============================================================================
;;; Async Processing
;;; ============================================================================

(defun start-async-workers (bus &optional (count 4))
  "Start async event processing workers.

  Args:
    BUS: Event bus instance
    COUNT: Number of workers (default: 4)

  Returns:
    List of worker thread objects"
  (let ((queue (make-array 1000 :fill-pointer 0 :adjustable t))
        (workers nil))
    (setf (event-bus-async-queue bus) queue)
    (dotimes (i count)
      (let ((thread (bt:make-thread
                     (lambda ()
                       (loop
                         (let ((event nil))
                           (bt:with-lock-held ((event-bus-lock bus))
                             (when (> (fill-pointer queue) 0)
                               (setf event (vector-pop queue))))
                           (when event
                             (publish bus event)))
                         (sleep 0.01)))
                     :name (format nil "event-bus-worker-~A" i))))
        (push thread workers)))
    (setf (event-bus-async-workers bus) workers)
    (log-info "Started ~A async event workers" count)
    workers))

(defun stop-async-workers (bus)
  "Stop async event processing workers.

  Args:
    BUS: Event bus instance

  Returns:
    Number of workers stopped"
  (let ((workers (event-bus-async-workers bus)))
    (dolist (worker workers)
      (bt:destroy-thread worker))
    (setf (event-bus-async-workers bus) nil)
    (setf (event-bus-async-queue bus) nil)
    (log-info "Stopped ~A async event workers" (length workers))
    (length workers)))

;;; ============================================================================
;;; Built-in Event Types
;;; ============================================================================

(defun make-system-event (type &key payload source)
  "Create a system event.

  Args:
    TYPE: System event type (startup, shutdown, error, config-change)
    PAYLOAD: Event payload
    SOURCE: Event source

  Returns:
    Event instance"
  (make-event "system"
              :type :info
              :payload (list* :system-type type payload)
              :source (or source "system")))

(defun make-user-event (type user-id &key payload source)
  "Create a user event.

  Args:
    TYPE: User event type (login, logout, action, error)
    USER-ID: User identifier
    PAYLOAD: Event payload
    SOURCE: Event source

  Returns:
    Event instance"
  (make-event (format nil "user.~A" type)
              :type :info
              :payload (list* :user-id user-id payload)
              :source (or source "user")))

(defun make-message-event (channel message-id &key payload source)
  "Create a message event.

  Args:
    CHANNEL: Channel identifier
    MESSAGE-ID: Message identifier
    PAYLOAD: Event payload
    SOURCE: Event source

  Returns:
    Event instance"
  (make-event (format nil "message.~A" channel)
              :type :info
              :payload (list* :channel channel :message-id message-id payload)
              :source (or source "channel")))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-event-bus-system (&key name async-workers)
  "Initialize the event bus system.

  Args:
    NAME: Bus name (default: \"lisp-claw\")
    ASYNC-WORKERS: Number of async workers (default: 4)

  Returns:
    Event bus instance"
  (let ((bus (make-event-bus :name (or name "lisp-claw"))))
    ;; Start async workers if requested
    (when async-workers
      (start-async-workers bus async-workers))
    (log-info "Event bus system initialized with ~A async workers"
              (or async-workers 0))
    bus))
