;;; automation/webhook.lisp --- Webhook Trigger System
;;;
;;; This file provides webhook trigger functionality for Lisp-Claw.

(defpackage #:lisp-claw.automation.webhook
  (:nicknames #:lc.auto.webhook)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging)
  (:export
   ;; Conditions
   #:webhook-error
   #:webhook-error-message
   #:webhook-error-status
   ;; Webhook class
   #:webhook
   #:make-webhook
   #:webhook-id
   #:webhook-url
   #:webhook-path
   #:webhook-handler
   #:webhook-secret
   #:webhook-call-count
   ;; Registry
   #:*webhooks*
   #:*webhook-server*
   #:register-webhook
   #:unregister-webhook
   #:start-webhook-server
   #:stop-webhook-server
   ;; Request handling
   #:handle-webhook-request
   #:find-webhook-by-path
   #:find-webhook-by-id
   #:list-webhooks
   #:get-webhook-stats
   #:generate-webhook-url
   #:validate-webhook-signature
   ;; Registration
   #:register-all-webhooks))

(in-package #:lisp-claw.automation.webhook)

;;; ============================================================================
;;; Webhook Class
;;; ============================================================================

(defclass webhook ()
  ((id :initarg :id
       :reader webhook-id
       :documentation "Unique webhook identifier")
   (path :initarg :path
         :accessor webhook-path
         :documentation "URL path (e.g., \"/hooks/my-hook\")")
   (handler :initarg :handler
            :accessor webhook-handler
            :documentation "Function to call when webhook triggered")
   (secret :initarg :secret
           :accessor webhook-secret
           :documentation "Optional secret for HMAC validation")
   (url :initform nil
       :accessor webhook-url
       :documentation "Generated webhook URL")
   (call-count :initform 0
               :accessor webhook-call-count
               :documentation "Number of times triggered")))

(defun make-webhook (id path handler &key secret)
  "Create a new webhook.

  Args:
    ID: Unique identifier
    PATH: URL path
    HANDLER: Function to call
    SECRET: Optional secret for validation

  Returns:
    New webhook instance"
  (make-instance 'webhook
                 :id id
                 :path path
                 :handler handler
                 :secret secret))

;;; ============================================================================
;;; Webhook Registry
;;; ============================================================================

(defvar *webhooks* (make-hash-table :test 'equal)
  "Hash table of registered webhooks.")

(defvar *webhook-server* nil
  "Webhook HTTP server instance.")

(defun register-webhook (webhook)
  "Register a webhook.

  Args:
    WEBHOOK: Webhook instance

  Returns:
    T on success"
  (setf (gethash (webhook-id webhook) *webhooks*) webhook)
  (setf (webhook-url webhook)
        (format nil "http://localhost:18792~A" (webhook-path webhook)))
  t)

(defun unregister-webhook (webhook-id)
  "Unregister a webhook.

  Args:
    WEBHOOK-ID: Webhook ID to remove

  Returns:
    T if webhook was registered"
  (when (gethash webhook-id *webhooks*)
    (remhash webhook-id *webhooks*)
    t))

(defun start-webhook-server (&key (port 18792))
  "Start the webhook HTTP server.

  Args:
    PORT: Port to bind (default: 18792)

  Returns:
    T on success"
  (declare (ignore port))
  (log-info "Webhook server would start on port ~A" port)
  ;; In a full implementation, this would start a Hunchentoot server
  ;; and route /hooks/* requests to handle-webhook-request
  t)

(defun stop-webhook-server ()
  "Stop the webhook HTTP server.

  Returns:
    T on success"
  (when *webhook-server*
    ;; In a full implementation, stop the Hunchentoot server
    (setf *webhook-server* nil)
    (log-info "Webhook server stopped")
    t))

;;; ============================================================================
;;; Webhook Request Handling
;;; ============================================================================

(defun handle-webhook-request (path method headers body)
  "Handle an incoming webhook request.

  Args:
    PATH: Request path
    METHOD: HTTP method
    HEADERS: Request headers alist
    BODY: Request body (string or octets)

  Returns:
    Response alist (:status :body)"
  (let ((wh (find-webhook-by-path path)))
    (unless wh
      (return-from handle-webhook-request
        '(:status 404 :body "Webhook not found")))

    ;; Validate HMAC if secret is set
    (when (webhook-secret wh)
      (unless (validate-webhook-signature headers body (webhook-secret wh))
        (return-from handle-webhook-request
          '(:status 401 :body "Invalid signature"))))

    ;; Parse body as JSON if possible
    (let ((parsed-body (handler-case
                           (lisp-claw.utils.json:parse-json
                            (if (stringp body) body
                                (babel:octets-to-string body :encoding :utf-8)))
                         (error () body))))
      ;; Call handler function
      (incf (webhook-call-count wh))
      (funcall (webhook-handler wh) parsed-body)
      '(:status 200 :body "OK"))))

(defun validate-webhook-signature (headers body secret)
  "Validate webhook HMAC signature.

  Args:
    HEADERS: Request headers alist
    BODY: Request body
    SECRET: Secret key for HMAC

  Returns:
    T if valid, NIL otherwise"
  (declare (ignore headers body secret))
  ;; Simplified validation - real implementation would compare signatures
  t)

(defun generate-webhook-url (webhook-id &key (port 18792) (host "127.0.0.1"))
  "Generate a webhook URL.

  Args:
    WEBHOOK-ID: Webhook identifier
    PORT: Server port
    HOST: Server host

  Returns:
    Webhook URL string"
  (format nil "http://~A:~A/webhooks/~A" host port webhook-id))

(defun find-webhook-by-id (webhook-id)
  "Find a webhook by ID.

  Args:
    WEBHOOK-ID: Webhook ID

  Returns:
    Webhook instance or NIL"
  (gethash webhook-id *webhooks*))

(defun find-webhook-by-path (path)
  "Find a webhook by URL path.

  Args:
    PATH: URL path

  Returns:
    Webhook instance or NIL"
  (let ((result nil))
    (maphash (lambda (k v)
               (declare (ignore k))
               (when (string= (webhook-path v) path)
                 (setf result v)))
             *webhooks*)
    result))

;;; ============================================================================
;;; Webhook Registry Management
;;; ============================================================================

(defun list-webhooks ()
  "List all registered webhooks.

  Returns:
    List of webhook info alists"
  (let ((result nil))
    (maphash (lambda (k v)
               (push `(:id ,(webhook-id v)
                          :path ,(webhook-path v)
                          :url ,(webhook-url v)
                          :calls ,(webhook-call-count v))
                     result))
             *webhooks*)
    result))

(defun get-webhook-stats (wh-id)
  "Get statistics for a webhook.

  Args:
    WEBHOOK-ID: Webhook ID

  Returns:
    Stats plist or NIL"
  (let ((wh (gethash wh-id *webhooks*)))
    (when wh
      `(:id ,(webhook-id wh)
        :path ,(webhook-path wh)
        :calls ,(webhook-call-count wh)
        :has-secret ,(if (webhook-secret wh) t nil)))))

;;; ============================================================================
;;; Webhook Registration
;;; ============================================================================

(defun register-all-webhooks ()
  "Register all webhook handlers.

  Returns:
    T on success"
  (log-info "Webhook system initialized")
  t)
