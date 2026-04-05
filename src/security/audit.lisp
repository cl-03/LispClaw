;;; security/audit.lisp --- Audit Logging System for Lisp-Claw
;;;
;;; This file implements comprehensive audit logging:
;;; - Security event tracking
;;; - User action logging
;;; - System change tracking
;;; - Audit log query and export
;;; - Compliance reporting

(defpackage #:lisp-claw.security.audit
  (:nicknames #:lc.security.audit)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.crypto)
  (:export
   ;; Audit event class
   #:audit-event
   #:make-audit-event
   #:audit-event-id
   #:audit-event-type
   #:audit-event-category
   #:audit-event-severity
   #:audit-event-user
   #:audit-event-action
   #:audit-event-resource
   #:audit-event-details
   #:audit-event-timestamp
   #:audit-event-ip-address
   #:audit-event-session-id
   ;; Audit log
   #:audit-log
   #:make-audit-log
   #:audit-log-write
   #:audit-log-read
   #:audit-log-query
   ;; Event categories
   #:audit-auth-event
   #:audit-access-event
   #:audit-change-event
   #:audit-admin-event
   #:audit-security-event
   ;; Query functions
   #:audit-search
   #:audit-get-by-user
   #:audit-get-by-type
   #:audit-get-by-severity
   #:audit-get-by-time-range
   ;; Export/Import
   #:audit-export
   #:audit-import
   #:audit-export-to-file
   #:audit-import-from-file
   ;; Compliance
   #:audit-compliance-report
   #:audit-retention-policy
   ;; Global functions
   #:audit-write
   #:audit-query
   #:audit-alert))

(in-package #:lisp-claw.security.audit)

;;; ============================================================================
;;; Audit Event Class
;;; ============================================================================

(defclass audit-event ()
  ((id :initform (generate-event-id)
       :reader audit-event-id
       :documentation "Unique event identifier")
   (type :initarg :type
         :reader audit-event-type
         :documentation "Event type keyword")
   (category :initarg :category
             :initform :general
             :reader audit-event-category
             :documentation "Event category")
   (severity :initarg :severity
             :initform :info
             :reader audit-event-severity
             :documentation "Event severity: :info, :warning, :error, :critical")
   (user :initarg :user
         :initform nil
         :reader audit-event-user
         :documentation "User identifier")
   (action :initarg :action
           :reader audit-event-action
           :documentation "Action performed")
   (resource :initarg :resource
             :initform nil
             :reader audit-event-resource
             :documentation "Affected resource")
   (details :initarg :details
            :initform nil
            :reader audit-event-details
            :documentation "Event details (plist)")
   (timestamp :initform (get-universal-time)
              :reader audit-event-timestamp
              :documentation "Event timestamp")
   (ip-address :initarg :ip-address
               :initform nil
               :reader audit-event-ip-address
               :documentation "Source IP address")
   (session-id :initarg :session-id
               :initform nil
               :reader audit-event-session-id
               :documentation "Session identifier")
   (hostname :initform (machine-instance)
             :reader audit-event-hostname
             :documentation "Source hostname")
   (checksum :initform nil
             :accessor audit-event-checksum
             :documentation "Event integrity checksum"))
  (:documentation "Audit event representation"))

(defmethod print-object ((event audit-event) stream)
  (print-unreadable-object (event stream :type t)
    (format t "~A/~A [~A] ~A"
            (audit-event-category event)
            (audit-event-type event)
            (audit-event-severity event)
            (audit-event-timestamp event))))

;;; ============================================================================
;;; Event ID Generation
;;; ============================================================================

(defvar *event-counter* 0
  "Event ID counter.")

(defvar *event-counter-lock* (bt:make-lock "event-counter-lock")
  "Lock for event counter.")

(defun generate-event-id ()
  "Generate a unique event ID.

  Returns:
    Event ID string"
  (bt:with-lock-held (*event-counter-lock*)
    (incf *event-counter*)
    (format nil "audit-~A-~A-~A"
            (get-universal-time)
            *event-counter*
            (subseq (generate-random-hex-string 8) 0 8))))

;;; ============================================================================
;;; Audit Log Class
;;; ============================================================================

(defclass audit-log ()
  ((events :initform (make-array 10000 :adjustable t :fill-pointer 0)
           :accessor audit-log-events
           :documentation "Event storage")
   (lock :initform (bt:make-lock "audit-log-lock")
         :reader audit-log-lock
         :documentation "Log write lock")
   (write-index :initform (make-hash-table :test 'equal)
                :accessor audit-log-write-index
                :documentation "Write index for fast lookup")
   (max-size :initarg :max-size
             :initform 100000
             :reader audit-log-max-size
             :documentation "Maximum log entries")
   (retention-days :initarg :retention-days
                   :initform 90
                   :reader audit-log-retention-days
                   :documentation "Retention period in days"))
  (:documentation "Audit log storage"))

(defmethod print-object ((log audit-log) stream)
  (print-unreadable-object (log stream :type t)
    (format t "~A entries" (length (audit-log-events log)))))

;;; ============================================================================
;;; Global Audit Log
;;; ============================================================================

(defvar *audit-log* nil
  "Global audit log instance.")

(defvar *audit-enabled* t
  "Enable/disable audit logging.")

(defvar *audit-alerts* nil
  "Alert handlers for audit events.")

;;; ============================================================================
;;; Construction
;;; ============================================================================

(defun make-audit-log (&key max-size retention-days)
  "Create an audit log instance.

  Args:
    MAX-SIZE: Maximum entries
    RETENTION-DAYS: Retention period

  Returns:
    Audit log instance"
  (make-instance 'audit-log
                 :max-size (or max-size 100000)
                 :retention-days (or retention-days 90)))

(defun initialize-audit-log ()
  "Initialize the global audit log.

  Returns:
    T"
  (setf *audit-log* (make-audit-log))
  (setf *audit-enabled* t)
  (log-info "Audit log initialized")
  t)

;;; ============================================================================
;;; Event Creation Helpers
;;; ============================================================================

(defun make-audit-event (type action &key category severity user resource details
                                   ip-address session-id)
  "Create an audit event.

  Args:
    TYPE: Event type keyword
    ACTION: Action performed
    CATEGORY: Event category
    SEVERITY: Event severity
    USER: User identifier
    RESOURCE: Affected resource
    DETAILS: Event details
    IP-ADDRESS: Source IP
    SESSION-ID: Session identifier

  Returns:
    Audit event instance"
  (make-instance 'audit-event
                 :type type
                 :action action
                 :category (or category :general)
                 :severity (or severity :info)
                 :user user
                 :resource resource
                 :details details
                 :ip-address ip-address
                 :session-id session-id))

(defun compute-event-checksum (event)
  "Compute checksum for an event.

  Args:
    EVENT: Audit event

  Returns:
    Checksum string"
  (let ((data (format nil "~A~A~A~A~A~A"
                      (audit-event-id event)
                      (audit-event-type event)
                      (audit-event-action event)
                      (audit-event-user event)
                      (audit-event-timestamp event)
                      (audit-event-resource event))))
    (sha256-hex data)))

;;; ============================================================================
;;; Writing Events
;;; ============================================================================

(defun audit-log-write (log event)
  "Write an event to the audit log.

  Args:
    LOG: Audit log instance
    EVENT: Audit event

  Returns:
    T"
  (unless *audit-enabled*
    (return-from audit-log-write nil))

  (bt:with-lock-held ((audit-log-lock log))
    ;; Compute checksum for integrity
    (setf (audit-event-checksum event) (compute-event-checksum event))

    ;; Add to storage
    (vector-push-extend event (audit-log-events log))

    ;; Update index
    (let* ((type (audit-event-type event))
           (user (audit-event-user event))
           (time (audit-event-timestamp event)))
      (pushnew event (gethash (list :type type) (audit-log-write-index log)) :test #'eq)
      (when user
        (pushnew event (gethash (list :user user) (audit-log-write-index log)) :test #'eq))
      (pushnew event (gethash (list :date (decode-universal time)) (audit-log-write-index log)) :test #'eq))

    ;; Check size limit
    (when (> (length (audit-log-events log)) (audit-log-max-size log))
      (audit-log-truncate log)))

  ;; Trigger alerts if needed
  (when (member (audit-event-severity event) '(:error :critical))
    (audit-trigger-alert event))

  (log-info "[AUDIT] ~A: ~A - ~A"
            (audit-event-category event)
            (audit-event-type event)
            (audit-event-action event))
  t)

(defun audit-log-truncate (log)
  "Truncate old log entries.

  Args:
    LOG: Audit log instance

  Returns:
    Number of entries removed"
  (let* ((now (get-universal-time))
         (retention-seconds (* (audit-log-retention-days log) 24 60 60))
         (cutoff (- now retention-seconds))
         (count 0))
    (bt:with-lock-held ((audit-log-lock log))
      (let ((events (audit-log-events log)))
        (loop for i from (1- (length events)) downto 0
              for event = (aref events i)
              when (< (audit-event-timestamp event) cutoff)
              do (progn
                   (vector-pop events)
                   (incf count)))))
    (log-info "Audit log truncated: ~A entries removed" count)
    count))

;;; ============================================================================
;;; Convenience Functions
;;; ============================================================================

(defun audit-write (type action &rest args &key category severity user resource
                                      details ip-address session-id)
  "Write an audit event to the global log.

  Args:
    TYPE: Event type
    ACTION: Action performed
    CATEGORY: Event category
    SEVERITY: Event severity
    USER: User identifier
    RESOURCE: Affected resource
    DETAILS: Event details
    IP-ADDRESS: Source IP
    SESSION-ID: Session identifier

  Returns:
    T"
  (let ((event (make-audit-event type action
                                 :category category
                                 :severity severity
                                 :user user
                                 :resource resource
                                 :details details
                                 :ip-address ip-address
                                 :session-id session-id)))
    (audit-log-write *audit-log* event)))

;;; ============================================================================
;;; Event Category Helpers
;;; ============================================================================

(defun audit-auth-event (action &key user ip-address session-id details severity)
  "Log an authentication event.

  Args:
    ACTION: Auth action (login, logout, failed, password-change)
    USER: User identifier
    IP-ADDRESS: Source IP
    SESSION-ID: Session identifier
    DETAILS: Event details
    SEVERITY: Event severity

  Returns:
    T"
  (audit-write :auth action
               :category :authentication
               :severity (or severity (if (string= action "failed") :warning :info))
               :user user
               :ip-address ip-address
               :session-id session-id
               :details details))

(defun audit-access-event (action &key user resource details ip-address)
  "Log an access event.

  Args:
    ACTION: Access action (read, write, delete, denied)
    USER: User identifier
    RESOURCE: Accessed resource
    DETAILS: Event details
    IP-ADDRESS: Source IP

  Returns:
    T"
  (audit-write :access action
               :category :access-control
               :severity (if (string= action "denied") :warning :info)
               :user user
               :resource resource
               :ip-address ip-address
               :details details))

(defun audit-change-event (action &key user resource details severity)
  "Log a change event.

  Args:
    ACTION: Change action (create, update, delete, config-change)
    USER: User identifier
    RESOURCE: Changed resource
    DETAILS: Event details
    SEVERITY: Event severity

  Returns:
    T"
  (audit-write :change action
               :category :change-management
               :severity (or severity :info)
               :user user
               :resource resource
               :details details))

(defun audit-admin-event (action &key user resource details severity)
  "Log an administrative event.

  Args:
    ACTION: Admin action (user-create, user-delete, config-update, system-change)
    USER: User identifier
    RESOURCE: Affected resource
    DETAILS: Event details
    SEVERITY: Event severity

  Returns:
    T"
  (audit-write :admin action
               :category :administration
               :severity (or severity :info)
               :user user
               :resource resource
               :details details))

(defun audit-security-event (action &key user resource details ip-address severity)
  "Log a security event.

  Args:
    ACTION: Security action (intrusion, scan, attack, policy-violation)
    USER: User identifier
    RESOURCE: Affected resource
    DETAILS: Event details
    IP-ADDRESS: Source IP
    SEVERITY: Event severity

  Returns:
    T"
  (audit-write :security action
               :category :security
               :severity (or severity :warning)
               :user user
               :resource resource
               :ip-address ip-address
               :details details))

;;; ============================================================================
;;; Query Functions
;;; ============================================================================

(defun audit-log-query (log &key type category severity user resource
                             start-time end-time limit offset)
  "Query audit log entries.

  Args:
    LOG: Audit log instance
    TYPE: Filter by type
    CATEGORY: Filter by category
    SEVERITY: Filter by severity
    USER: Filter by user
    RESOURCE: Filter by resource
    START-TIME: Start timestamp
    END-TIME: End timestamp
    LIMIT: Maximum results
    OFFSET: Result offset

  Returns:
    List of matching events"
  (let ((results nil)
        (count 0))
    (bt:with-lock-held ((audit-log-lock log))
      (loop for i from (1- (length (audit-log-events log))) downto 0
            for event = (aref (audit-log-events log) i)
            when (and (or (null type)
                          (eq (audit-event-type event) type))
                      (or (null category)
                          (eq (audit-event-category event) category))
                      (or (null severity)
                          (eq (audit-event-severity event) severity))
                      (or (null user)
                          (string= user (audit-event-user event)))
                      (or (null resource)
                          (string= resource (audit-event-resource event)))
                      (or (null start-time)
                          (>= (audit-event-timestamp event) start-time))
                      (or (null end-time)
                          (<= (audit-event-timestamp event) end-time)))
            do (progn
                 (when (and offset (>= count offset))
                   (push event results))
                 (when (null offset)
                   (push event results))
                 (incf count)
                 (when (and limit (>= (length results) limit))
                   (return))))))
    results))

(defun audit-query (&rest args &key type category severity user resource
                               start-time end-time limit)
  "Query the global audit log.

  Args:
    TYPE: Filter by type
    CATEGORY: Filter by category
    SEVERITY: Filter by severity
    USER: Filter by user
    RESOURCE: Filter by resource
    START-TIME: Start timestamp
    END-TIME: End timestamp
    LIMIT: Maximum results

  Returns:
    List of matching events"
  (apply #'audit-log-query *audit-log* args))

(defun audit-search (log keyword &key limit)
  "Search audit log by keyword.

  Args:
    LOG: Audit log instance
    KEYWORD: Search keyword
    LIMIT: Maximum results

  Returns:
    List of matching events"
  (let ((results nil)
        (count 0))
    (bt:with-lock-held ((audit-log-lock log))
      (loop for event across (audit-log-events log)
            when (or (search keyword (string (audit-event-type event)))
                     (search keyword (string (audit-event-action event)))
                     (search keyword (string (audit-event-resource event))))
            do (progn
                 (push event results)
                 (incf count)
                 (when (and limit (>= count limit))
                   (return)))))
    results))

(defun audit-get-by-user (user &key limit)
  "Get events by user.

  Args:
    USER: User identifier
    LIMIT: Maximum results

  Returns:
    List of events"
  (audit-query :user user :limit (or limit 100)))

(defun audit-get-by-type (type &key limit)
  "Get events by type.

  Args:
    TYPE: Event type
    LIMIT: Maximum results

  Returns:
    List of events"
  (audit-query :type type :limit (or limit 100)))

(defun audit-get-by-severity (severity &key limit)
  "Get events by severity.

  Args:
    SEVERITY: Event severity
    LIMIT: Maximum results

  Returns:
    List of events"
  (audit-query :severity severity :limit (or limit 100)))

(defun audit-get-by-time-range (start-time end-time &key limit)
  "Get events within time range.

  Args:
    START-TIME: Start timestamp
    END-TIME: End timestamp
    LIMIT: Maximum results

  Returns:
    List of events"
  (audit-query :start-time start-time :end-time end-time :limit (or limit 100)))

;;; ============================================================================
;;; Alert System
;;; ============================================================================

(defun register-audit-alert-handler (handler)
  "Register an alert handler.

  Args:
    HANDLER: Handler function

  Returns:
    T"
  (push handler *audit-alerts*)
  t)

(defun audit-trigger-alert (event)
  "Trigger alerts for an event.

  Args:
    EVENT: Audit event

  Returns:
    T"
  (dolist (handler *audit-alerts*)
    (handler-case
        (funcall handler event)
      (error (e)
        (log-error "Alert handler failed: ~A" e))))
  t)

(defun audit-alert (severity message &key user resource details)
  "Trigger an audit alert.

  Args:
    SEVERITY: Alert severity
    MESSAGE: Alert message
    USER: User identifier
    RESOURCE: Affected resource
    DETAILS: Alert details

  Returns:
    T"
  (audit-write :alert message
               :category :alert
               :severity severity
               :user user
               :resource resource
               :details (append (list :message message) details)))

;;; ============================================================================
;;; Export/Import
;;; ============================================================================

(defun audit-export (log &key format)
  "Export audit log entries.

  Args:
    LOG: Audit log instance
    FORMAT: Export format (:json, :csv)

  Returns:
    Exported data string"
  (let ((events (audit-log-events log)))
    (ecase (or format :json)
      (:json
       (stringify-json
        (loop for event across events
              collect (list :id (audit-event-id event)
                            :type (audit-event-type event)
                            :category (audit-event-category event)
                            :severity (audit-event-severity event)
                            :user (audit-event-user event)
                            :action (audit-event-action event)
                            :resource (audit-event-resource event)
                            :timestamp (audit-event-timestamp event))))))))

(defun audit-export-to-file (log filename &key format)
  "Export audit log to file.

  Args:
    LOG: Audit log instance
    FILENAME: Output file
    FORMAT: Export format

  Returns:
    T"
  (let ((data (audit-export log :format format)))
    (with-open-file (out filename :direction :output :if-exists :supersede)
      (write-string data out))
    (log-info "Audit log exported to: ~A" filename)
    t))

(defun audit-import (log data &key format)
  "Import audit log entries.

  Args:
    LOG: Audit log instance
    DATA: Imported data
    FORMAT: Data format

  Returns:
    Number of entries imported"
  (let ((count 0))
    (ecase (or format :json)
      (:json
       (let ((events (parse-json data)))
         (dolist (event-data events)
           (let ((event (make-instance 'audit-event
                                       :type (getf event-data :type)
                                       :action (getf event-data :action)
                                       :category (getf event-data :category)
                                       :severity (getf event-data :severity)
                                       :user (getf event-data :user)
                                       :resource (getf event-data :resource))))
             (audit-log-write log event)
             (incf count))))))
    count))

(defun audit-import-from-file (log filename &key format)
  "Import audit log from file.

  Args:
    LOG: Audit log instance
    FILENAME: Input file
    FORMAT: Data format

  Returns:
    Number of entries imported"
  (with-open-file (in filename :direction :input)
    (let ((data (make-string (file-length in))))
      (read-sequence data in)
      (audit-import log data :format format))))

;;; ============================================================================
;;; Compliance Reporting
;;; ============================================================================

(defun audit-compliance-report (&key start-time end-time)
  "Generate a compliance report.

  Args:
    START-TIME: Report start time
    END-TIME: Report end time

  Returns:
    Report plist"
  (let* ((events (audit-get-by-time-range start-time end-time :limit 10000))
         (auth-events (remove-if-not (lambda (e) (eq (audit-event-category e) :authentication)) events))
         (access-events (remove-if-not (lambda (e) (eq (audit-event-category e) :access-control)) events))
         (change-events (remove-if-not (lambda (e) (eq (audit-event-category e) :change-management)) events))
         (security-events (remove-if-not (lambda (e) (eq (audit-event-category e) :security)) events)))
    (list :period (list :start start-time :end end-time)
          :total-events (length events)
          :authentication-events (length auth-events)
          :access-control-events (length access-events)
          :change-management-events (length change-events)
          :security-events (length security-events)
          :failed-auth (length (remove-if-not (lambda (e)
                                                (string= (audit-event-action e) "failed"))
                                              auth-events))
          :access-denied (length (remove-if-not (lambda (e)
                                                  (string= (audit-event-action e) "denied"))
                                                access-events))
          :critical-events (length (remove-if-not (lambda (e)
                                                    (eq (audit-event-severity e) :critical))
                                                  events))
          :generated-at (get-universal-time))))

(defun audit-retention-policy (log)
  "Get retention policy info.

  Args:
    LOG: Audit log instance

  Returns:
    Policy plist"
  (list :retention-days (audit-log-retention-days log)
        :max-entries (audit-log-max-size log)
        :current-size (length (audit-log-events log))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-audit-system ()
  "Initialize the audit system.

  Returns:
    T"
  (initialize-audit-log)
  (log-info "Audit system initialized")
  t)
