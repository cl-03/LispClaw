;;; agent/router.lisp --- Agent Router for Lisp-Claw
;;;
;;; This file implements intelligent agent routing:
;;; - Capability-based routing
;;; - Load-aware distribution
;;; - Intent-to-Agent mapping
;;; - Agent health monitoring
;;; - Priority queuing

(defpackage #:lisp-claw.agent.router
  (:nicknames #:lc.agent.router)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.agent.session
        #:lisp-claw.agent.intents)
  (:export
   ;; Router class
   #:agent-router
   #:make-agent-router
   #:router-route-request
   #:router-register-agent
   #:router-unregister-agent
   ;; Capability registry
   #:register-capability
   #:unregister-capability
   #:get-agents-by-capability
   #:list-all-capabilities
   ;; Load balancing
   #:get-agent-load
   #:select-least-loaded
   #:update-agent-load
   ;; Health monitoring
   #:check-agent-health
   #:get-healthy-agents
   #:agent-heartbeat
   ;; Routing strategies
   #:*routing-strategy*
   #:route-by-capability
   #:route-by-load
   #:route-by-session
   #:route-round-robin))

(in-package #:lisp-claw.agent.router)

;;; ============================================================================
;;; Agent Router Class
;;; ============================================================================

(defclass agent-router ()
  ((name :initarg :name
         :reader router-name
         :documentation "Router name")
   (agents :initform (make-hash-table :test 'equal)
           :accessor router-agents
           :documentation "Registered agents")
   (capabilities :initform (make-hash-table :test 'equal)
                 :accessor router-capabilities
                 :documentation "Capability to agent mapping")
   (load-table :initform (make-hash-table :test 'equal)
               :accessor router-load-table
               :documentation "Agent load information")
   (health-status :initform (make-hash-table :test 'equal)
                  :accessor router-health-status
                  :documentation "Agent health status")
   (sessions :initform (make-hash-table :test 'equal)
             :accessor router-sessions
             :documentation "Session to agent affinity")
   (round-robin-index :initform 0
                      :accessor router-round-robin-index
                      :documentation "Round-robin index")
   (lock :initform (bt:make-lock "agent-router-lock")
         :reader router-lock
         :documentation "Router lock")))

(defmethod print-object ((router agent-router) stream)
  (print-unreadable-object (router stream :type t)
    (format t "~A [~A agents]"
            (router-name router)
            (hash-table-count (router-agents router)))))

;;; ============================================================================
;;; Global Router Instance
;;; ============================================================================

(defvar *agent-router* nil
  "Global agent router instance.")

(defvar *routing-strategy* :capability
  "Default routing strategy: :capability, :load, :round-robin, :session")

;;; ============================================================================
;;; Construction
;;; ============================================================================

(defun make-agent-router (&key (name "default"))
  "Create an agent router.

  Args:
    NAME: Router name

  Returns:
    Agent router instance"
  (let ((router (make-instance 'agent-router :name name)))
    (log-info "Agent router created: ~A" name)
    router))

(defun initialize-router ()
  "Initialize the global agent router.

  Returns:
    T"
  (setf *agent-router* (make-agent-router))
  (log-info "Agent router initialized")
  t)

;;; ============================================================================
;;; Agent Registration
;;; ============================================================================

(defun router-register-agent (router agent-id &key capabilities metadata)
  "Register an agent with the router.

  Args:
    ROUTER: Router instance
    AGENT-ID: Agent identifier
    CAPABILITIES: List of capability keywords
    METADATA: Optional metadata

  Returns:
    T on success"
  (bt:with-lock-held ((router-lock router))
    ;; Register agent
    (setf (gethash agent-id (router-agents router))
          (list :id agent-id
                :capabilities capabilities
                :metadata metadata
                :registered-at (get-universal-time)
                :load 0
                :last-seen (get-universal-time)))

    ;; Register capabilities
    (dolist (cap capabilities)
      (let ((agents (gethash cap (router-capabilities router))))
        (pushnew agent-id agents :test #'string=)
        (setf (gethash cap (router-capabilities router)) agents)))

    ;; Initialize load
    (setf (gethash agent-id (router-load-table router)) 0)

    ;; Initialize health
    (setf (gethash agent-id (router-health-status router)) :healthy)

    (log-info "Agent registered: ~A with capabilities: ~A" agent-id capabilities)
    t))

(defun router-unregister-agent (router agent-id)
  "Unregister an agent from the router.

  Args:
    ROUTER: Router instance
    AGENT-ID: Agent identifier

  Returns:
    T on success"
  (bt:with-lock-held ((router-lock router))
    (let ((agent-info (gethash agent-id (router-agents router))))
      (when agent-info
        ;; Remove from capabilities
        (dolist (cap (getf agent-info :capabilities))
          (let ((agents (gethash cap (router-capabilities router))))
            (setf agents (remove agent-id agents :test #'string=))
            (setf (gethash cap (router-capabilities router)) agents))))

        ;; Remove from all tables
        (remhash agent-id (router-agents router))
        (remhash agent-id (router-load-table router))
        (remhash agent-id (router-health-status router))

        (log-info "Agent unregistered: ~A" agent-id)
        t))))

(defun agent-heartbeat (router agent-id &key load status)
  "Send heartbeat from an agent.

  Args:
    ROUTER: Router instance
    AGENT-ID: Agent identifier
    LOAD: Current load (0-100)
    STATUS: Health status

  Returns:
    T"
  (bt:with-lock-held ((router-lock router))
    (let ((agent-info (gethash agent-id (router-agents router))))
      (when agent-info
        (setf (getf agent-info :last-seen) (get-universal-time))
        (when load
          (setf (getf agent-info :load) load)
          (setf (gethash agent-id (router-load-table router)) load))
        (when status
          (setf (gethash agent-id (router-health-status router)) status))
        t))))

;;; ============================================================================
;;; Capability Registry
;;; ============================================================================

(defun register-capability (capability agent-id)
  "Register a capability for an agent.

  Args:
    CAPABILITY: Capability keyword/string
    AGENT-ID: Agent identifier

  Returns:
    T"
  (let ((cap (string-downcase (string capability))))
    (bt:with-lock-held (*agent-router*)
      (let ((agents (gethash cap (router-capabilities *agent-router*))))
        (pushnew agent-id agents :test #'string=)
        (setf (gethash cap (router-capabilities *agent-router*)) agents)))
    (log-debug "Capability registered: ~A -> ~A" capability agent-id)
    t))

(defun unregister-capability (capability agent-id)
  "Unregister a capability from an agent.

  Args:
    CAPABILITY: Capability keyword/string
    AGENT-ID: Agent identifier

  Returns:
    T"
  (let ((cap (string-downcase (string capability))))
    (bt:with-lock-held (*agent-router*)
      (let ((agents (gethash cap (router-capabilities *agent-router*))))
        (setf agents (remove agent-id agents :test #'string=))
        (setf (gethash cap (router-capabilities *agent-router*)) agents)))
    t))

(defun get-agents-by-capability (capability)
  "Get all agents with a capability.

  Args:
    CAPABILITY: Capability keyword/string

  Returns:
    List of agent IDs"
  (let ((cap (string-downcase (string capability))))
    (gethash cap (router-capabilities *agent-router*))))

(defun list-all-capabilities ()
  "List all registered capabilities.

  Returns:
    List of capability names"
  (let ((caps nil))
    (maphash (lambda (k v)
               (declare (ignore v))
               (push k caps))
             (router-capabilities *agent-router*))
    caps))

;;; ============================================================================
;;; Load Balancing
;;; ============================================================================

(defun get-agent-load (agent-id)
  "Get current load of an agent.

  Args:
    AGENT-ID: Agent identifier

  Returns:
    Load value (0-100) or NIL"
  (gethash agent-id (router-load-table *agent-router*)))

(defun update-agent-load (agent-id load)
  "Update agent load.

  Args:
    AGENT-ID: Agent identifier
    LOAD: Load value (0-100)

  Returns:
    T"
  (setf (gethash agent-id (router-load-table *agent-router*)) load)
  t)

(defun select-least-loaded (&optional agents)
  "Select the least loaded agent.

  Args:
    AGENTS: Optional list of agent IDs to consider

  Returns:
    Agent ID or NIL"
  (let ((candidates (or agents
                        (alexandria:hash-table-keys (router-agents *agent-router*)))))
    (let ((min-load most-positive-fixnum)
          (selected nil))
      (dolist (agent-id candidates)
        (let ((load (or (get-agent-load agent-id) 0)))
          (when (< load min-load)
            (setf min-load load)
            (setf selected agent-id))))
      selected)))

;;; ============================================================================
;;; Health Monitoring
;;; ============================================================================

(defun check-agent-health (router agent-id)
  "Check health of an agent.

  Args:
    ROUTER: Router instance
    AGENT-ID: Agent identifier

  Returns:
    Health status keyword"
  (let* ((agent-info (gethash agent-id (router-agents router)))
         (last-seen (when agent-info (getf agent-info :last-seen)))
         (now (get-universal-time)))
    (if (and last-seen
             (<= (- now last-seen) 60))  ; 60 second timeout
        :healthy
        :unhealthy)))

(defun get-healthy-agents (&optional agents)
  "Get list of healthy agents.

  Args:
    AGENTS: Optional list of agent IDs to filter

  Returns:
    List of healthy agent IDs"
  (let ((candidates (or agents
                        (alexandria:hash-table-keys (router-agents *agent-router*)))))
    (remove-if-not (lambda (id)
                     (eq (gethash id (router-health-status *agent-router*)) :healthy))
                   candidates)))

;;; ============================================================================
;;; Routing Strategies
;;; ============================================================================

(defun route-by-capability (intent-capabilities)
  "Route request by capability.

  Args:
    INTENT-CAPABILITIES: List of required capabilities

  Returns:
    Agent ID or NIL"
  (let ((candidates nil))
    ;; Find agents with all required capabilities
    (dolist (cap intent-capabilities)
      (let ((agents (get-agents-by-capability cap)))
        (if candidates
            (setf candidates (intersection candidates agents :test #'string=))
            (setf candidates agents))))

    (when candidates
      ;; Select least loaded among capable agents
      (select-least-loaded (get-healthy-agents candidates)))))

(defun route-by-load ()
  "Route request to least loaded agent.

  Returns:
    Agent ID or NIL"
  (select-least-loaded (get-healthy-agents)))

(defun route-by-session (session-id)
  "Route request by session affinity.

  Args:
    SESSION-ID: Session identifier

  Returns:
    Agent ID or NIL"
  (let ((agent (gethash session-id (router-sessions *agent-router*))))
    (if (and agent
             (eq (gethash agent (router-health-status *agent-router*)) :healthy))
        agent
        ;; No affinity, use load-based routing
        (let ((selected (route-by-load)))
          (when selected
            (setf (gethash session-id (router-sessions *agent-router*)) selected))
          selected))))

(defun route-round-robin ()
  "Route request using round-robin.

  Returns:
    Agent ID or NIL"
  (let* ((agents (get-healthy-agents))
         (count (length agents)))
    (when (plusp count)
      (let ((index (mod (router-round-robin-index *agent-router*) count)))
        (incf (router-round-robin-index *agent-router*))
        (nth index agents)))))

;;; ============================================================================
;;; Main Routing Function
;;; ============================================================================

(defun router-route-request (router request &key session-id intent)
  "Route a request to an appropriate agent.

  Args:
    ROUTER: Router instance
    REQUEST: Request object
    SESSION-ID: Optional session ID for affinity
    INTENT: Optional intent for capability-based routing

  Returns:
    Agent ID or NIL"
  (let ((strategy *routing-strategy*)
        (agent nil))

    (bt:with-lock-held ((router-lock router))
      (cond
        ;; Session affinity first
        ((and session-id (eq strategy :session))
         (setf agent (route-by-session session-id)))

        ;; Capability-based routing
        ((and intent (eq strategy :capability))
         (let ((capabilities (getf intent :capabilities)))
           (when capabilities
             (setf agent (route-by-capability capabilities)))))

        ;; Load-based routing
        ((eq strategy :load)
         (setf agent (route-by-load)))

        ;; Round-robin
        ((eq strategy :round-robin)
         (setf agent (route-round-robin)))

        ;; Default: capability then load
        (t
         (if intent
             (let ((capabilities (getf intent :capabilities)))
               (when capabilities
                 (setf agent (route-by-capability capabilities))))
             (setf agent (route-by-load)))
         (unless agent
           (setf agent (route-round-robin)))))

      ;; Update load if agent selected
      (when agent
        (let ((current-load (get-agent-load agent)))
          (update-agent-load agent (min 100 (+ (or current-load 0) 10))))))

    (if agent
        (log-debug "Routed request to agent: ~A (strategy: ~A)" agent strategy)
        (log-warn "No suitable agent found for request"))

    agent))

;;; ============================================================================
;;; Intent Integration
;;; ============================================================================

(defun extract-capabilities-from-intent (intent)
  "Extract required capabilities from intent.

  Args:
    INTENT: Intent object

  Returns:
    List of capability keywords"
  (let ((capabilities nil))
    ;; Check intent type
    (let ((type (getf intent :type)))
      (cond
        ((member type '(:question :query) :test #'string=)
         (push :knowledge capabilities))
        ((member type '(:code :programming) :test #'string=)
         (push :coding capabilities))
        ((member type '(:analysis :data) :test #'string=)
         (push :analysis capabilities))
        ((member type '(:creative :writing) :test #'string=)
         (push :creative capabilities))
        ((member type '(:tool :action) :test #'string=)
         (push :tool-use capabilities))))

    ;; Check for tool requirements
    (let ((tools (getf intent :required-tools)))
      (when tools
        (push :tool-use capabilities)))

    (nreverse capabilities)))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-agent-router-system ()
  "Initialize the agent router system.

  Returns:
    T"
  (initialize-router)
  (log-info "Agent router system initialized")
  t)
