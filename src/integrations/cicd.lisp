;;; integrations/cicd.lisp --- CI/CD Integration for Lisp-Claw
;;;
;;; This file provides integration with CI/CD platforms:
;;; - GitHub Actions - Workflow triggers, status checks, run logs
;;; - GitLab CI - Pipeline triggers, job status, merge request checks
;;; - Generic webhooks - CI/CD agnostic webhook handling
;;;
;;; Features:
;;; - Trigger CI/CD pipelines from Lisp-Claw
;;; - Receive CI/CD status callbacks
;;; - Report status to AI conversations
;;; - Automated code quality checks

(defpackage #:lisp-claw.integrations.cicd
  (:nicknames #:lc.cicd)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.crypto
        #:lisp-claw.hooks.webhook)
  (:export
   ;; Configuration
   #:*github-token*
   #:*gitlab-token*
   #:*cicd-webhook-port*
   ;; GitHub Actions
   #:github-trigger-workflow
   #:github-get-workflow-runs
   #:github-get-job-logs
   #:github-create-check-run
   #:github-update-check-run
   #:github-list-workflows
   #:github-get-workflow
   ;; GitLab CI
   #:gitlab-trigger-pipeline
   #:gitlab-get-pipeline-status
   #:gitlab-get-job-logs
   #:gitlab-list-pipelines
   #:gitlab-get-bridge-status
   ;; CI/CD Status
   #:cicd-status
   #:make-cicd-status
   #:cicd-status-platform
   #:cicd-status-repository
   #:cicd-status-state
   #:cicd-status-sha
   #:cicd-status-target-url
   #:cicd-status-description
   ;; Webhook handlers
   #:register-cicd-webhook
   #:handle-github-webhook
   #:handle-gitlab-webhook
   #:handle-cicd-webhook
   ;; Configuration
   #:configure-github
   #:configure-gitlab
   #:configure-cicd
   ;; Utilities
   #:github-api-request
   #:gitlab-api-request
   #:parse-ci-event
   #:format-cicd-status))

(in-package #:lisp-claw.integrations.cicd)

;;; ============================================================================
;;; Configuration
;;; ============================================================================

(defvar *github-token* nil
  "GitHub personal access token for API authentication.")

(defvar *gitlab-token* nil
  "GitLab personal access token for API authentication.")

(defvar *cicd-webhook-port* 18793
  "Port for receiving CI/CD webhooks.")

(defvar *github-api-base* "https://api.github.com"
  "GitHub API base URL.")

(defvar *gitlab-api-base* nil
  "GitLab API base URL (e.g., \"https://gitlab.com/api/v4\").")

(defvar *cicd-repositories* (make-hash-table :test 'equal)
  "Repository configurations for CI/CD.")

(defvar *cicd-status-cache* (make-array 100 :adjustable t :fill-pointer 0)
  "Cache of CI/CD status updates.")

;;; ============================================================================
;;; CI/CD Status Class
;;; ============================================================================

(defclass cicd-status ()
  ((platform :initarg :platform
             :reader cicd-status-platform
             :documentation "Platform (github, gitlab, generic)")
   (repository :initarg :repository
               :reader cicd-status-repository
               :documentation "Repository name (owner/repo)")
   (state :initarg :state
          :accessor cicd-status-state
          :documentation "Status state (pending, success, failure, error)")
   (sha :initarg :sha
        :reader cicd-status-sha
        :documentation "Commit SHA")
   (target-url :initarg :target-url
               :initform nil
               :reader cicd-status-target-url
               :documentation "URL with detailed status")
   (description :initarg :description
                :initform nil
                :reader cicd-status-description
                :documentation "Status description")
   (context :initarg :context
            :initform "lisp-claw/ci"
            :reader cicd-status-context
            :documentation "Status context")
   (created-at :initform (get-universal-time)
               :reader cicd-status-created-at
               :documentation "Status creation time"))
  (:documentation "CI/CD status representation"))

(defmethod print-object ((status cicd-status) stream)
  (print-unreadable-object (status stream :type t)
    (format t "~A/~A [~A]" (cicd-status-platform status)
            (cicd-status-repository status)
            (cicd-status-state status))))

(defun make-cicd-status (platform repository state sha &key target-url description context)
  "Create a CI/CD status instance.

  Args:
    PLATFORM: Platform keyword (:github, :gitlab, :generic)
    REPOSITORY: Repository name (e.g., \"owner/repo\")
    STATE: Status state (:pending, :success, :failure, :error)
    SHA: Commit SHA
    TARGET-URL: Optional URL for details
    DESCRIPTION: Optional description
    CONTEXT: Optional context (default: \"lisp-claw/ci\")

  Returns:
    cicd-status instance"
  (make-instance 'cicd-status
                 :platform platform
                 :repository repository
                 :state (string-downcase (symbol-name state))
                 :sha sha
                 :target-url target-url
                 :description description
                 :context (or context "lisp-claw/ci")))

;;; ============================================================================
;;; Configuration
;;; ============================================================================

(defun configure-github (&key token api-base)
  "Configure GitHub integration.

  Args:
    TOKEN: GitHub personal access token
    API-BASE: Optional custom API base URL

  Returns:
    T on success"
  (when token
    (setf *github-token* token))
  (when api-base
    (setf *github-api-base* api-base))
  (log-info "GitHub CI/CD integration configured")
  t)

(defun configure-gitlab (&key token api-base)
  "Configure GitLab integration.

  Args:
    TOKEN: GitLab personal access token
    API-BASE: Optional custom API base URL (default: GitLab SaaS)

  Returns:
    T on success"
  (when token
    (setf *gitlab-token* token))
  (when api-base
    (setf *gitlab-api-base* api-base))
  (unless *gitlab-api-base*
    (setf *gitlab-api-base* "https://gitlab.com/api/v4"))
  (log-info "GitLab CI/CD integration configured")
  t)

(defun configure-cicd (&key github-token gitlab-token webhook-port)
  "Configure CI/CD integration.

  Args:
    GITHUB-TOKEN: GitHub token
    GITLAB-TOKEN: GitLab token
    WEBHOOK-PORT: Webhook port for callbacks

  Returns:
    T on success"
  (when github-token
    (configure-github :token github-token))
  (when gitlab-token
    (configure-gitlab :token gitlab-token))
  (when webhook-port
    (setf *cicd-webhook-port* webhook-port))
  (log-info "CI/CD integration configured")
  t)

;;; ============================================================================
;;; API Client
;;; ============================================================================

(defun github-api-request (endpoint &key method body headers accept)
  "Make a request to the GitHub API.

  Args:
    ENDPOINT: API endpoint (e.g., \"/repos/owner/repo/actions/workflows\")
    METHOD: HTTP method (default: GET)
    BODY: Request body (plist)
    HEADERS: Additional headers
    ACCEPT: Accept header (default: application/vnd.github.v3+json)

  Returns:
    Response as alist, or NIL on error"
  (unless *github-token*
    (error "GitHub token not configured. Call (configure-github) first."))

  (let* ((url (format nil "~A~A" *github-api-base* endpoint))
         (request-headers (append headers
                                  (list (cons "Authorization" (format nil "token ~A" *github-token*))
                                        (cons "Accept" (or accept "application/vnd.github.v3+json"))))))
    (let ((method (or method :get)))
      (handler-case
          (let ((response (ecase method
                            (:get (dex:get url :headers request-headers))
                            (:post (dex:post url :headers request-headers
                                             :content (when body (stringify-json body))))
                            (:put (dex:put url :headers request-headers
                                           :content (when body (stringify-json body))))
                            (:patch (dex:patch url :headers request-headers
                                               :content (when body (stringify-json body))))
                            (:delete (dex:delete url :headers request-headers)))))
            (log-debug "GitHub API ~A ~A -> ~A" method endpoint response)
            (parse-json response))
        (error (e)
          (log-error "GitHub API request failed: ~A - ~A" endpoint e)
          nil)))))

(defun gitlab-api-request (endpoint &key method body headers)
  "Make a request to the GitLab API.

  Args:
    ENDPOINT: API endpoint
    METHOD: HTTP method (default: GET)
    BODY: Request body (plist)
    HEADERS: Additional headers

  Returns:
    Response as alist, or NIL on error"
  (unless *gitlab-token*
    (error "GitLab token not configured. Call (configure-gitlab) first."))

  (let* ((url (format nil "~A~A" *gitlab-api-base* endpoint))
         (request-headers (append headers
                                  (list (cons "PRIVATE-TOKEN" *gitlab-token*)
                                        (cons "Content-Type" "application/json")))))
    (let ((method (or method :get)))
      (handler-case
          (let ((response (ecase method
                            (:get (dex:get url :headers request-headers))
                            (:post (dex:post url :headers request-headers
                                             :content (when body (stringify-json body))))
                            (:put (dex:put url :headers request-headers
                                           :content (when body (stringify-json body))))
                            (:delete (dex:delete url :headers request-headers)))))
            (log-debug "GitLab API ~A ~A -> ~A" method endpoint response)
            (parse-json response))
        (error (e)
          (log-error "GitLab API request failed: ~A - ~A" endpoint e)
          nil)))))

;;; ============================================================================
;;; GitHub Actions
;;; ============================================================================

(defun github-list-workflows (owner repo)
  "List GitHub Actions workflows.

  Args:
    OWNER: Repository owner
    REPO: Repository name

  Returns:
    List of workflow plists"
  (let ((endpoint (format nil "/repos/~A/~A/actions/workflows" owner repo)))
    (let ((data (github-api-request endpoint)))
      (when data
        (let ((workflows (json-get data :workflows)))
          (loop for wf across (if (vectorp workflows) workflows (coerce workflows 'vector))
                collect (list :id (json-get wf :id)
                              :name (json-get wf :name)
                              :path (json-get wf :path)
                              :state (json-get wf :state))))))))

(defun github-get-workflow (owner repo workflow-id)
  "Get a GitHub Actions workflow.

  Args:
    OWNER: Repository owner
    REPO: Repository name
    WORKFLOW-ID: Workflow ID or filename

  Returns:
    Workflow data plist"
  (let ((endpoint (format nil "/repos/~A/~A/actions/workflows/~A" owner repo workflow-id)))
    (let ((data (github-api-request endpoint)))
      (when data
        (list :id (json-get data :id)
              :name (json-get data :name)
              :path (json-get data :path)
              :state (json-get data :state)
              :created-at (json-get data :created_at)
              :updated-at (json-get data :updated_at))))))

(defun github-trigger-workflow (owner repo workflow-id ref &key inputs)
  "Trigger a GitHub Actions workflow.

  Args:
    OWNER: Repository owner
    REPO: Repository name
    WORKFLOW-ID: Workflow ID or filename
    REF: Git reference (branch or tag)
    INPUTS: Optional workflow inputs (plist)

  Returns:
    Run ID on success, NIL on error"
  (let ((endpoint (format nil "/repos/~A/~A/actions/workflows/~A/dispatches" owner repo workflow-id)))
    (let ((body (append '(:ref ref)
                        (when inputs (list :inputs inputs)))))
      (let ((data (github-api-request endpoint :method :post :body body)))
        (when data
          (log-info "GitHub workflow triggered: ~A/~A - ~A" owner repo workflow-id)
          t)))))

(defun github-get-workflow-runs (owner repo &key workflow-id branch status limit)
  "Get workflow runs.

  Args:
    OWNER: Repository owner
    REPO: Repository name
    WORKFLOW-ID: Optional workflow filter
    BRANCH: Optional branch filter
    STATUS: Optional status filter (queued, in_progress, completed)
    LIMIT: Maximum results

  Returns:
    List of run plists"
  (let* ((endpoint (if workflow-id
                       (format nil "/repos/~A/~A/actions/workflows/~A/runs" owner repo workflow-id)
                       (format nil "/repos/~A/~A/actions/runs" owner repo)))
         (params (append (when branch (list (cons 'branch branch)))
                         (when status (list (cons 'status status)))
                         (when limit (list (cons 'per_page limit))))))
    (when params
      (setf endpoint (format nil "~A?~{~A=~A~^&~}" endpoint params)))
    (let ((data (github-api-request endpoint)))
      (when data
        (let ((runs (json-get data :workflow_runs)))
          (loop for run across (if (vectorp runs) runs (coerce runs 'vector))
                collect (list :id (json-get run :id)
                              :status (json-get run :status)
                              :conclusion (json-get run :conclusion)
                              :head-branch (json-get run :head_branch)
                              :head-sha (json-get run :head_sha)
                              :created-at (json-get run :created_at)
                              :updated-at (json-get run :updated_at))))))))

(defun github-get-job-logs (owner repo job-id)
  "Get logs for a workflow job.

  Args:
    OWNER: Repository owner
    REPO: Repository name
    JOB-ID: Job ID

  Returns:
    Log content as string"
  (let ((endpoint (format nil "/repos/~A/~A/actions/jobs/~A/logs" owner repo job-id)))
    (handler-case
        (dex:get (format nil "~A~A" *github-api-base* endpoint)
                 :headers (list (cons "Authorization" (format nil "token ~A" *github-token*))
                                (cons "Accept" "application/vnd.github.v3+json")))
      (error (e)
        (log-error "Failed to get job logs: ~A" e)
        nil))))

(defun github-create-check-run (owner repo sha name status &key details-url output actions)
  "Create a check run.

  Args:
    OWNER: Repository owner
    REPO: Repository name
    SHA: Commit SHA
    NAME: Check name
    STATUS: Check status (queued, in_progress, completed)
    DETAILS-URL: Optional details URL
    OUTPUT: Check output (alist with title, summary, text)
    ACTIONS: Optional actions

  Returns:
    Check run ID"
  (let ((endpoint (format nil "/repos/~A/~A/check-runs" owner repo)))
    (let ((body (append
                 '(:name name :sha sha :status status)
                 (when details-url (list :details_url details-url))
                 (when output (list :output output))
                 (when actions (list :actions actions)))))
      (let ((data (github-api-request endpoint :method :post :body body
                                      :accept "application/vnd.github.antiope-preview+json")))
        (when data
          (json-get data :id))))))

(defun github-update-check-run (owner repo check-run-id &key status conclusion output actions)
  "Update a check run.

  Args:
    OWNER: Repository owner
    REPO: Repository name
    CHECK-RUN-ID: Check run ID
    STATUS: New status
    CONCLUSION: Conclusion (success, failure, neutral, etc.)
    OUTPUT: Updated output
    ACTIONS: Updated actions

  Returns:
    T on success"
  (let ((endpoint (format nil "/repos/~A/~A/check-runs/~A" owner repo check-run-id)))
    (let ((body (append
                 (when status (list :status status))
                 (when conclusion (list :conclusion conclusion))
                 (when output (list :output output))
                 (when actions (list :actions actions)))))
      (let ((data (github-api-request endpoint :method :patch :body body
                                      :accept "application/vnd.github.antiope-preview+json")))
        (when data
          t))))))

;;; ============================================================================
;;; GitLab CI
;;; ============================================================================

(defun gitlab-list-pipelines (project-id &key branch status scope limit)
  "List GitLab CI pipelines.

  Args:
    PROJECT-ID: Project ID or URL-encoded path
    BRANCH: Optional branch filter
    STATUS: Optional status filter
    SCOPE: Optional scope (running, pending, finished, tags)
    LIMIT: Maximum results

  Returns:
    List of pipeline plists"
  (let* ((endpoint (format nil "/projects/~A/pipelines" project-id))
         (params (append (when branch (list (cons 'ref branch)))
                         (when status (list (cons 'status status)))
                         (when scope (list (cons 'scope scope)))
                         (when limit (list (cons 'per_page limit))))))
    (when params
      (setf endpoint (format nil "~A?~{~A=~A~^&~}" endpoint params)))
    (let ((data (gitlab-api-request endpoint)))
      (when data
        (loop for pipeline across (if (vectorp data) data (coerce data 'vector))
              collect (list :id (json-get pipeline :id)
                            :sha (json-get pipeline :sha)
                            :ref (json-get pipeline :ref)
                            :status (json-get pipeline :status)
                            :source (json-get pipeline :source)
                            :created-at (json-get pipeline :created_at)))))))

(defun gitlab-trigger-pipeline (project-id ref &key variables)
  "Trigger a GitLab CI pipeline.

  Args:
    PROJECT-ID: Project ID or URL-encoded path
    REF: Branch or tag to build
    VARIABLES: Optional pipeline variables (plist)

  Returns:
    Pipeline ID on success"
  (let ((endpoint (format nil "/projects/~A/trigger/pipeline" project-id)))
    (let ((body (append
                 '(:ref ref)
                 (when variables
                   (list :variables (loop for (k . v) in variables
                                          collect (cons (string k) v)))))))
      (let ((data (gitlab-api-request endpoint :method :post :body body)))
        (when data
          (log-info "GitLab pipeline triggered: ~A - ~A" project-id ref)
          (list :id (json-get data :id)
                :status (json-get data :status)))))))

(defun gitlab-get-pipeline-status (project-id pipeline-id)
  "Get pipeline status.

  Args:
    PROJECT-ID: Project ID
    PIPELINE-ID: Pipeline ID

  Returns:
    Status plist"
  (let ((endpoint (format nil "/projects/~A/pipelines/~A" project-id pipeline-id)))
    (let ((data (gitlab-api-request endpoint)))
      (when data
        (list :id (json-get data :id)
              :status (json-get data :status)
              :ref (json-get data :ref)
              :sha (json-get data :sha)
              :source (json-get data :source)
              :created-at (json-get data :created_at)
              :updated-at (json-get data :updated_at)
              :duration (json-get data :duration)))))

(defun gitlab-get-job-logs (project-id job-id)
  "Get logs for a CI job.

  Args:
    PROJECT-ID: Project ID
    JOB-ID: Job ID

  Returns:
    Log content as string"
  (let ((endpoint (format nil "/projects/~A/jobs/~A/trace" project-id job-id)))
    (handler-case
        (dex:get (format nil "~A~A" *gitlab-api-base* endpoint)
                 :headers (list (cons "PRIVATE-TOKEN" *gitlab-token*)))
      (error (e)
        (log-error "Failed to get job logs: ~A" e)
        nil))))

;;; ============================================================================
;;; Webhook Handlers
;;; ============================================================================

(defvar *cicd-event-handlers* (make-hash-table :test 'equal)
  "Handlers for CI/CD events.")

(defun register-cicd-event-handler (event-type handler)
  "Register a handler for a CI/CD event.

  Args:
    EVENT-TYPE: Event keyword
    HANDLER: Handler function

  Returns:
    T"
  (push handler (gethash event-type *cicd-event-handlers*))
  t)

(defun register-cicd-webhook (&optional port)
  "Register CI/CD webhook handler.

  Args:
    PORT: Optional port (default: *cicd-webhook-port*)

  Returns:
    Webhook URL"
  (let ((port (or port *cicd-webhook-port*)))
    ;; Register webhook path
    (let ((webhook (make-webhook "cicd-webhook" "/cicd/webhook" #'handle-cicd-webhook)))
      (register-webhook webhook))
    (format nil "http://localhost:~A/cicd/webhook" port)))

(defun handle-cicd-webhook (request)
  "Handle incoming CI/CD webhook.

  Args:
    REQUEST: Request plist

  Returns:
    Response plist"
  (let* ((headers (getf request :headers))
         (body (getf request :body))
         (data (if (stringp body) (parse-json body) body))
         (event-type (or (gethash "X-GitHub-Event" headers)
                         (gethash "x-gitlab-event" headers)
                         "unknown")))
    (log-info "Received CI/CD webhook: ~A" event-type)

    ;; Parse event
    (let ((parsed (parse-ci-event event-type data headers)))
      ;; Store status
      (when (getf parsed :status)
        (store-cicd-status (getf parsed :status)))

      ;; Trigger handlers
      (let ((handlers (gethash (getf parsed :event-type) *cicd-event-handlers*)))
        (when handlers
          (dolist (handler handlers)
            (handler-case
                (funcall handler parsed)
              (error (e)
                (log-error "CI/CD event handler error: ~A" e)))))))

    '(:status 200 :body "OK")))

(defun handle-github-webhook (request)
  "Handle GitHub webhook.

  Args:
    REQUEST: Request plist

  Returns:
    Response plist"
  (let* ((headers (getf request :headers))
         (body (getf request :body))
         (event (gethash "X-GitHub-Event" headers))
         (data (if (stringp body) (parse-json body) body)))
    (log-info "GitHub webhook: ~A" event)

    (cond
      ((string= event "check_run")
       (handle-check-run-event data))
      ((string= event "workflow_run")
       (handle-workflow-run-event data))
      ((string= event "status")
       (handle-status-event data)))

    '(:status 200 :body "OK")))

(defun handle-gitlab-webhook (request)
  "Handle GitLab webhook.

  Args:
    REQUEST: Request plist

  Returns:
    Response plist"
  (let* ((body (getf request :body))
         (data (if (stringp body) (parse-json body) body))
         (object-kind (json-get data :object_kind)))
    (log-info "GitLab webhook: ~A" object-kind)

    (cond
      ((string= object-kind "pipeline")
       (handle-pipeline-event data))
      ((string= object-kind "build")
       (handle-build-event data)))

    '(:status 200 :body "OK")))

(defun parse-ci-event (event-type data headers)
  "Parse a CI/CD event.

  Args:
    EVENT-TYPE: Event type string
    DATA: Event data
    HEADERS: Request headers

  Returns:
    Parsed event plist"
  (cond
    ;; GitHub check_run event
    ((string= event-type "check_run")
     (let ((action (json-get data :action))
           (check-run (json-get data :check_run))
           (repo (json-get data :repository)))
       (list :event-type :check-run
             :platform :github
             :action action
             :status (make-cicd-status
                      :github
                      (format nil "~A/~A" (json-get repo :owner :login) (json-get repo :name))
                      (ecase (keywordize (string-downcase (json-get check-run :status)))
                        (:queued :pending)
                        (:in_progress :pending)
                        (:completed :success))
                      (json-get data :check_run :head_sha)
                      :target-url (json-get check-run :details_url)
                      :description (json-get check-run :output :summary)))))

    ;; GitHub workflow_run event
    ((string= event-type "workflow_run")
     (let ((workflow-run (json-get data :workflow_run))
           (repo (json-get data :repository)))
       (list :event-type :workflow-run
             :platform :github
             :action (json-get data :action)
             :status (make-cicd-status
                      :github
                      (format nil "~A/~A" (json-get repo :owner :login) (json-get repo :name))
                      (if (string= (json-get workflow-run :conclusion) "success")
                          :success :failure)
                      (json-get workflow-run :head_sha)
                      :target-url (json-get workflow-run :html_url)))))

    ;; GitLab pipeline event
    ((string= event-type "Pipeline Hook")
     (let ((object-attributes (json-get data :object_attributes)))
       (list :event-type :pipeline
             :platform :gitlab
             :status (make-cicd-status
                      :gitlab
                      (json-get data :project :path_with_namespace)
                      (ecase (keywordize (string-downcase (json-get object-attributes :status)))
                        (:running :pending)
                        (:pending :pending)
                        (:success :success)
                        (:failed :failure)
                        (:canceled :error))
                      (json-get object-attributes :sha)
                      :target-url (json-get object-attributes :pipeline_url)))))

    (t
     (list :event-type :unknown
           :platform :generic
           :data data))))

;;; ============================================================================
;;; Event Handlers
;;; ============================================================================

(defun handle-check-run-event (data)
  "Handle GitHub check_run event.

  Args:
    DATA: Event data"
  (let ((check-run (json-get data :check_run))
        (repo (json-get data :repository)))
    (log-info "Check run ~A: ~A/~A ~A"
              (json-get check-run :name)
              (json-get repo :owner :login)
              (json-get repo :name)
              (json-get check-run :status))))

(defun handle-workflow-run-event (data)
  "Handle GitHub workflow_run event.

  Args:
    DATA: Event data"
  (let ((workflow-run (json-get data :workflow_run))
        (repo (json-get data :repository)))
    (log-info "Workflow run ~A: ~A/~A ~A"
              (json-get workflow-run :name)
              (json-get repo :owner :login)
              (json-get repo :name)
              (json-get workflow-run :conclusion))))

(defun handle-status-event (data)
  "Handle GitHub status event.

  Args:
    DATA: Event data"
  (let ((repo (json-get data :repository)))
    (log-info "Status update: ~A/~A - ~A"
              (json-get repo :owner :login)
              (json-get repo :name)
              (json-get data :state))))

(defun handle-pipeline-event (data)
  "Handle GitLab pipeline event.

  Args:
    DATA: Event data"
  (let ((attrs (json-get data :object_attributes)))
    (log-info "Pipeline ~A: ~A - ~A"
              (json-get data :project :name)
              (json-get attrs :ref)
              (json-get attrs :status))))

(defun handle-build-event (data)
  "Handle GitLab build event.

  Args:
    DATA: Event data"
  (log-info "Build ~A: ~A - ~A"
            (json-get data :build_name)
            (json-get data :build_stage)
            (json-get data :build_status)))

;;; ============================================================================
;;; Status Storage
;;; ============================================================================

(defun store-cicd-status (status)
  "Store a CI/CD status update.

  Args:
    STATUS: cicd-status instance

  Returns:
    T"
  (vector-push-extend status *cicd-status-cache*)
  (log-info "Stored CI/CD status: ~A/~A ~A"
            (cicd-status-platform status)
            (cicd-status-repository status)
            (cicd-status-state status))
  t)

(defun get-cicd-statuses (&key platform repository limit)
  "Get stored CI/CD statuses.

  Args:
    PLATFORM: Filter by platform
    REPOSITORY: Filter by repository
    LIMIT: Maximum results

  Returns:
    List of cicd-status instances"
  (let ((result nil))
    (loop for i from (1- (length *cicd-status-cache*)) downto 0
          for status = (aref *cicd-status-cache* i)
          when (and (or (null platform)
                        (eq platform (cicd-status-platform status)))
                    (or (null repository)
                        (string= repository (cicd-status-repository status))))
          do (push status result)
          when (and limit (>= (length result) limit))
          do (return))
    result))

;;; ============================================================================
;;; Formatting
;;; ============================================================================

(defun format-cicd-status (status)
  "Format a CI/CD status for display.

  Args:
    STATUS: cicd-status instance

  Returns:
    Formatted string"
  (format nil "[~A] ~A/~A: ~A - ~A~@[ (~A)~]"
          (cicd-status-platform status)
          (cicd-status-repository status)
          (cicd-status-sha status)
          (cicd-status-state status)
          (or (cicd-status-description status) "")
          (cicd-status-target-url status)))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-cicd-integration ()
  "Initialize CI/CD integration.

  Returns:
    T"
  (log-info "CI/CD integration initialized")
  (register-cicd-webhook)
  t)
