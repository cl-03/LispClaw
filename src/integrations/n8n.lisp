;;; integrations/n8n.lisp --- n8n Workflow Automation Integration
;;;
;;; This file provides integration with n8n (https://n8n.io), an open-source
;;; workflow automation tool. It supports:
;;; - Triggering n8n workflows via webhook
;;; - Executing n8n workflows via API
;;; - Receiving callbacks from n8n
;;; - Workflow result processing

(defpackage #:lisp-claw.integrations.n8n
  (:nicknames #:lc.n8n)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.hooks.webhook
        #:lisp-claw.automation.webhook)
  (:export
   ;; Configuration
   #:*n8n-base-url*
   #:*n8n-api-key*
   #:*n8n-webhook-port*
   ;; n8n Workflow class
   #:n8n-workflow
   #:make-n8n-workflow
   #:n8n-workflow-id
   #:n8n-workflow-name
   #:n8n-workflow-active-p
   #:n8n-workflow-tags
   #:n8n-workflow-created-at
   #:n8n-workflow-updated-at
   ;; n8n Execution class
   #:n8n-execution
   #:n8n-execution-id
   #:n8n-execution-workflow-id
   #:n8n-execution-status
   #:n8n-execution-data
   #:n8n-execution-started-at
   #:n8n-execution-finished-at
   ;; Workflow management
   #:get-workflow
   #:list-workflows
   #:activate-workflow
   #:deactivate-workflow
   #:execute-workflow
   #:execute-workflow-async
   #:get-execution
   #:get-executions
   ;; Webhook triggers
   #:register-n8n-webhook
   #:unregister-n8n-webhook
   #:handle-n8n-webhook
   ;; Credential management
   #:get-credentials
   #:set-credentials
   ;; Event triggers
   #:trigger-n8n-event
   #:on-n8n-execution-complete
   ;; Utilities
   #:n8n-api-request
   #:n8n-webhook-url
   #:configure-n8n))

(in-package #:lisp-claw.integrations.n8n)

;;; ============================================================================
;;; Configuration
;;; ============================================================================

(defvar *n8n-base-url* nil
  "Base URL for n8n API (e.g., \"http://localhost:5678\").")

(defvar *n8n-api-key* nil
  "API key for n8n authentication.")

(defvar *n8n-webhook-port* 18792
  "Port for receiving n8n webhooks.")

(defvar *n8n-workflows* (make-hash-table :test 'equal)
  "Cache of n8n workflows.")

(defvar *n8n-executions* (make-hash-table :test 'equal)
  "Cache of n8n executions.")

(defvar *n8n-event-handlers* (make-hash-table :test 'equal)
  "Event handlers for n8n events.")

;;; ============================================================================
;;; n8n Workflow Class
;;; ============================================================================

(defclass n8n-workflow ()
  ((id :initarg :id
       :reader n8n-workflow-id
       :documentation "Workflow ID")
   (name :initarg :name
         :reader n8n-workflow-name
         :documentation "Workflow name")
   (active-p :initarg :active-p
             :initform nil
             :accessor n8n-workflow-active-p
             :documentation "Whether workflow is active")
   (tags :initarg :tags
         :initform nil
         :reader n8n-workflow-tags
         :documentation "Workflow tags")
   (created-at :initarg :created-at
               :initform nil
               :reader n8n-workflow-created-at
               :documentation "Creation timestamp")
   (updated-at :initarg :updated-at
               :initform nil
               :reader n8n-workflow-updated-at
               :documentation "Last update timestamp")
   (nodes :initarg :nodes
          :initform nil
          :reader n8n-workflow-nodes
          :documentation "Workflow nodes")
   (connections :initarg :connections
                :initform nil
                :reader n8n-workflow-connections
                :documentation "Node connections"))
  (:documentation "n8n Workflow representation"))

(defmethod print-object ((workflow n8n-workflow) stream)
  (print-unreadable-object (workflow stream :type t)
    (format t "~A [~A]" (n8n-workflow-name workflow) (n8n-workflow-id workflow))))

(defun make-n8n-workflow (id name &key active-p tags nodes connections)
  "Create an n8n workflow instance.

  Args:
    ID: Workflow ID
    NAME: Workflow name
    ACTIVE-P: Whether active
    TAGS: List of tags
    NODES: Workflow nodes
    CONNECTIONS: Node connections

  Returns:
    n8n-workflow instance"
  (make-instance 'n8n-workflow
                 :id id
                 :name name
                 :active-p active-p
                 :tags tags
                 :nodes nodes
                 :connections connections))

;;; ============================================================================
;;; n8n Execution Class
;;; ============================================================================

(defclass n8n-execution ()
  ((id :initarg :id
       :reader n8n-execution-id
       :documentation "Execution ID")
   (workflow-id :initarg :workflow-id
                :reader n8n-execution-workflow-id
                :documentation "Workflow ID that was executed")
   (status :initarg :status
           :accessor n8n-execution-status
           :documentation "Execution status (success, error, running)")
   (data :initarg :data
         :initform nil
         :accessor n8n-execution-data
         :documentation "Execution input/output data")
   (started-at :initarg :started-at
               :initform nil
               :reader n8n-execution-started-at
               :documentation "Execution start time")
   (finished-at :initarg :finished-at
                :initform nil
                :reader n8n-execution-finished-at
                :documentation "Execution end time")
   (error :initarg :error
          :initform nil
          :accessor n8n-execution-error
          :documentation "Error message if failed"))
  (:documentation "n8n Execution representation"))

(defmethod print-object ((execution n8n-execution) stream)
  (print-unreadable-object (execution stream :type t)
    (format t "~A [~A]" (n8n-execution-id execution) (n8n-execution-status execution))))

(defun make-n8n-execution (id workflow-id status &key data started-at finished-at error)
  "Create an n8n execution instance.

  Args:
    ID: Execution ID
    WORKFLOW-ID: Executed workflow ID
    STATUS: Execution status
    DATA: Execution data
    STARTED-AT: Start timestamp
    FINISHED-AT: End timestamp
    ERROR: Error message

  Returns:
    n8n-execution instance"
  (make-instance 'n8n-execution
                 :id id
                 :workflow-id workflow-id
                 :status status
                 :data data
                 :started-at started-at
                 :finished-at finished-at
                 :error error))

;;; ============================================================================
;;; Configuration
;;; ============================================================================

(defun configure-n8n (&key base-url api-key webhook-port)
  "Configure n8n integration.

  Args:
    BASE-URL: n8n server URL (e.g., \"http://localhost:5678\")
    API-KEY: n8n API key
    WEBHOOK-PORT: Port for receiving webhooks

  Returns:
    T on success"
  (when base-url
    (setf *n8n-base-url* base-url))
  (when api-key
    (setf *n8n-api-key* api-key))
  (when webhook-port
    (setf *n8n-webhook-port* webhook-port))
  (log-info "n8n configured: ~A" *n8n-base-url*)
  t)

;;; ============================================================================
;;; API Client
;;; ============================================================================

(defun n8n-api-request (endpoint &key method body params)
  "Make a request to the n8n API.

  Args:
    ENDPOINT: API endpoint (e.g., \"/workflows\")
    METHOD: HTTP method (default: GET)
    BODY: Request body (plist, will be JSON-encoded)
    PARAMS: URL query parameters (alist)

  Returns:
    Response as alist, or NIL on error"
  (unless *n8n-base-url*
    (error "n8n not configured. Call (configure-n8n) first."))

  (let* ((url (format nil "~A/api/v1~A" *n8n-base-url* endpoint))
         (headers (list (cons "Content-Type" "application/json")))
         (method (or method :get)))

    ;; Add API key authentication
    (when *n8n-api-key*
      (push (cons "X-N8N-API-Key" *n8n-api-key*) headers))

    ;; Build query string
    (when params
      (let ((query (format nil "?~{~A=~A~^&~}"
                           (loop for (k . v) in params
                                 collect (cons k v)))))
        (setf url (concatenate 'string url query))))

    ;; Prepare body
    (let ((body-str (when body (stringify-json body))))
      (handler-case
          (let ((response (ecase method
                            (:get (dex:get url :headers headers))
                            (:post (dex:post url :headers headers :content body-str))
                            (:put (dex:put url :headers headers :content body-str))
                            (:delete (dex:delete url :headers headers :content body-str))
                            (:patch (dex:patch url :headers headers :content body-str)))))
            (log-debug "n8n API ~A ~A -> ~A" method endpoint response)
            (parse-json response))
        (error (e)
          (log-error "n8n API request failed: ~A - ~A" endpoint e)
          nil)))))

(defun n8n-webhook-url (&key (port *n8n-webhook-port*) (host "127.0.0.1"))
  "Generate the webhook URL for n8n callbacks.

  Args:
    PORT: Webhook port
    HOST: Webhook host

  Returns:
    Webhook URL string"
  (format nil "http://~A:~A/n8n/webhook" host port))

;;; ============================================================================
;;; Workflow Management
;;; ============================================================================

(defun get-workflow (workflow-id)
  "Get a workflow by ID.

  Args:
    WORKFLOW-ID: Workflow ID

  Returns:
    n8n-workflow instance or NIL"
  ;; Check cache first
  (let ((cached (gethash workflow-id *n8n-workflows*)))
    (when cached
      (return-from get-workflow cached))))

  ;; Fetch from API
  (let ((data (n8n-api-request (format nil "/workflows/~A" workflow-id))))
    (when data
      (let ((workflow (make-n8n-workflow
                       (json-get data :id)
                       (json-get data :name)
                       :active-p (json-get data :active)
                       :tags (json-get data :tags)
                       :nodes (json-get data :nodes)
                       :connections (json-get data :connections))))
        (setf (gethash workflow-id *n8n-workflows*) workflow)
        workflow))))

(defun list-workflows (&key active-only tags)
  "List workflows.

  Args:
    ACTIVE-ONLY: If true, only return active workflows
    TAGS: Filter by tags (list)

  Returns:
    List of n8n-workflow instances"
  (let ((data (n8n-api-request "/workflows")))
    (when data
      (let ((workflows
             (loop for wf-data across (if (vectorp data) data (coerce data 'vector))
                   for wf = (make-n8n-workflow
                             (json-get wf-data :id)
                             (json-get wf-data :name)
                             :active-p (json-get wf-data :active)
                             :tags (json-get wf-data :tags))
                   when (and (or (not active-only) (n8n-workflow-active-p wf))
                             (or (not tags)
                                 (intersection tags (n8n-workflow-tags wf) :test #'string=)))
                   collect wf)))
        ;; Update cache
        (dolist (wf workflows)
          (setf (gethash (n8n-workflow-id wf) *n8n-workflows*) wf))
        workflows))))

(defun activate-workflow (workflow-id)
  "Activate a workflow.

  Args:
    WORKFLOW-ID: Workflow ID

  Returns:
    T on success"
  (let ((data (n8n-api-request (format nil "/workflows/~A/active" workflow-id)
                               :method :put
                               :body '(:active t))))
    (when data
      ;; Update cache
      (let ((cached (gethash workflow-id *n8n-workflows*)))
        (when cached
          (setf (slot-value cached 'n8n-workflow-active-p) t)))
      t)))

(defun deactivate-workflow (workflow-id)
  "Deactivate a workflow.

  Args:
    WORKFLOW-ID: Workflow ID

  Returns:
    T on success"
  (let ((data (n8n-api-request (format nil "/workflows/~A/active" workflow-id)
                               :method :put
                               :body '(:active nil))))
    (when data
      ;; Update cache
      (let ((cached (gethash workflow-id *n8n-workflows*)))
        (when cached
          (setf (slot-value cached 'n8n-workflow-active-p) nil)))
      t)))

;;; ============================================================================
;;; Workflow Execution
;;; ============================================================================

(defun execute-workflow (workflow-id &key data wait-timeout)
  "Execute a workflow synchronously.

  Args:
    WORKFLOW-ID: Workflow ID to execute
    DATA: Input data for the workflow (plist)
    WAIT-TIMEOUT: Maximum time to wait for execution (seconds, default: 60)

  Returns:
    n8n-execution instance with result data"
  (let ((body (append '(:workflowId workflow-id)
                      (when data (list :data data)))))
    (let ((data (n8n-api-request "/executions"
                                 :method :post
                                 :body body)))
      (when data
        (let ((execution (make-n8n-execution
                          (json-get data :id)
                          workflow-id
                          (json-get data :status)
                          :data (json-get data :data)
                          :started-at (json-get data :startedAt)
                          :finished-at (json-get data :finishedAt)
                          :error (json-get data :error))))
          ;; Cache execution
          (setf (gethash (n8n-execution-id execution) *n8n-executions*) execution)
          execution)))))

(defun execute-workflow-async (workflow-id &key data)
  "Execute a workflow asynchronously.

  Args:
    WORKFLOW-ID: Workflow ID to execute
    DATA: Input data for the workflow (plist)

  Returns:
    Execution ID (string)"
  (let ((body (append '(:workflowId workflow-id)
                      (when data (list :data data))
                      '(:async t))))
    (let ((data (n8n-api-request "/executions"
                                 :method :post
                                 :body body)))
      (when data
        (let ((execution-id (json-get data :id)))
          ;; Create pending execution
          (let ((execution (make-n8n-execution execution-id workflow-id "running" :data data)))
            (setf (gethash execution-id *n8n-executions*) execution))
          execution-id)))))

(defun get-execution (execution-id)
  "Get execution status and result.

  Args:
    EXECUTION-ID: Execution ID

  Returns:
    n8n-execution instance or NIL"
  ;; Check cache first
  (let ((cached (gethash execution-id *n8n-executions*)))
    (when (and cached
               (member (n8n-execution-status cached) '("success" "error") :test #'string=))
      (return-from get-execution cached))))

  ;; Fetch from API
  (let ((data (n8n-api-request (format nil "/executions/~A" execution-id))))
    (when data
      (let ((execution (make-n8n-execution
                        (json-get data :id)
                        (json-get data :workflowId)
                        (json-get data :status)
                        :data (json-get data :data)
                        :started-at (json-get data :startedAt)
                        :finished-at (json-get data :finishedAt)
                        :error (json-get data :error))))
        ;; Update cache
        (setf (gethash execution-id *n8n-executions*) execution)
        execution))))

(defun get-executions (&key workflow-id status limit)
  "Get list of executions.

  Args:
    WORKFLOW-ID: Filter by workflow ID
    STATUS: Filter by status
    LIMIT: Maximum results (default: 100)

  Returns:
    List of n8n-execution instances"
  (let ((params (list (cons 'limit (or limit 100)))))
    (when workflow-id
      (push (cons 'workflowId workflow-id) params))
    (when status
      (push (cons 'status status) params))

    (let ((data (n8n-api-request "/executions" :params params)))
      (when data
        (loop for exec-data across (if (vectorp data) data (coerce data 'vector))
              collect (make-n8n-execution
                       (json-get exec-data :id)
                       (json-get exec-data :workflowId)
                       (json-get exec-data :status)
                       :data (json-get exec-data :data)
                       :started-at (json-get exec-data :startedAt)
                       :finished-at (json-get exec-data :finishedAt)
                       :error (json-get exec-data :error)))))))

;;; ============================================================================
;;; Webhook Integration
;;; ============================================================================

(defun register-n8n-webhook (&optional handler)
  "Register a webhook handler for n8n callbacks.

  Args:
    HANDLER: Optional custom handler function (default: handle-n8n-webhook)

  Returns:
    Webhook URL string"
  (let ((handler (or handler #'handle-n8n-webhook)))
    ;; Register with automation/webhook system
    (let ((webhook (make-webhook "n8n-callback" "/n8n/webhook" handler)))
      (register-webhook webhook))
    (n8n-webhook-url)))

(defun unregister-n8n-webhook ()
  "Unregister the n8n webhook handler.

  Returns:
    T on success"
  (unregister-webhook "n8n-callback"))

(defun handle-n8n-webhook (request)
  "Handle an incoming webhook from n8n.

  Args:
    REQUEST: Request plist with :body, :headers, :path

  Returns:
    Response plist"
  (let* ((body (getf request :body))
         (data (if (stringp body) (parse-json body) body))
         (event-type (json-get data :event))
         (execution-data (json-get data :execution)))

    (log-info "Received n8n webhook: ~A" event-type)

    ;; Process different event types
    (ecase (keywordize event-type)
      (:execution:completed
       (handle-execution-completed execution-data))
      (:execution:failed
       (handle-execution-failed execution-data))
      (:workflow:activated
       (handle-workflow-activated execution-data))
      (:workflow:deactivated
       (handle-workflow-deactivated execution-data))
      (t
       (log-warn "Unknown n8n event type: ~A" event-type)))

    ;; Trigger registered event handlers
    (trigger-n8n-event (keywordize event-type) data)

    '(:status 200 :body "OK")))

(defun handle-execution-completed (execution-data)
  "Handle execution completed event.

  Args:
    EXECUTION-DATA: Execution data from n8n"
  (let* ((execution-id (json-get execution-data :id))
         (workflow-id (json-get execution-data :workflowId))
         (result-data (json-get execution-data :data)))

    ;; Update cached execution
    (let ((cached (gethash execution-id *n8n-executions*)))
      (if cached
          (progn
            (setf (n8n-execution-status cached) "success")
            (setf (n8n-execution-data cached) result-data))
          (setf (gethash execution-id *n8n-executions*)
                (make-n8n-execution execution-id workflow-id "success" :data result-data))))

    (log-info "n8n execution completed: ~A for workflow ~A" execution-id workflow-id)))

(defun handle-execution-failed (execution-data)
  "Handle execution failed event.

  Args:
    EXECUTION-DATA: Execution data from n8n"
  (let* ((execution-id (json-get execution-data :id))
         (workflow-id (json-get execution-data :workflowId))
         (error (json-get execution-data :error)))

    ;; Update cached execution
    (let ((cached (gethash execution-id *n8n-executions*)))
      (if cached
          (progn
            (setf (n8n-execution-status cached) "error")
            (setf (n8n-execution-error cached) error))
          (setf (gethash execution-id *n8n-executions*)
                (make-n8n-execution execution-id workflow-id "error" :error error))))

    (log-error "n8n execution failed: ~A for workflow ~A - ~A"
               execution-id workflow-id error)))

(defun handle-workflow-activated (workflow-data)
  "Handle workflow activated event.

  Args:
    WORKFLOW-DATA: Workflow data from n8n"
  (let ((workflow-id (json-get workflow-data :id)))
    (let ((cached (gethash workflow-id *n8n-workflows*)))
      (when cached
        (setf (n8n-workflow-active-p cached) t)))
    (log-info "n8n workflow activated: ~A" workflow-id)))

(defun handle-workflow-deactivated (workflow-data)
  "Handle workflow deactivated event.

  Args:
    WORKFLOW-DATA: Workflow data from n8n"
  (let ((workflow-id (json-get workflow-data :id)))
    (let ((cached (gethash workflow-id *n8n-workflows*)))
      (when cached
        (setf (n8n-workflow-active-p cached) nil)))
    (log-info "n8n workflow deactivated: ~A" workflow-id)))

;;; ============================================================================
;;; Event System
;;; ============================================================================

(defun on-n8n-execution-complete (handler)
  "Register a handler for execution complete events.

  Args:
    HANDLER: Function to call when execution completes

  Returns:
    T"
  (push handler (gethash :execution:completed *n8n-event-handlers*))
  t)

(defun trigger-n8n-event (event-type data)
  "Trigger handlers for an n8n event.

  Args:
    EVENT-TYPE: Event keyword
    DATA: Event data

  Returns:
    List of handler results"
  (let ((handlers (gethash event-type *n8n-event-handlers*)))
    (when handlers
      (loop for handler in handlers
            collect (handler-case
                        (funcall handler data)
                      (error (e)
                        (log-error "n8n event handler error: ~A" e)))))))

;;; ============================================================================
;;; Credential Management
;;; ============================================================================

(defun get-credentials (credential-id)
  "Get n8n credentials by ID.

  Args:
    CREDENTIAL-ID: Credential ID

  Returns:
    Credential data plist or NIL"
  (let ((data (n8n-api-request (format nil "/credentials/~A" credential-id))))
    (when data
      (list :id (json-get data :id)
            :name (json-get data :name)
            :type (json-get data :type)
            :data (json-get data :data)))))

(defun set-credentials (name type data)
  "Create or update credentials.

  Args:
    NAME: Credential name
    TYPE: Credential type (e.g., \"httpBasicAuth\", \"oAuth2Api\")
    DATA: Credential data plist

  Returns:
    Credential ID on success"
  (let ((body (list :name name
                    :type type
                    :data data)))
    (let ((result (n8n-api-request "/credentials"
                                   :method :post
                                   :body body)))
      (when result
        (json-get result :id)))))

;;; ============================================================================
;;; Integration with Lisp-Claw Tools
;;; ============================================================================

(defun register-n8n-tools ()
  "Register n8n tools with the tool system.

  Returns:
    T"
  ;; These would be registered with lisp-claw.tools:register-tool
  ;; For now, just log that we would register them
  (log-info "n8n tools available: execute-workflow, get-workflow, list-workflows, get-execution")
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-n8n-integration ()
  "Initialize the n8n integration.

  Returns:
    T"
  (log-info "n8n integration initialized")
  (register-n8n-webhook)
  (register-n8n-tools)
  t)
