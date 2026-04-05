;;; agent/workflows.lisp --- Agentic Workflows for Lisp-Claw
;;;
;;; This file implements multi-agent collaboration workflows,
;;; similar to OpenClaw's agentic workflows system.

(defpackage #:lisp-claw.agent.workflows
  (:nicknames #:lc.agent.workflows)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.agent.session
        #:lisp-claw.advanced.memory)
  (:export
   ;; Agent class
   #:agent
   #:make-agent
   #:agent-id
   #:agent-name
   #:agent-role
   #:agent-capabilities
   #:agent-model
   #:agent-state
   ;; Workflow class
   #:workflow
   #:make-workflow
   #:workflow-id
   #:workflow-name
   #:workflow-steps
   #:workflow-enabled-p
   ;; Workflow steps
   #:workflow-step
   #:make-workflow-step
   #:step-id
   #:step-name
   #:step-agent
   #:step-action
   #:step-condition
   ;; Workflow registry
   #:*agent-registry*
   #:*workflow-registry*
   #:register-agent
   #:unregister-agent
   #:register-workflow
   #:unregister-workflow
   ;; Workflow execution
   #:execute-workflow
   #:execute-step
   #:get-workflow-status
   ;; Built-in workflows
   #:register-built-in-workflows
   ;; Coordination
   #:coordinator
   #:make-coordinator
   #:coordinator-assign-task
   #:coordinator-get-result))

(in-package #:lisp-claw.agent.workflows)

;;; ============================================================================
;;; Agent Class
;;; ============================================================================

(defclass agent ()
  ((id :initarg :id
       :reader agent-id
       :documentation "Unique agent identifier")
   (name :initarg :name
         :reader agent-name
         :documentation "Agent display name")
   (role :initarg :role
         :initform ""
         :reader agent-role
         :documentation "Agent role/specialization")
   (capabilities :initarg :capabilities
                 :initform nil
                 :reader agent-capabilities
                 :documentation "List of capabilities")
   (model :initarg :model
          :initform "claude-sonnet-4-6"
          :accessor agent-model
          :documentation "AI model for this agent")
   (state :initform :idle
          :accessor agent-state
          :documentation "Current state: idle, busy, offline")
   (system-prompt :initarg :system-prompt
                  :initform ""
                  :reader agent-system-prompt
                  :documentation "System prompt for this agent")
   (metadata :initarg :metadata
             :initform nil
             :reader agent-metadata
             :documentation "Additional metadata"))
  (:documentation "AI Agent for multi-agent collaboration"))

(defmethod print-object ((agent agent) stream)
  (print-unreadable-object (agent stream :type t)
    (format stream "~A (~A) [~A]"
            (agent-name agent)
            (agent-role agent)
            (agent-state agent))))

(defun make-agent (id name &key role capabilities model system-prompt metadata)
  "Create an agent.

  Args:
    ID: Unique identifier
    NAME: Display name
    ROLE: Role/specialization
    CAPABILITIES: List of capabilities
    MODEL: AI model
    SYSTEM-PROMPT: System prompt
    METADATA: Additional metadata

  Returns:
    Agent instance"
  (make-instance 'agent
                 :id id
                 :name name
                 :role (or role "General Assistant")
                 :capabilities (or capabilities nil)
                 :model (or model "claude-sonnet-4-6")
                 :system-prompt (or system-prompt "")
                 :metadata (or metadata nil)))

;;; ============================================================================
;;; Workflow Step Class
;;; ============================================================================

(defclass workflow-step ()
  ((id :initarg :id
       :reader step-id
       :documentation "Unique step identifier")
   (name :initarg :name
         :reader step-name
         :documentation "Step name")
   (description :initarg :description
                :initform ""
                :reader step-description
                :documentation "Step description")
   (agent-id :initarg :agent-id
             :reader step-agent-id
             :documentation "Agent to execute this step")
   (action :initarg :action
           :reader step-action
           :documentation "Action function for this step")
   (condition :initarg :condition
              :initform nil
              :reader step-condition
              :documentation "Condition to execute this step")
   (next-steps :initform nil
               :accessor step-next-steps
               :documentation "Next steps after this one")
   (timeout :initarg :timeout
            :initform 300
            :reader step-timeout
            :documentation "Timeout in seconds"))
  (:documentation "A step in a workflow"))

(defmethod print-object ((step workflow-step) stream)
  (print-unreadable-object (step stream :type t)
    (format stream "~A [~A]" (step-name step) (step-agent-id step))))

(defun make-workflow-step (id name action &key agent-id description condition timeout)
  "Create a workflow step.

  Args:
    ID: Step identifier
    NAME: Step name
    ACTION: Action function
    AGENT-ID: Agent to execute
    DESCRIPTION: Step description
    CONDITION: Condition function
    TIMEOUT: Timeout in seconds

  Returns:
    Workflow step instance"
  (make-instance 'workflow-step
                 :id id
                 :name name
                 :action action
                 :agent-id (or agent-id "default")
                 :description (or description "")
                 :condition (or condition nil)
                 :timeout (or timeout 300)))

;;; ============================================================================
;;; Workflow Class
;;; ============================================================================

(defclass workflow ()
  ((id :initarg :id
       :reader workflow-id
       :documentation "Unique workflow identifier")
   (name :initarg :name
         :reader workflow-name
         :documentation "Workflow name")
   (description :initarg :description
                :initform ""
                :reader workflow-description
                :documentation "Workflow description")
   (steps :initarg :steps
          :initform nil
          :accessor workflow-steps
          :documentation "List of workflow steps")
   (enabled-p :initform t
              :accessor workflow-enabled-p
              :documentation "Whether workflow is enabled")
   (state :initform :idle
          :accessor workflow-state
          :documentation "Current state: idle, running, paused, completed, failed")
   (current-step :initform nil
                 :accessor workflow-current-step
                 :documentation "Current step being executed")
   (context :initform (make-hash-table)
            :accessor workflow-context
            :documentation "Workflow execution context")
   (results :initform nil
            :accessor workflow-results
            :documentation "Execution results")
   (created-at :initform (get-universal-time)
               :reader workflow-created-at
               :documentation "Creation timestamp"))
  (:documentation "Agentic workflow for multi-step tasks"))

(defmethod print-object ((workflow workflow) stream)
  (print-unreadable-object (workflow stream :type t)
    (format stream "~A [~A]" (workflow-name workflow) (workflow-state workflow))))

(defun make-workflow (id name &key description steps)
  "Create a workflow.

  Args:
    ID: Workflow identifier
    NAME: Workflow name
    DESCRIPTION: Workflow description
    STEPS: List of workflow steps

  Returns:
    Workflow instance"
  (make-instance 'workflow
                 :id id
                 :name name
                 :description (or description "")
                 :steps (or steps nil)))

(defun add-step-to-workflow (workflow step)
  "Add a step to a workflow.

  Args:
    WORKFLOW: Workflow instance
    STEP: Workflow step instance

  Returns:
    T on success"
  (push step (workflow-steps workflow))
  (setf (workflow-steps workflow)
        (nreverse (workflow-steps workflow)))
  t)

(defun set-step-next (step next-step)
  "Set the next step after a step.

  Args:
    STEP: Current step
    NEXT-STEP: Next step

  Returns:
    T"
  (push next-step (step-next-steps step))
  t)

;;; ============================================================================
;;; Registries
;;; ============================================================================

(defvar *agent-registry* (make-hash-table :test 'equal)
  "Registry of agents.")

(defvar *workflow-registry* (make-hash-table :test 'equal)
  "Registry of workflows.")

(defvar *workflow-lock* (bt:make-lock)
  "Lock for workflow/agent registry access.")

(defun register-agent (agent)
  "Register an agent.

  Args:
    AGENT: Agent instance

  Returns:
    T on success"
  (bt:with-lock-held (*workflow-lock*)
    (setf (gethash (agent-id agent) *agent-registry*) agent)
    (log-info "Registered agent: ~A (~A)" (agent-name agent) (agent-id agent))
    t))

(defun unregister-agent (id)
  "Unregister an agent.

  Args:
    ID: Agent ID

  Returns:
    T on success"
  (bt:with-lock-held (*workflow-lock*)
    (when (gethash id *agent-registry*)
      (remhash id *agent-registry*)
      (log-info "Unregistered agent: ~A" id)
      t)))

(defun get-agent (id)
  "Get an agent by ID.

  Args:
    ID: Agent ID

  Returns:
    Agent instance or NIL"
  (gethash id *agent-registry*))

(defun list-agents ()
  "List all registered agents.

  Returns:
    List of agent info"
  (let ((agents nil))
    (bt:with-lock-held (*workflow-lock*)
      (maphash (lambda (id agent)
                 (push (list :id id
                             :name (agent-name agent)
                             :role (agent-role agent)
                             :state (agent-state agent)
                             :model (agent-model agent))
                       agents))
               *agent-registry*))
    agents))

(defun register-workflow (workflow)
  "Register a workflow.

  Args:
    WORKFLOW: Workflow instance

  Returns:
    T on success"
  (bt:with-lock-held (*workflow-lock*)
    (setf (gethash (workflow-id workflow) *workflow-registry*) workflow)
    (log-info "Registered workflow: ~A" (workflow-name workflow))
    t))

(defun unregister-workflow (id)
  "Unregister a workflow.

  Args:
    ID: Workflow ID

  Returns:
    T on success"
  (bt:with-lock-held (*workflow-lock*)
    (when (gethash id *workflow-registry*)
      (remhash id *workflow-registry*)
      (log-info "Unregistered workflow: ~A" id)
      t)))

(defun get-workflow (id)
  "Get a workflow by ID.

  Args:
    ID: Workflow ID

  Returns:
    Workflow instance or NIL"
  (gethash id *workflow-registry*))

(defun list-workflows ()
  "List all registered workflows.

  Returns:
    List of workflow info"
  (let ((workflows nil))
    (bt:with-lock-held (*workflow-lock*)
      (maphash (lambda (id workflow)
                 (push (list :id id
                             :name (workflow-name workflow)
                             :description (workflow-description workflow)
                             :state (workflow-state workflow)
                             :steps (length (workflow-steps workflow)))
                       workflows))
               *workflow-registry*))
    workflows))

;;; ============================================================================
;;; Workflow Execution
;;; ============================================================================

(defun execute-step (workflow step context)
  "Execute a workflow step.

  Args:
    WORKFLOW: Workflow instance
    STEP: Step to execute
    CONTEXT: Execution context

  Returns:
    Step result"
  (let ((agent (get-agent (step-agent-id step))))
    (unless agent
      (return-from execute-step
        (list :status :error :message "Agent not found"))))

  (setf (workflow-current-step workflow) step)
  (log-info "Executing step: ~A with agent: ~A"
            (step-name step) (step-agent-id step))

  (handler-case
      (let ((result (funcall (step-action step) context)))
        (log-info "Step completed: ~A" (step-name step))
        (list :status :success :result result))
    (error (e)
      (log-error "Step failed: ~A - ~A" (step-name step) e)
      (list :status :error :message (format nil "~A" e)))))

(defun execute-workflow (workflow-id &key initial-context)
  "Execute a workflow.

  Args:
    WORKFLOW-ID: Workflow ID
    INITIAL-CONTEXT: Initial context plist

  Returns:
    Workflow execution result"
  (let ((workflow (get-workflow workflow-id)))
    (unless workflow
      (return-from execute-workflow
        (list :status :error :message "Workflow not found")))

    (unless (workflow-enabled-p workflow)
      (return-from execute-workflow
        (list :status :error :message "Workflow is disabled")))

    ;; Initialize context
    (let ((context (or initial-context (make-hash-table))))
      (setf (workflow-state workflow) :running)
      (setf (workflow-context workflow) context)
      (setf (workflow-results workflow) nil)

      ;; Execute steps in order
      (let ((current-step (first (workflow-steps workflow))))
        (loop while current-step
              do (let ((result (execute-step workflow current-step context)))
                   (push (list :step (step-id current-step)
                               :result result)
                         (workflow-results workflow))

                   ;; Check for error
                   (when (eq (getf result :status) :error)
                     (setf (workflow-state workflow) :failed)
                     (return-from execute-workflow
                       (list :status :failed
                             :workflow-id workflow-id
                             :error (getf result :message)
                             :results (workflow-results workflow))))

                   ;; Get next step
                   (let ((next-steps (step-next-steps current-step)))
                     (setf current-step
                           (if next-steps
                               (first next-steps)
                               (let ((idx (position current-step (workflow-steps workflow))))
                                 (when (< idx (1- (length (workflow-steps workflow))))
                                   (nth (1+ idx) (workflow-steps workflow)))))))))

        (setf (workflow-state workflow) :completed)
        (setf (workflow-current-step workflow) nil)

        (log-info "Workflow completed: ~A" (workflow-name workflow))
        (list :status :completed
              :workflow-id workflow-id
              :results (workflow-results workflow))))))

(defun get-workflow-status (workflow-id)
  "Get workflow execution status.

  Args:
    WORKFLOW-ID: Workflow ID

  Returns:
    Status plist"
  (let ((workflow (get-workflow workflow-id)))
    (unless workflow
      (return-from get-workflow-status
        (list :status :error :message "Workflow not found")))

    (list :id workflow-id
          :name (workflow-name workflow)
          :state (workflow-state workflow)
          :current-step (when (workflow-current-step workflow)
                          (step-name (workflow-current-step workflow)))
          :total-steps (length (workflow-steps workflow))
          :results (workflow-results workflow))))

;;; ============================================================================
;;; Coordinator
;;; ============================================================================

(defclass coordinator ()
  ((id :initarg :id
       :reader coordinator-id
       :documentation "Coordinator ID")
   (name :initarg :name
         :reader coordinator-name
         :documentation "Coordinator name")
   (agents :initform nil
           :accessor coordinator-agents
           :documentation "List of managed agents")
   (task-queue :initform nil
               :accessor coordinator-task-queue
               :documentation "Pending tasks")
   (active-tasks :initform (make-hash-table :test 'equal)
                 :accessor coordinator-active-tasks
                 :documentation "Currently active tasks"))
  (:documentation "Multi-agent coordinator"))

(defun make-coordinator (id name &key agents)
  "Create a coordinator.

  Args:
    ID: Coordinator ID
    NAME: Coordinator name
    AGENTS: Initial agents

  Returns:
    Coordinator instance"
  (let ((coord (make-instance 'coordinator :id id :name name)))
    (when agents
      (setf (coordinator-agents coord) agents))
    coord))

(defun coordinator-assign-task (coordinator task agent-id)
  "Assign a task to an agent.

  Args:
    COORDINATOR: Coordinator instance
    TASK: Task to assign
    AGENT-ID: Agent ID

  Returns:
    Task assignment result"
  (let ((agent (get-agent agent-id)))
    (unless agent
      (return-from coordinator-assign-task
        (list :status :error :message "Agent not found")))

    (when (eq (agent-state agent) :busy)
      (return-from coordinator-assign-task
        (list :status :error :message "Agent is busy")))

    ;; Assign task
    (setf (agent-state agent) :busy)
    (setf (gethash task (coordinator-active-tasks coordinator))
          (list :agent agent
                :task task
                :started-at (get-universal-time)))

    (log-info "Assigned task to agent ~A: ~A" agent-id task)
    (list :status :success :agent-id agent-id :task task)))

(defun coordinator-get-result (coordinator task-id)
  "Get result of a task.

  Args:
    COORDINATOR: Coordinator instance
    TASK-ID: Task ID

  Returns:
    Task result"
  (let ((task-info (gethash task-id (coordinator-active-tasks coordinator))))
    (unless task-info
      (return-from coordinator-get-result
        (list :status :error :message "Task not found")))

    ;; Check if completed
    (let ((agent (getf task-info :agent))
          (started (getf task-info :started-at)))
      (list :status :completed
            :agent-id (agent-id agent)
            :started-at started
            :result "Task completed")))) ; Placeholder

;;; ============================================================================
;;; Built-in Workflows
;;; ============================================================================

(defun register-research-workflow ()
  "Register research workflow.

  Returns:
    T"
  (let* ((workflow (make-workflow "research" "Research Workflow"
                                  :description "Multi-step research and analysis"))
         (step1 (make-workflow-step
                 "search" "Search"
                 (lambda (context)
                   (let ((query (getf context :query)))
                     (list :status :success :results (format nil "Searched: ~A" query))))
                 :agent-id "researcher"
                 :description "Search for information"))
         (step2 (make-workflow-step
                 "analyze" "Analyze"
                 (lambda (context)
                   (let ((search-results (getf context :search-results)))
                     (list :status :success :analysis (format nil "Analyzed: ~A" search-results))))
                 :agent-id "analyst"
                 :description "Analyze search results"))
         (step3 (make-workflow-step
                 "summarize" "Summarize"
                 (lambda (context)
                   (let ((analysis (getf context :analysis))
                         (query (getf context :query)))
                     (list :status :success
                           :summary (format nil "Summary for '~A': ~A" query analysis))))
                 :agent-id "writer"
                 :description "Create summary")))
    (set-step-next step1 step2)
    (set-step-next step2 step3)

    (add-step-to-workflow workflow step1)
    (add-step-to-workflow workflow step2)
    (add-step-to-workflow workflow step3)

    (register-workflow workflow))
  t)

(defun register-code-review-workflow ()
  "Register code review workflow.

  Returns:
    T"
  (let* ((workflow (make-workflow "code-review" "Code Review Workflow"
                                  :description "Automated code review process"))
         (step1 (make-workflow-step
                 "parse" "Parse Code"
                 (lambda (context)
                   (let ((code (getf context :code)))
                     (list :status :success
                           :parsed t
                           :lines (length (split-sequence:split-sequence #\Newline code)))))
                 :agent-id "parser"
                 :description "Parse and analyze code structure"))
         (step2 (make-workflow-step
                 "review" "Review"
                 (lambda (context)
                   (list :status :success
                         :issues (list "Consider adding type hints"
                                       "Missing docstrings"))
                 :agent-id "reviewer"
                 :description "Review code quality"))
         (step3 (make-workflow-step
                 "report" "Generate Report"
                 (lambda (context)
                   (let ((issues (getf context :issues)))
                     (list :status :success
                           :report (format nil "Code Review Report:~%~{~&- ~A~}" issues))))
                 :agent-id "reporter"
                 :description "Generate review report")))
    (set-step-next step1 step2)
    (set-step-next step2 step3)

    (add-step-to-workflow workflow step1)
    (add-step-to-workflow workflow step2)
    (add-step-to-workflow workflow step3)

    (register-workflow workflow))
  t)

(defun register-data-processing-workflow ()
  "Register data processing workflow.

  Returns:
    T"
  (let* ((workflow (make-workflow "data-processing" "Data Processing Workflow"
                                  :description "Multi-step data processing pipeline"))
         (step1 (make-workflow-step
                 "extract" "Extract Data"
                 (lambda (context)
                   (list :status :success :data "Extracted data"))
                 :agent-id "extractor"
                 :description "Extract data from source"))
         (step2 (make-workflow-step
                 "transform" "Transform"
                 (lambda (context)
                   (let ((data (getf context :data)))
                     (list :status :success :transformed (format nil "Transformed: ~A" data))))
                 :agent-id "transformer"
                 :description "Transform and clean data"))
         (step3 (make-workflow-step
                 "load" "Load"
                 (lambda (context)
                   (list :status :success :loaded t))
                 :agent-id "loader"
                 :description "Load data to destination")))
    (set-step-next step1 step2)
    (set-step-next step2 step3)

    (add-step-to-workflow workflow step1)
    (add-step-to-workflow workflow step2)
    (add-step-to-workflow workflow step3)

    (register-workflow workflow))
  t)

(defun register-built-in-workflows ()
  "Register all built-in workflows and agents.

  Returns:
    T"
  ;; Register agents
  (register-agent (make-agent "default" "Default Agent"
                              :role "General Assistant"
                              :capabilities '("chat" "tools" "memory")))
  (register-agent (make-agent "researcher" "Research Agent"
                              :role "Research Specialist"
                              :capabilities '("search" "gather" "verify")
                              :system-prompt "You are a research specialist. Find accurate information."))
  (register-agent (make-agent "analyst" "Analysis Agent"
                              :role "Data Analyst"
                              :capabilities '("analyze" "interpret" "visualize")
                              :system-prompt "You are a data analyst. Provide insights from data."))
  (register-agent (make-agent "writer" "Writing Agent"
                              :role "Content Writer"
                              :capabilities '("write" "edit" "summarize")
                              :system-prompt "You are a content writer. Create clear, concise content."))
  (register-agent (make-agent "reviewer" "Code Review Agent"
                              :role "Code Reviewer"
                              :capabilities '("review" "debug" "optimize")
                              :system-prompt "You are a code reviewer. Find bugs and suggest improvements."))
  (register-agent (make-agent "parser" "Parser Agent"
                              :role "Code Parser"
                              :capabilities '("parse" "analyze" "structure")
                              :system-prompt "You parse and analyze code structure."))
  (register-agent (make-agent "reporter" "Reporter Agent"
                              :role "Report Generator"
                              :capabilities '("report" "document")
                              :system-prompt "You generate clear, comprehensive reports."))
  (register-agent (make-agent "extractor" "Data Extractor"
                              :role "Data Extraction"
                              :capabilities '("extract" "scrape")
                              :system-prompt "You extract data from various sources."))
  (register-agent (make-agent "transformer" "Data Transformer"
                              :role "Data Transformation"
                              :capabilities '("transform" "clean")
                              :system-prompt "You transform and clean data."))
  (register-agent (make-agent "loader" "Data Loader"
                              :role "Data Loading"
                              :capabilities '("load" "import")
                              :system-prompt "You load data into destination systems."))

  ;; Register workflows
  (register-research-workflow)
  (register-code-review-workflow)
  (register-data-processing-workflow)

  (log-info "Built-in workflows and agents registered")
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-workflows-system ()
  "Initialize the agentic workflows system.

  Returns:
    T"
  (register-built-in-workflows)
  (log-info "Agentic workflows system initialized")
  t)
