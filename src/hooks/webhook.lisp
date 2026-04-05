;;; hooks/webhook.lisp --- Webhooks and Hooks System for Lisp-Claw
;;;
;;; This file implements incoming/outgoing webhooks with authentication,
;;; similar to OpenClaw's hooks system.

(defpackage #:lisp-claw.hooks.webhook
  (:nicknames #:lc.hooks.webhook)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.crypto
        #:lisp-claw.gateway.auth)
  (:export
   ;; Webhook class
   #:webhook
   #:make-webhook
   #:webhook-id
   #:webhook-url
   #:webhook-secret
   #:webhook-events
   #:webhook-enabled-p
   ;; Webhook registry
   #:*webhook-registry*
   #:register-webhook
   #:unregister-webhook
   #:get-webhook
   #:list-webhooks
   ;; Incoming webhooks
   #:handle-incoming-webhook
   #:validate-webhook-signature
   #:webhook-authenticator
   ;; Outgoing webhooks
   #:send-webhook
   #:trigger-webhook
   #:deliver-webhook
   ;; Webhook logs
   #:get-webhook-delivery-log
   #:clear-webhook-logs
   ;; HMAC signing
   #:sign-webhook-payload
   #:verify-webhook-signature))

(in-package #:lisp-claw.hooks.webhook)

;;; ============================================================================
;;; Webhook Class
;;; ============================================================================

(defclass webhook ()
  ((id :initarg :id
       :reader webhook-id
       :documentation "Unique webhook identifier")
   (url :initarg :url
        :reader webhook-url
        :documentation "Target URL for webhook")
   (secret :initarg :secret
           :reader webhook-secret
           :documentation "Secret for HMAC signing")
   (events :initarg :events
           :initform nil
           :reader webhook-events
           :documentation "List of events to trigger")
   (enabled-p :initform t
              :accessor webhook-enabled-p
              :documentation "Whether webhook is enabled")
   (headers :initarg :headers
            :initform nil
            :reader webhook-headers
            :documentation "Custom headers")
   (retry-count :initarg :retry-count
                :initform 3
                :reader webhook-retry-count
                :documentation "Number of retry attempts")
   (timeout :initarg :timeout
            :initform 30
            :reader webhook-timeout
            :documentation "Request timeout in seconds")
   (created-at :initform (get-universal-time)
               :reader webhook-created-at
               :documentation "Creation timestamp"))
  (:documentation "Webhook configuration"))

(defmethod print-object ((webhook webhook) stream)
  (print-unreadable-object (webhook stream :type t)
    (format stream "~A [~A]" (webhook-id webhook) (webhook-url webhook))))

(defun make-webhook (id url &key secret events headers retry-count timeout)
  "Create a webhook.

  Args:
    ID: Unique identifier
    URL: Target URL
    SECRET: Secret for HMAC signing
    EVENTS: Events to trigger
    HEADERS: Custom headers
    RETRY-COUNT: Retry attempts
    TIMEOUT: Request timeout

  Returns:
    Webhook instance"
  (make-instance 'webhook
                 :id id
                 :url url
                 :secret (or secret (generate-webhook-secret))
                 :events events
                 :headers headers
                 :retry-count (or retry-count 3)
                 :timeout (or timeout 30)))

;;; ============================================================================
;;; Global Registry
;;; ============================================================================

(defvar *webhook-registry* (make-hash-table :test 'equal)
  "Registry of configured webhooks.")

(defvar *webhook-delivery-log* (make-array 1000 :adjustable t :fill-pointer 0)
  "Log of webhook deliveries.")

(defvar *webhook-log-lock* (bt:make-lock)
  "Lock for webhook log access.")

;;; ============================================================================
;;; Webhook Management
;;; ============================================================================

(defun register-webhook (webhook)
  "Register a webhook.

  Args:
    WEBHOOK: Webhook instance

  Returns:
    T on success"
  (setf (gethash (webhook-id webhook) *webhook-registry*) webhook)
  (log-info "Registered webhook: ~A -> ~A" (webhook-id webhook) (webhook-url webhook))
  t)

(defun unregister-webhook (id)
  "Unregister a webhook.

  Args:
    ID: Webhook ID

  Returns:
    T on success"
  (when (gethash id *webhook-registry*)
    (remhash id *webhook-registry*)
    (log-info "Unregistered webhook: ~A" id)
    t))

(defun get-webhook (id)
  "Get a webhook by ID.

  Args:
    ID: Webhook ID

  Returns:
    Webhook instance or NIL"
  (gethash id *webhook-registry*))

(defun list-webhooks ()
  "List all registered webhooks.

  Returns:
    List of webhook info plists"
  (let ((webhooks nil))
    (maphash (lambda (id webhook)
               (push (list :id id
                           :url (webhook-url webhook)
                           :events (webhook-events webhook)
                           :enabled (webhook-enabled-p webhook)
                           :created-at (webhook-created-at webhook))
                     webhooks))
             *webhook-registry*)
    webhooks))

;;; ============================================================================
;;; HMAC Signing
;;; ============================================================================

(defun generate-webhook-secret ()
  "Generate a random webhook secret.

  Returns:
    Random secret string"
  (generate-random-hex-string 32))

(defun sign-webhook-payload (payload secret)
  "Sign a webhook payload with HMAC-SHA256.

  Args:
    PAYLOAD: Payload string
    SECRET: Secret key

  Returns:
    HMAC signature hex string"
  (let ((signature (hmac-sha256-hex secret payload)))
    signature))

(defun verify-webhook-signature (payload signature secret)
  "Verify a webhook signature.

  Args:
    PAYLOAD: Payload string
    SIGNATURE: Signature to verify
    SECRET: Secret key

  Returns:
    T if valid, NIL otherwise"
  (let ((expected (sign-webhook-payload payload secret)))
    (string= signature expected)))

(defun validate-webhook-signature (request secret &optional tolerance)
  "Validate webhook signature from request headers.

  Args:
    REQUEST: Request plist
    SECRET: Expected secret
    TOLERANCE: Timestamp tolerance in seconds

  Returns:
    T if valid, NIL otherwise"
  (let* ((headers (getf request :headers))
         (signature (or (gethash "X-Webhook-Signature" headers)
                        (gethash "x-webhook-signature" headers)))
         (timestamp (or (gethash "X-Webhook-Timestamp" headers)
                        (gethash "x-webhook-timestamp" headers)))
         (body (getf request :body)))

    (unless signature
      (return-from validate-webhook-signature nil))

    (unless (verify-webhook-signature body signature secret)
      (return-from validate-webhook-signature nil))

    (when (and timestamp tolerance)
      (let ((request-time (parse-integer timestamp))
            (now (get-universal-time)))
        (unless (<= (abs (- request-time now)) tolerance)
          (return-from validate-webhook-signature nil))))

    t))

;;; ============================================================================
;;; Outgoing Webhooks
;;; ============================================================================

(defun send-webhook (webhook event payload)
  "Send a webhook.

  Args:
    WEBHOOK: Webhook instance
    EVENT: Event type
    PAYLOAD: Payload plist

  Returns:
    Delivery result plist"
  (let ((url (webhook-url webhook))
        (secret (webhook-secret webhook))
        (headers (webhook-headers webhook))
        (retry-count (webhook-retry-count webhook))
        (timeout (webhook-timeout webhook)))

    ;; Build payload
    (let* ((payload-str (stringify-json payload))
           (timestamp (get-universal-time))
           (signature (sign-webhook-payload payload-str secret))
           (request-headers (append headers
                                    `(("Content-Type" . "application/json")
                                      ("X-Webhook-Signature" . ,signature)
                                      ("X-Webhook-Timestamp" . ,(format nil "~A" timestamp))
                                      ("X-Webhook-Event" . ,(string event))))))

      ;; Send request
      (let ((success nil)
            (attempts 0)
            (response nil)
            (error nil))
        (loop while (and (not success) (< attempts retry-count))
              do (handler-case
                     (progn
                       (setf response (dex:post url
                                                :headers request-headers
                                                :content payload-str
                                                :timeout timeout))
                       (setf success t))
                   (error (e)
                     (setf error e)
                     (incf attempts)
                     (when (< attempts retry-count)
                       (sleep (* attempts 0.5))))))

        ;; Log delivery
        (log-webhook-delivery webhook event success response error)

        (list :success success
              :webhook-id (webhook-id webhook)
              :event event
              :attempts attempts
              :error (when error (format nil "~A" error)))))))

(defun trigger-webhook (event payload)
  "Trigger all webhooks for an event.

  Args:
    EVENT: Event type
    PAYLOAD: Payload plist

  Returns:
    List of delivery results"
  (let ((results nil))
    (maphash (lambda (id webhook)
               (when (and (webhook-enabled-p webhook)
                          (member event (webhook-events webhook) :test #'string=))
                 (push (send-webhook webhook event payload) results)))
             *webhook-registry*)
    (nreverse results)))

(defun deliver-webhook (url payload &key secret headers timeout)
  "Deliver a webhook to a specific URL.

  Args:
    URL: Target URL
    PAYLOAD: Payload plist
    SECRET: Optional secret for signing
    HEADERS: Optional custom headers
    TIMEOUT: Optional timeout

  Returns:
    Delivery result"
  (let* ((payload-str (stringify-json payload))
         (timestamp (get-universal-time))
         (request-headers (append headers
                                  `(("Content-Type" . "application/json")))))

    (when secret
      (let ((signature (sign-webhook-payload payload-str secret)))
        (push (cons "X-Webhook-Signature" signature) request-headers)
        (push (cons "X-Webhook-Timestamp" (format nil "~A" timestamp)) request-headers)))

    (handler-case
        (let ((response (dex:post url
                                  :headers request-headers
                                  :content payload-str
                                  :timeout (or timeout 30))))
          (list :success t :response response))
      (error (e)
        (list :success nil :error (format nil "~A" e))))))

;;; ============================================================================
;;; Incoming Webhooks
;;; ============================================================================

(defvar *incoming-webhook-handlers* (make-hash-table :test 'equal)
  "Registry of incoming webhook handlers.")

(defun register-incoming-webhook-handler (path handler &key auth-token)
  "Register a handler for incoming webhooks.

  Args:
    PATH: URL path to handle
    HANDLER: Handler function
    AUTH-TOKEN: Optional auth token for validation

  Returns:
    T"
  (setf (gethash path *incoming-webhook-handlers*)
        (list :handler handler :auth-token auth-token))
  (log-info "Registered incoming webhook handler: ~A" path)
  t)

(defun unregister-incoming-webhook-handler (path)
  "Unregister an incoming webhook handler.

  Args:
    PATH: URL path

  Returns:
    T"
  (remhash path *incoming-webhook-handlers*)
  (log-info "Unregistered incoming webhook handler: ~A" path)
  t)

(defun handle-incoming-webhook (request)
  "Handle an incoming webhook request.

  Args:
    REQUEST: Request plist

  Returns:
    Response plist"
  (let* ((path (getf request :path))
         (handler-info (gethash path *incoming-webhook-handlers*)))

    (unless handler-info
      (return-from handle-incoming-webhook
        (list :status 404 :body "Webhook handler not found"))))

  (let ((handler (getf handler-info :handler))
        (auth-token (getf handler-info :auth-token)))

    ;; Validate authentication if configured
    (when auth-token
      (let ((request-token (or (getf request :token)
                               (gethash "Authorization" (getf request :headers)))))
        (unless (or (string= request-token auth-token)
                    (string= request-token (format nil "Bearer ~A" auth-token)))
          (return-from handle-incoming-webhook
            (list :status 401 :body "Unauthorized")))))

    ;; Call handler
    (handler-case
        (let ((result (funcall handler request)))
          (list :status 200 :body (stringify-json result)))
      (error (e)
        (list :status 500 :body (format nil "Error: ~A" e))))))

(defun webhook-authenticator (request secret)
  "Authenticator function for webhook requests.

  Args:
    REQUEST: Request plist
    SECRET: Expected secret

  Returns:
    T if authenticated, NIL otherwise"
  (validate-webhook-signature request secret))

;;; ============================================================================
;;; Logging
;;; ============================================================================

(defun log-webhook-delivery (webhook event success response error)
  "Log a webhook delivery.

  Args:
    WEBHOOK: Webhook instance
    EVENT: Event type
    SUCCESS: Whether delivery succeeded
    RESPONSE: Response data
    ERROR: Error if failed

  Returns:
    T"
  (bt:with-lock-held (*webhook-log-lock*)
    (vector-push-extend
     (list :timestamp (get-universal-time)
           :webhook-id (webhook-id webhook)
           :event event
           :success success
           :response response
           :error (when error (format nil "~A" error)))
     *webhook-delivery-log*))
  t)

(defun get-webhook-delivery-log (&key limit webhook-id)
  "Get webhook delivery log.

  Args:
    LIMIT: Maximum entries
    WEBHOOK-ID: Filter by webhook ID

  Returns:
    List of log entries"
  (let ((log nil))
    (bt:with-lock-held (*webhook-log-lock*)
      (let ((len (length *webhook-delivery-log*)))
        (loop for i from (1- len) downto 0
              for entry = (aref *webhook-delivery-log* i)
              when (or (null webhook-id)
                       (string= webhook-id (getf entry :webhook-id)))
              do (push entry log)
              when (and limit (>= (length log) limit))
              do (return))))
    log))

(defun clear-webhook-logs ()
  "Clear webhook delivery logs.

  Returns:
    T"
  (bt:with-lock-held (*webhook-log-lock*)
    (setf *webhook-delivery-log* (make-array 1000 :adjustable t :fill-pointer 0)))
  t)

;;; ============================================================================
;;; Pre-built Event Types
;;; ============================================================================

(defparameter +webhook-events+
  '("message.received"
    "message.sent"
    "agent.response"
    "tool.called"
    "skill.executed"
    "channel.connected"
    "channel.disconnected"
    "error.occurred"
    "system.started"
    "system.stopped"
    "cron.executed"
    "memory.stored"
    "vector.indexed")
  "Standard webhook event types.")

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-webhook-system ()
  "Initialize the webhook system.

  Returns:
    T"
  (log-info "Webhook system initialized")
  t)
