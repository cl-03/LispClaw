;;; session.lisp --- Agent Session Management for Lisp-Claw
;;;
;;; This file implements session management for AI agent interactions.

(defpackage #:lisp-claw.agent.session
  (:nicknames #:lc.agent.session)
  (:use #:cl
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.helpers
        #:lisp-claw.utils.json)
  (:export
   #:*session-store*
   #:agent-session
   #:make-agent-session
   #:get-session
   #:create-session
   #:destroy-session
   #:session-add-message
   #:session-get-history
   #:session-clear-history
   #:session-set-mode
   #:session-compaction
   #:list-sessions
   #:session-send))

(in-package #:lisp-claw.agent.session)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *session-store* (make-hash-table :test 'equal)
  "Hash table storing all agent sessions.")

(defvar *session-lock* (bt:make-lock)
  "Lock for session store access.")

(defvar *session-counter* 0
  "Counter for generating unique session IDs.")

(defvar *default-session-ttl* 3600
  "Default session time-to-live in seconds (1 hour).")

;;; ============================================================================
;;; Session Class
;;; ============================================================================

(defclass agent-session ()
  ((id :initarg :id
       :reader session-id
       :documentation "Unique session identifier")
   (created-at :initform (get-universal-time)
               :reader session-created-at
       :documentation "Session creation timestamp")
   (last-accessed :initform (get-universal-time)
                  :accessor session-last-accessed
       :documentation "Last access timestamp")
   (mode :initform :main
         :accessor session-mode
       :documentation "Session mode (:main, :group, :non-main)")
   (model :initarg :model
          :initform "anthropic/claude-opus-4-6"
          :accessor session-model
       :documentation "Model identifier for this session")
   (thinking-level :initform :medium
                   :accessor session-thinking-level
       :documentation "Thinking level (:off, :minimal, :low, :medium, :high, :xhigh)")
   (verbose-level :initform :normal
                  :accessor session-verbose-level
       :documentation "Verbosity level (:off, :normal, :full)")
   (history :initform nil
            :accessor session-history
       :documentation "Message history (list of alists)")
   (message-count :initform 0
                  :accessor session-message-count
       :documentation "Number of messages in session")
   (metadata :initform nil
             :accessor session-metadata
       :documentation "Additional session metadata")
   (context-tokens :initform 0
                   :accessor session-context-tokens
       :documentation "Estimated context token count")
   (ttl :initarg :ttl
        :initform *default-session-ttl*
        :accessor session-ttl
       :documentation "Session time-to-live in seconds")
   (expired-p :initform nil
              :accessor session-expired-p
       :documentation "Whether session has expired")))

(defmethod print-object ((session agent-session) stream)
  "Print session representation."
  (print-unreadable-object (session stream :type t)
    (format stream "~A [~A msgs, ~A]"
            (session-id session)
            (session-message-count session)
            (session-mode session))))

;;; ============================================================================
;;; Session Construction
;;; ============================================================================

(defun generate-session-id ()
  "Generate a unique session ID.

  Returns:
    Session ID string"
  (format nil "session-~A-~A"
          (get-universal-time)
          (incf *session-counter*)))

(defun make-agent-session (&key id model mode metadata ttl)
  "Create a new agent session.

  Args:
    ID: Optional session ID (generated if NIL)
    MODEL: Model identifier
    MODE: Session mode
    METADATA: Additional metadata
    TTL: Time-to-live in seconds

  Returns:
    Agent session instance"
  (let ((session (make-instance 'agent-session
                                :id (or id (generate-session-id))
                                :model model
                                :mode mode
                                :metadata metadata
                                :ttl ttl)))
    (log-debug "Created session: ~A" (session-id session))
    session))

;;; ============================================================================
;;; Session Store Operations
;;; ============================================================================

(defun create-session (&key id model mode metadata ttl)
  "Create and store a new session.

  Args:
    ID: Optional session ID
    MODEL: Model identifier
    MODE: Session mode
    METADATA: Additional metadata
    TTL: Time-to-live

  Returns:
    Session ID"
  (let ((session (make-agent-session :id id
                                     :model model
                                     :mode mode
                                     :metadata metadata
                                     :ttl ttl)))
    (bt:with-lock-held (*session-lock*)
      (setf (gethash (session-id session) *session-store*) session))
    (log-info "Session created: ~A" (session-id session))
    (session-id session)))

(defun get-session (session-id)
  "Get a session by ID.

  Args:
    SESSION-ID: Session identifier

  Returns:
    Agent session or NIL"
  (bt:with-lock-held (*session-lock*)
    (let ((session (gethash session-id *session-store*)))
      (when session
        ;; Check expiration
        (if (session-expired-p session)
            (progn
              (remhash session-id *session-store*)
              (log-debug "Session expired and removed: ~A" session-id)
              nil)
            ;; Update last accessed
            (progn
              (setf (session-last-accessed session) (get-universal-time))
              session))))))

(defun destroy-session (session-id)
  "Destroy a session.

  Args:
    SESSION-ID: Session identifier

  Returns:
    T on success"
  (bt:with-lock-held (*session-lock*)
    (let ((session (gethash session-id *session-store*)))
      (when session
        (remhash session-id *session-store*)
        (log-info "Session destroyed: ~A" session-id)
        t))))

(defun list-sessions (&key mode expired-p)
  "List all sessions.

  Args:
    MODE: Optional filter by mode
    EXPIRED-P: Whether to include expired sessions

  Returns:
    List of session IDs"
  (let ((ids nil))
    (bt:with-lock-held (*session-lock*)
      (maphash (lambda (id session)
                 (when (and (or (null mode)
                                (equal (session-mode session) mode))
                            (or expired-p
                                (not (session-expired-p session))))
                   (push id ids)))
               *session-store*))
    ids))

;;; ============================================================================
;;; Message History
;;; ============================================================================

(defun session-add-message (session-id role content &key attachments metadata)
  "Add a message to session history.

  Args:
    SESSION-ID: Session identifier
    ROLE: Message role (:user, :assistant, :system)
    CONTENT: Message content
    ATTACHMENTS: Optional attachments
    METADATA: Optional metadata

  Returns:
    T on success"
  (let ((session (get-session session-id)))
    (unless session
      (log-error "Session not found: ~A" session-id)
      (return-from session-add-message nil))

    (let ((message `(:role ,role
                     :content ,content
                     :timestamp ,(get-universal-time)
                     ,@(when attachments `((:attachments ,attachments)))
                     ,@(when metadata `((:metadata ,metadata))))))
      (bt:with-lock-held (*session-lock*)
        (push message (session-history session))
        (incf (session-message-count session))
        ;; Update context tokens estimate (rough estimate: 1 char ≈ 0.75 tokens)
        (incf (session-context-tokens session)
              (floor (* (length (princ-to-string content)) 0.75))))

      (log-debug "Message added to session ~A: ~A" session-id role)
      t)))

(defun session-get-history (session-id &key limit format)
  "Get session message history.

  Args:
    SESSION-ID: Session identifier
    LIMIT: Optional maximum number of messages
    FORMAT: Output format (:lisp, :json, :string)

  Returns:
    Message history (reversed, oldest first)"
  (let ((session (get-session session-id)))
    (unless session
      (return-from session-get-history nil))

    (let ((history (nreverse (session-history session))))
      (when limit
        (setf history (subseq history 0 (min limit (length history)))))

      (ecase format
        ((nil :lisp) history)
        (:json (stringify-json history))
        (:string (format nil "~{~A~^~%~}"
                         (loop for msg in history
                               collect (format nil "[~A] ~A"
                                               (plist-get msg :role)
                                               (plist-get msg :content)))))))))

(defun session-clear-history (session-id)
  "Clear session message history.

  Args:
    SESSION-ID: Session identifier

  Returns:
    T on success"
  (let ((session (get-session session-id)))
    (when session
      (bt:with-lock-held (*session-lock*)
        (setf (session-history session) nil)
        (setf (session-context-tokens session) 0)
        (log-info "Session history cleared: ~A" session-id)
        t))))

;;; ============================================================================
;;; Session Compaction
;;; ============================================================================

(defun session-compaction (session-id &key max-tokens summary-model)
  "Compact session history to reduce context size.

  Args:
    SESSION-ID: Session identifier
    MAX-TOKENS: Maximum tokens to keep
    SUMMARY-MODEL: Model to use for summarization

  Returns:
    T on success"
  (declare (ignore summary-model))
  (let ((session (get-session session-id)))
    (unless session
      (return-from session-compaction nil))

    (bt:with-lock-held (*session-lock*)
      (let ((history (session-history session)))
        (when (> (session-context-tokens session) max-tokens)
          ;; Keep only recent messages
          (let ((keep-count (max 5 (floor (length history) 2))))
            (setf (session-history session)
                  (subseq history 0 keep-count))
            (log-info "Session compacted: ~A (kept ~A messages)"
                      session-id keep-count))))
      t)))

;;; ============================================================================
;;; Session Mode
;;; ============================================================================

(defun session-set-mode (session-id mode &key model thinking-level verbose-level)
  "Set session mode and options.

  Args:
    SESSION-ID: Session identifier
    MODE: New session mode
    MODEL: Optional new model
    THINKING-LEVEL: Optional thinking level
    VERBOSE-LEVEL: Optional verbosity level

  Returns:
    T on success"
  (let ((session (get-session session-id)))
    (unless session
      (log-error "Session not found: ~A" session-id)
      (return-from session-set-mode nil))

    (bt:with-lock-held (*session-lock*)
      (when (member mode '(:main :group :non-main))
        (setf (session-mode session) mode))
      (when model
        (setf (session-model session) model))
      (when (member thinking-level '(:off :minimal :low :medium :high :xhigh))
        (setf (session-thinking-level session) thinking-level))
      (when (member verbose-level '(:off :normal :full))
        (setf (session-verbose-level session) verbose-level)))

    (log-info "Session mode updated: ~A -> ~A" session-id mode)
    t))

;;; ============================================================================
;;; Session Sending
;;; ============================================================================

(defun session-send (session-id message &key stream)
  "Send a message to a session (process with AI).

  Args:
    SESSION-ID: Session identifier
    MESSAGE: User message content
    STREAM: Whether to stream response

  Returns:
    AI response"
  (let ((session (get-session session-id)))
    (unless session
      (return-from session-send
        (values nil "Session not found"))))

  ;; Add user message to history
  (session-add-message session-id :user message)

  ;; Process with AI (would call agent core)
  (let ((response (process-with-ai session-id message stream)))
    ;; Add assistant response to history
    (session-add-message session-id :assistant response)
    response))

(defun process-with-ai (session-id message stream)
  "Process a message with AI.

  Args:
    SESSION-ID: Session identifier
    MESSAGE: User message
    STREAM: Whether to stream

  Returns:
    AI response string

  Note: This is a stub - actual AI integration in agent/core.lisp"
  (declare (ignore session-id message stream))
  "This is a stub response. Actual AI integration pending.")

;;; ============================================================================
;;; Session Cleanup
;;; ============================================================================

(defun cleanup-expired-sessions ()
  "Clean up expired sessions.

  Returns:
    Number of sessions cleaned up"
  (let ((count 0))
    (bt:with-lock-held (*session-lock*)
      (maphash (lambda (id session)
                 (let ((expiry (+ (session-created-at session)
                                  (session-ttl session))))
                   (when (> (get-universal-time) expiry)
                     (remhash id *session-store*)
                     (incf count)
                     (log-debug "Cleaned up expired session: ~A" id))))
               *session-store*))
    (log-info "Cleaned up ~A expired sessions" count)
    count))

(defun start-session-cleanup-task (&optional (interval-seconds 300))
  "Start background session cleanup task.

  Args:
    INTERVAL-SECONDS: Cleanup interval (default 5 minutes)

  Returns:
    Thread object"
  (bt:make-thread
   (lambda ()
     (loop
       (sleep interval-seconds)
       (cleanup-expired-sessions)))
   :name "lisp-claw-session-cleanup"))
