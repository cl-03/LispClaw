;;; gateway/middleware.lisp --- Middleware System for Lisp-Claw
;;;
;;; This file implements a middleware processing pipeline for request/response
;;; handling, similar to OpenClaw's middleware system.

(defpackage #:lisp-claw.gateway.middleware
  (:nicknames #:lc.gateway.middleware)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; Middleware types
   #:middleware
   #:make-middleware
   #:middleware-name
   #:middleware-handler
   #:middleware-order
   ;; Middleware registry
   #:*middleware-registry*
   #:register-middleware
   #:unregister-middleware
   #:get-middleware
   #:list-middleware
   ;; Middleware chain
   #:middleware-chain
   #:make-middleware-chain
   #:chain-add-middleware
   #:chain-remove-middleware
   #:run-middleware-chain
   ;; Built-in middleware
   #:logging-middleware
   #:timing-middleware
   #:error-handler-middleware
   #:rate-limit-middleware
   #:auth-middleware
   #:cors-middleware
   ;; Request/Response processing
   #:process-request
   #:process-response))

(in-package #:lisp-claw.gateway.middleware)

;;; ============================================================================
;;; Middleware Class
;;; ============================================================================

(defclass middleware ()
  ((name :initarg :name
         :reader middleware-name
         :documentation "Unique middleware identifier")
   (handler :initarg :handler
            :reader middleware-handler
            :documentation "Middleware handler function")
   (order :initarg :order
          :initform 0
          :reader middleware-order
          :documentation "Execution order (lower = earlier)")
   (enabled-p :initform t
              :accessor middleware-enabled-p
              :documentation "Whether middleware is enabled")
   (config :initarg :config
           :initform nil
           :reader middleware-config
           :documentation "Middleware-specific configuration"))
  (:documentation "Middleware component for request/response processing"))

(defmethod print-object ((mw middleware) stream)
  (print-unreadable-object (mw stream :type t)
    (format stream "~A [~:*~A]" (middleware-name mw)
            (if (middleware-enabled-p mw) "enabled" "disabled"))))

(defun make-middleware (name handler &key order config)
  "Create a middleware instance.

  Args:
    NAME: Unique identifier
    HANDLER: Function that processes request/response
    ORDER: Execution order (lower = earlier)
    CONFIG: Configuration plist

  Returns:
    Middleware instance"
  (make-instance 'middleware
                 :name name
                 :handler handler
                 :order (or order 0)
                 :config config))

;;; ============================================================================
;;; Middleware Registry
;;; ============================================================================

(defvar *middleware-registry* (make-hash-table :test 'equal)
  "Registry of configured middleware.")

(defvar *middleware-lock* (bt:make-lock)
  "Lock for middleware registry access.")

(defun register-middleware (middleware)
  "Register a middleware.

  Args:
    MIDDLEWARE: Middleware instance

  Returns:
    T on success"
  (bt:with-lock-held (*middleware-lock*)
    (setf (gethash (middleware-name middleware) *middleware-registry*) middleware)
    (log-info "Registered middleware: ~A" (middleware-name middleware))
    t))

(defun unregister-middleware (name)
  "Unregister a middleware.

  Args:
    NAME: Middleware name

  Returns:
    T on success"
  (bt:with-lock-held (*middleware-lock*)
    (when (gethash name *middleware-registry*)
      (remhash name *middleware-registry*)
      (log-info "Unregistered middleware: ~A" name)
      t)))

(defun get-middleware (name)
  "Get a middleware by name.

  Args:
    NAME: Middleware name

  Returns:
    Middleware instance or NIL"
  (gethash name *middleware-registry*))

(defun list-middleware ()
  "List all registered middleware.

  Returns:
    List of middleware info"
  (let ((middleware-list nil))
    (bt:with-lock-held (*middleware-lock*)
      (maphash (lambda (name mw)
                 (push (list :name name
                             :order (middleware-order mw)
                             :enabled (middleware-enabled-p mw)
                             :config (middleware-config mw))
                       middleware-list))
               *middleware-registry*))
    (sort middleware-list #'< :key #'getf)))

;;; ============================================================================
;;; Middleware Chain
;;; ============================================================================

(defclass middleware-chain ()
  ((name :initarg :name
         :reader middleware-chain-name
         :documentation "Chain name")
   (middleware-list :initform nil
                    :accessor middleware-chain-list
                    :documentation "Ordered list of middleware")
   (enabled-p :initform t
              :accessor middleware-chain-enabled-p
              :documentation "Whether chain is enabled"))
  (:documentation "Chain of middleware to execute in order"))

(defmethod print-object ((chain middleware-chain) stream)
  (print-unreadable-object (chain stream :type t)
    (format stream "~A (~A middleware)"
            (middleware-chain-name chain)
            (length (middleware-chain-list chain)))))

(defun make-middleware-chain (name)
  "Create a middleware chain.

  Args:
    NAME: Chain name

  Returns:
    Middleware chain instance"
  (make-instance 'middleware-chain :name name))

(defun chain-add-middleware (chain middleware)
  "Add middleware to chain.

  Args:
    CHAIN: Middleware chain
    MIDDLEWARE: Middleware instance

  Returns:
    T on success"
  (let ((mw (if (stringp middleware) (get-middleware middleware) middleware)))
    (when mw
      (pushnew mw (middleware-chain-list chain) :test #'eq)
      (setf (middleware-chain-list chain)
            (sort (middleware-chain-list chain) #'<
                  :key #'middleware-order))
      (log-info "Added middleware ~A to chain ~A" (middleware-name mw)
                (middleware-chain-name chain))
      t)))

(defun chain-remove-middleware (chain name)
  "Remove middleware from chain.

  Args:
    CHAIN: Middleware chain
    NAME: Middleware name

  Returns:
    T on success"
  (let ((mw (find name (middleware-chain-list chain)
                  :key #'middleware-name :test #'string=)))
    (when mw
      (setf (middleware-chain-list chain)
            (remove mw (middleware-chain-list chain)))
      t)))

(defun run-middleware-chain (chain request &optional response)
  "Run a middleware chain on a request/response.

  Args:
    CHAIN: Middleware chain
    REQUEST: Request plist
    RESPONSE: Optional response plist

  Returns:
    Processed request/response"
  (unless (middleware-chain-enabled-p chain)
    (return-from run-middleware-chain (values request response)))

  (let ((result-request request)
        (result-response response))
    (dolist (mw (middleware-chain-list chain))
      (when (middleware-enabled-p mw)
        (multiple-value-setq (result-request result-response)
          (funcall (middleware-handler mw) result-request result-response))))
    (values result-request result-response)))

;;; ============================================================================
;;; Built-in Middleware
;;; ============================================================================

(defun logging-middleware (request response)
  "Middleware that logs requests and responses.

  Args:
    REQUEST: Request plist
    RESPONSE: Response plist

  Returns:
    Request and response"
  (let ((start-time (get-universal-time)))
    (log-info "[REQUEST] ~A ~A" (getf request :method) (getf request :path))
    (log-debug "[REQUEST-BODY] ~A" (getf request :body))

    ;; Process response
    (let ((elapsed (- (get-universal-time) start-time)))
      (when response
        (log-info "[RESPONSE] Status: ~A, Time: ~As"
                  (getf response :status) elapsed)
        (log-debug "[RESPONSE-BODY] ~A" (getf response :body))))

    (values request response)))

(defun timing-middleware (request response)
  "Middleware that adds timing information.

  Args:
    REQUEST: Request plist
    RESPONSE: Response plist

  Returns:
    Request and response with timing"
  (let ((start-time (get-internal-real-time)))
    (multiple-value-bind (new-request new-response)
        (values request response)
      (let* ((end-time (get-internal-real-time))
             (elapsed-ms (/ (* (- end-time start-time) 1000)
                            internal-time-units-per-second)))
        (when new-response
          (setf (getf new-response :headers)
                (merge-hash-tables
                 (or (getf new-response :headers) (make-hash-table))
                 (let ((ht (make-hash-table))
                       (ms (format nil "~,2f" elapsed-ms)))
                   (setf (gethash "X-Response-Time" ht) ms)
                   ht)))))
      (values new-request new-response))))

(defun error-handler-middleware (request response)
  "Middleware that catches errors and returns error responses.

  Args:
    REQUEST: Request plist
    RESPONSE: Response plist

  Returns:
    Request and response"
  (handler-case
      (values request response)
    (error (e)
      (log-error "[ERROR] ~A: ~A~%Backtrace: ~A"
                 (type-of e) e
                 (with-output-to-string (s)
                   (do-backtrace s)))
      (values request
              (list :status 500
                    :body (stringify-json
                           `(:error "Internal Server Error"
                             :message ,(format nil "~A" e))))))))

(defun rate-limit-middleware (request response)
  "Middleware that enforces rate limiting.

  Args:
    REQUEST: Request plist
    RESPONSE: Response plist

  Returns:
    Request and response"
  ;; Check if rate limiting is enabled
  (let ((config (getf request :rate-limit-config)))
    (when config
      (let ((client-id (getf request :client-id))
            (limit (getf config :limit))
            (window (getf config :window)))
        ;; Check rate limit (simplified - use actual rate limiter in production)
        (let ((exceeded nil)) ;; Check from rate limiter
          (when exceeded
            (return-from rate-limit-middleware
              (values request
                      (list :status 429
                            :body (stringify-json
                                   '(:error "Rate Limit Exceeded"
                                     :retry-after 60))))))))))
  (values request response))

(defun auth-middleware (request response)
  "Middleware that handles authentication.

  Args:
    REQUEST: Request plist
    RESPONSE: Response plist

  Returns:
    Request and response"
  (let ((path (getf request :path)))
    ;; Skip auth for public endpoints
    (when (member path '("/health" "/ready" "/metrics") :test #'string=)
      (return-from auth-middleware (values request response)))

    ;; Check authentication
    (let ((auth-header (gethash "Authorization"
                                (or (getf request :headers)
                                    (make-hash-table)))))
      (unless auth-header
        (return-from auth-middleware
          (values request
                  (list :status 401
                        :body (stringify-json
                               '(:error "Unauthorized"
                                 :message "Missing Authorization header"))))))

      ;; Validate token (use actual validator in production)
      (let ((valid t)) ;; Validate token
        (unless valid
          (return-from auth-middleware
            (values request
                    (list :status 401
                          :body (stringify-json
                                 '(:error "Invalid Token"
                                   :message "Token validation failed"))))))

        ;; Add auth info to request
        (setf (getf request :authenticated-p) t)
        (setf (getf request :auth-token) auth-header)))

  (values request response))

(defun cors-middleware (request response)
  "Middleware that handles CORS headers.

  Args:
    REQUEST: Request plist
    RESPONSE: Response plist

  Returns:
    Request and response"
  (let* ((headers (or (getf request :headers) (make-hash-table)))
         (origin (gethash "Origin" headers))
         (method (getf request :method)))

    ;; Handle preflight requests
    (when (and (string= method "OPTIONS")
               (gethash "Access-Control-Request-Method" headers))
      (return-from cors-middleware
        (values request
                (list :status 204
                      :headers (let ((ht (make-hash-table)))
                                 (setf (gethash "Access-Control-Allow-Origin" ht)
                                       (or origin "*"))
                                 (setf (gethash "Access-Control-Allow-Methods" ht)
                                       "GET, POST, PUT, DELETE, OPTIONS")
                                 (setf (gethash "Access-Control-Allow-Headers" ht)
                                       "Content-Type, Authorization")
                                 (setf (gethash "Access-Control-Max-Age" ht) "86400")
                                 ht)))))

    ;; Add CORS headers to response
    (when response
      (let ((response-headers (or (getf response :headers) (make-hash-table))))
        (setf (gethash "Access-Control-Allow-Origin" response-headers)
              (or origin "*"))
        (setf (gethash "Access-Control-Allow-Credentials" response-headers)
              "true")
        (setf (getf response :headers) response-headers)))

  (values request response))

;;; ============================================================================
;;; Request/Response Processing
;;; ============================================================================

(defun process-request (chain request)
  "Process a request through a middleware chain.

  Args:
    CHAIN: Middleware chain
    REQUEST: Request plist

  Returns:
    Processed request"
  (multiple-value-bind (new-request new-response)
      (run-middleware-chain chain request nil)
    (declare (ignore new-response))
    new-request))

(defun process-response (chain request response)
  "Process a response through a middleware chain.

  Args:
    CHAIN: Middleware chain
    REQUEST: Request plist
    RESPONSE: Response plist

  Returns:
    Processed response"
  (multiple-value-bind (new-request new-response)
      (run-middleware-chain chain request response)
    (declare (ignore new-request))
    new-response))

;;; ============================================================================
;;; Middleware Factory
;;; ============================================================================

(defun make-request-logging-middleware (&key level)
  "Create a request logging middleware.

  Args:
    LEVEL: Log level

  Returns:
    Middleware instance"
  (make-middleware "request-logging"
                   (lambda (req res)
                     (log-info "[~A] ~A ~A" (getf req :method)
                               (getf req :path)
                               (or (getf req :client-ip) "unknown"))
                     (values req res))
                   :order 100
                   :config (list :level (or level :info))))

(defun make-response-timing-middleware ()
  "Create a response timing middleware.

  Returns:
    Middleware instance"
  (make-middleware "response-timing"
                   (lambda (req res)
                     (let ((start (get-internal-real-time)))
                       (multiple-value-bind (r1 r2)
                           (values req res)
                         (let ((elapsed (/ (* (- (get-internal-real-time) start)
                                              1000)
                                           internal-time-units-per-second)))
                           (when r2
                             (let ((headers (or (getf r2 :headers)
                                                (make-hash-table))))
                               (setf (gethash "X-Response-Time" headers)
                                     (format nil "~,2fms" elapsed))
                               (setf (getf r2 :headers) headers)))
                         (values r1 r2))))
                   :order 900))

(defun make-error-handler-middleware ()
  "Create an error handler middleware.

  Returns:
    Middleware instance"
  (make-middleware "error-handler"
                   (lambda (req res)
                     (handler-case
                         (values req res)
                       (error (e)
                         (log-error "Error in request: ~A" e)
                         (values req
                                 (list :status 500
                                       :body (stringify-json
                                              `(:error "Internal Server Error"
                                                :message ,(format nil "~A" e))))))))
                   :order 50))

(defun make-auth-middleware (&key skip-paths)
  "Create an authentication middleware.

  Args:
    SKIP-PATHS: Paths to skip auth

  Returns:
    Middleware instance"
  (let ((skip (or skip-paths '("/health" "/ready"))))
    (make-middleware "auth"
                     (lambda (req res)
                       (block auth-handler
                         (let ((path (getf req :path)))
                           (when (member path skip :test #'string=)
                             (return-from auth-handler (values req res)))
                           ;; Check auth header
                           (let ((auth (gethash "Authorization"
                                                (or (getf req :headers)
                                                    (make-hash-table)))))
                             (when auth
                               (setf (getf req :authenticated-p) t)
                               (setf (getf req :auth-token) auth)))
                           (values req res))))
                     :order 200
                     :config (list :skip-paths skip))))

(defun make-cors-middleware (&key allowed-origins)
  "Create a CORS middleware.

  Args:
    ALLOWED-ORIGINS: List of allowed origins

  Returns:
    Middleware instance"
  (make-middleware "cors"
                   (lambda (req res)
                     (block cors-handler
                       (let* ((headers (or (getf req :headers) (make-hash-table)))
                              (origin (gethash "Origin" headers))
                              (method (getf req :method)))
                         ;; Handle preflight
                         (when (string= method "OPTIONS")
                           (let ((resp-headers (make-hash-table)))
                             (setf (gethash "Access-Control-Allow-Origin" resp-headers)
                                   (if (member origin allowed-origins :test #'string=)
                                       origin "*"))
                             (setf (gethash "Access-Control-Allow-Methods" resp-headers)
                                   "GET, POST, PUT, DELETE, OPTIONS")
                             (setf (gethash "Access-Control-Allow-Headers" resp-headers)
                                   "Content-Type, Authorization")
                             (return-from cors-handler
                               (values req
                                       (list :status 204
                                             :headers resp-headers)))))
                         ;; Add CORS headers to response
                         (when res
                           (let ((resp-headers (or (getf res :headers)
                                                   (make-hash-table))))
                             (setf (gethash "Access-Control-Allow-Origin" resp-headers)
                                   (if (member origin allowed-origins :test #'string=)
                                       origin "*"))
                             (setf (getf res :headers) resp-headers)))
                         (values req res))))
                   :order 150
                   :config (list :allowed-origins allowed-origins)))

;;; ============================================================================
;;; Registration
;;; ============================================================================

(defun register-built-in-middleware ()
  "Register all built-in middleware.

  Returns:
    T"
  (register-middleware (make-request-logging-middleware))
  (register-middleware (make-response-timing-middleware))
  (register-middleware (make-error-handler-middleware))
  (register-middleware (make-auth-middleware))
  (register-middleware (make-cors-middleware))
  (log-info "Built-in middleware registered")
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-middleware-system ()
  "Initialize the middleware system.

  Returns:
    T"
  (register-built-in-middleware)
  (log-info "Middleware system initialized")
  t)
