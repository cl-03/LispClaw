;;; automation/scheduler.lisp --- Enhanced Task Scheduler for Lisp-Claw
;;;
;;; This file provides an enhanced task scheduler with cron support,
;;; heartbeat monitoring, and task distribution capabilities.
;;; Based on OpenClaw's scheduler architecture.

(defpackage #:lisp-claw.automation.scheduler
  (:nicknames #:lc.auto.scheduler)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:local-time
        #:lisp-claw.utils.logging)
  (:export
   ;; Scheduler
   #:scheduler
   #:make-scheduler
   #:scheduler-start
   #:scheduler-stop
   #:scheduler-running-p
   ;; Task management
   #:schedule-task
   #:cancel-task
   #:list-scheduled-tasks
   #:get-task-info
   ;; Cron jobs
   #:register-cron-job
   #:unregister-cron-job
   #:list-cron-jobs
   #:parse-cron-expression
   ;; Heartbeat
   #:register-heartbeat
   #:unregister-heartbeat
   #:list-heartbeats
   ;; Task queue
   #:enqueue-task
   #:dequeue-task
   #:queue-size
   ;; Execution history
   #:get-execution-history
   #:clear-execution-history
   ;; Predefined schedules
   #:every-minute
   #:every-5-minutes
   #:every-hour
   #:daily
   #:weekly
   #:monthly))

(in-package #:lisp-claw.automation.scheduler)

;;; ============================================================================
;;; Scheduler Class
;;; ============================================================================

(defclass scheduler ()
  ((tasks :initform (make-hash-table :test 'equal)
          :accessor scheduler-tasks
          :documentation "Hash table of scheduled tasks")
   (cron-jobs :initform (make-hash-table :test 'equal)
              :accessor scheduler-cron-jobs
              :documentation "Hash table of cron jobs")
   (heartbeats :initform (make-hash-table :test 'equal)
               :accessor scheduler-heartbeats
               :documentation "Hash table of heartbeat monitors")
   (queue :initform nil
          :accessor scheduler-queue
          :documentation "Task queue")
   (queue-lock :initform (bt:make-lock)
               :reader scheduler-queue-lock
               :documentation "Queue lock")
   (running-p :initform nil
              :accessor scheduler-running-p
              :documentation "Whether scheduler is running")
   (scheduler-thread :initform nil
                     :accessor scheduler-thread
                     :documentation "Scheduler thread")
   (history :initform (make-array 1000 :adjustable t :fill-pointer 0)
            :accessor scheduler-history
            :documentation "Execution history")
   (history-lock :initform (bt:make-lock)
                :reader scheduler-history-lock
                :documentation "History lock"))
  (:documentation "Enhanced task scheduler"))

(defvar *scheduler* nil
  "Global scheduler instance.")

(defun make-scheduler ()
  "Create a new scheduler instance.

  Returns:
    Scheduler instance"
  (make-instance 'scheduler))

(defmethod print-object ((scheduler scheduler) stream)
  (print-unreadable-object (scheduler stream :type t)
    (format stream "~A tasks, ~A cron jobs, ~A queue"
            (hash-table-count (scheduler-tasks scheduler))
            (hash-table-count (scheduler-cron-jobs scheduler))
            (length (scheduler-queue scheduler)))))

;;; ============================================================================
;;; Task Class
;;; ============================================================================

(defclass scheduled-task ()
  ((id :initarg :id
       :reader task-id
       :documentation "Unique task identifier")
   (name :initarg :name
         :reader task-name
         :documentation "Task name")
   (action :initarg :action
           :reader task-action
           :documentation "Function to execute")
   (scheduled-time :initarg :scheduled-time
                   :reader task-scheduled-time
                   :documentation "Scheduled execution time (universal time)")
   (priority :initarg :priority
             :initform 5
             :reader task-priority
             :documentation "Priority (1-10, higher = more urgent)")
   (repeat-p :initarg :repeat-p
             :initform nil
             :reader task-repeat-p
             :documentation "Whether to repeat")
   (repeat-interval :initarg :repeat-interval
                    :initform nil
                    :reader task-repeat-interval
                    :documentation "Repeat interval in seconds")
   (callback :initarg :callback
             :initform nil
             :reader task-callback
             :documentation "Callback function after execution")
   (metadata :initarg :metadata
             :initform nil
             :reader task-metadata
             :documentation "Additional metadata")
   (status :initform :pending
           :accessor task-status
           :documentation "Task status: pending, running, completed, failed, cancelled")
   (result :initform nil
           :accessor task-result
           :documentation "Execution result")
   (error :initform nil
          :accessor task-error
          :documentation "Error if failed")
   (executed-at :initform nil
                :accessor task-executed-at
                :documentation "Actual execution time")
   (completed-at :initform nil
                 :accessor task-completed-at
                 :documentation "Completion time"))
  (:documentation "Scheduled task"))

(defmethod print-object ((task scheduled-task) stream)
  (print-unreadable-object (task stream :type t)
    (format stream "~A [~A] ~A"
            (task-name task)
            (task-status task)
            (task-scheduled-time task))))

;;; ============================================================================
;;; Cron Expression Parser
;;; ============================================================================

(defun parse-cron-expression (expression)
  "Parse a cron expression into schedule components.

  Args:
    EXPRESSION: Cron expression (minute hour day month weekday)

  Returns:
    Plist with :minutes, :hours, :days, :months, :weekdays

  Examples:
    \"*/5 * * * *\" - Every 5 minutes
    \"0 9 * * 1-5\" - Weekdays at 9am
    \"0 0 1 * *\"   - First day of each month"
  (let* ((parts (split-sequence:split-sequence #\Space expression))
         (minute (parse-cron-field (first parts) 0 59))
         (hour (parse-cron-field (second parts) 0 23))
         (day (parse-cron-field (third parts) 1 31))
         (month (parse-cron-field (fourth parts) 1 12))
         (weekday (parse-cron-field (fifth parts) 0 6)))
    (list :minutes minute
          :hours hour
          :days day
          :months month
          :weekdays weekday)))

(defun parse-cron-field (field min-val max-val)
  "Parse a single cron field.

  Args:
    FIELD: Field string (e.g., \"*/5\", \"1-5\", \"1,3,5\")
    MIN-VAL: Minimum value
    MAX-VAL: Maximum value

  Returns:
    List of valid values"
  (cond
    ;; Wildcard
    ((string= field "*")
     (loop for i from min-val to max-val collect i))
    ;; Step (*/n)
    ((and (> (length field) 2)
          (char= (char field 0) #\*)
          (char= (char field 1) #\/))
     (let ((step (parse-integer (subseq field 2))))
       (loop for i from min-val to max-val by step collect i)))
    ;; Range (n-m)
    ((position #\- field)
     (let* ((dash-pos (position #\- field))
            (start (parse-integer (subseq field 0 dash-pos)))
            (end (parse-integer (subseq field (1+ dash-pos)))))
       (loop for i from start to (min end max-val) collect i)))
    ;; List (n,m,o)
    ((position #\, field)
     (mapcar #'parse-integer
             (split-sequence:split-sequence #\, field)))
    ;; Single value
    (t
     (list (parse-integer field)))))

(defun cron-next-time (parsed-cron &optional from-time)
  "Calculate the next execution time for a parsed cron expression.

  Args:
    PARSED-CRON: Parsed cron expression (from parse-cron-expression)
    FROM-TIME: Base time (default: now)

  Returns:
    Next execution time (decoded time values)"
  (let* ((now (or from-time (get-universal-time)))
         (decoded (multiple-value-list (decode-universal-time now 0)))
         (minute (nth 1 decoded))
         (hour (nth 2 decoded))
         (day (nth 3 decoded))
         (month (nth 4 decoded))
         (year (nth 5 decoded))
         (weekday (nth 6 decoded)))
    (declare (ignore weekday))
    ;; Simple implementation: find next matching time
    (loop with minutes = (getf parsed-cron :minutes)
          with hours = (getf parsed-cron :hours)
          with days = (getf parsed-cron :days)
          with months = (getf parsed-cron :months)
          with weekdays = (getf parsed-cron :weekdays)
          for m = minute then (if (>= m 59) 0 (1+ m))
          for h = hour then (if (and (>= m 59) (>= h 23)) 0 (if (>= m 59) (1+ h) h))
          for d = day then (if (and (>= m 59) (>= h 23) (>= d 31)) 1 (if (and (>= m 59) (>= h 23)) (1+ d) d))
          for mon = month then (if (and (>= m 59) (>= h 23) (>= d 31) (>= mon 12)) 1
                                                        (if (and (>= m 59) (>= h 23) (>= d 31)) (1+ mon) mon))
          for y = year then (if (and (>= m 59) (>= h 23) (>= d 31) (>= mon 12)) (1+ y) y)
          when (and (member m minutes)
                    (member h hours)
                    (member d days)
                    (member mon months))
          return (encode-universal-time 0 m h d mon y 0))))

;;; ============================================================================
;;; Task Scheduling
;;; ============================================================================

(defun schedule-task (scheduler name action &key delay priority repeat-p repeat-interval metadata)
  "Schedule a task for execution.

  Args:
    SCHEDULER: Scheduler instance
    NAME: Task name
    ACTION: Function to execute
    DELAY: Delay in seconds (default: 0 = immediate)
    PRIORITY: Priority 1-10 (default: 5)
    REPEAT-P: Whether to repeat
    REPEAT-INTERVAL: Repeat interval in seconds
    METADATA: Additional metadata

  Returns:
    Task ID"
  (let* ((task-id (format nil "task-~A-~A" (get-universal-time) (random 1000000)))
         (scheduled-time (+ (get-universal-time) (or delay 0)))
         (task (make-instance 'scheduled-task
                              :id task-id
                              :name name
                              :action action
                              :scheduled-time scheduled-time
                              :priority (or priority 5)
                              :repeat-p repeat-p
                              :repeat-interval repeat-interval
                              :metadata metadata)))
    (setf (gethash task-id (scheduler-tasks scheduler)) task)
    (log-info "Scheduled task ~A: ~A at ~A" task-id name scheduled-time)
    task-id))

(defun cancel-task (scheduler task-id)
  "Cancel a scheduled task.

  Args:
    SCHEDULER: Scheduler instance
    TASK-ID: Task ID to cancel

  Returns:
    T if cancelled, NIL if not found"
  (let ((task (gethash task-id (scheduler-tasks scheduler))))
    (when task
      (setf (task-status task) :cancelled)
      (remhash task-id (scheduler-tasks scheduler))
      (log-info "Cancelled task ~A" task-id)
      t)))

(defun list-scheduled-tasks (scheduler)
  "List all scheduled tasks.

  Args:
    SCHEDULER: Scheduler instance

  Returns:
    List of task info plists"
  (let ((tasks nil))
    (maphash (lambda (id task)
               (push (list :id id
                           :name (task-name task)
                           :scheduled-time (task-scheduled-time task)
                           :priority (task-priority task)
                           :status (task-status task)
                           :repeat-p (task-repeat-p task))
                     tasks))
             (scheduler-tasks scheduler))
    (sort tasks #'< :key (lambda (x) (getf x :scheduled-time)))))

(defun get-task-info (scheduler task-id)
  "Get information about a specific task.

  Args:
    SCHEDULER: Scheduler instance
    TASK-ID: Task ID

  Returns:
    Task info plist or NIL"
  (let ((task (gethash task-id (scheduler-tasks scheduler))))
    (when task
      (list :id task-id
            :name (task-name task)
            :scheduled-time (task-scheduled-time task)
            :priority (task-priority task)
            :status (task-status task)
            :result (task-result task)
            :error (task-error task)
            :executed-at (task-executed-at task)
            :completed-at (task-completed-at task)))))

;;; ============================================================================
;;; Cron Job Management
;;; ============================================================================

(defun register-cron-job (scheduler name cron-expression action &key metadata)
  "Register a cron job.

  Args:
    SCHEDULER: Scheduler instance
    NAME: Job name
    CRON-EXPRESSION: Cron expression
    ACTION: Function to execute
    METADATA: Additional metadata

  Returns:
    Job ID"
  (let* ((job-id (format nil "cron-~A" name))
         (parsed (parse-cron-expression cron-expression))
         (next-run (cron-next-time parsed))
         (job (list :id job-id
                    :name name
                    :expression cron-expression
                    :parsed parsed
                    :action action
                    :metadata metadata
                    :next-run next-run
                    :enabled t)))
    (setf (gethash job-id (scheduler-cron-jobs scheduler)) job)
    (log-info "Registered cron job ~A: ~A" job-id cron-expression)
    job-id))

(defun unregister-cron-job (scheduler job-id)
  "Unregister a cron job.

  Args:
    SCHEDULER: Scheduler instance
    JOB-ID: Job ID

  Returns:
    T on success"
  (when (gethash job-id (scheduler-cron-jobs scheduler))
    (remhash job-id (scheduler-cron-jobs scheduler))
    (log-info "Unregistered cron job ~A" job-id)
    t))

(defun list-cron-jobs (scheduler)
  "List all cron jobs.

  Args:
    SCHEDULER: Scheduler instance

  Returns:
    List of job info plists"
  (let ((jobs nil))
    (maphash (lambda (id job)
               (push (list :id id
                           :name (getf job :name)
                           :expression (getf job :expression)
                           :next-run (getf job :next-run)
                           :enabled (getf job :enabled))
                     jobs))
             (scheduler-cron-jobs scheduler))
    jobs))

;;; ============================================================================
;;; Heartbeat Monitoring
;;; ============================================================================

(defun register-heartbeat (scheduler name interval action &key timeout)
  "Register a heartbeat monitor.

  Args:
    SCHEDULER: Scheduler instance
    NAME: Heartbeat name
    INTERVAL: Expected interval in seconds
    ACTION: Function to call on heartbeat
    TIMEOUT: Timeout in seconds (default: interval * 2)

  Returns:
    T"
  (let ((heartbeat-id (format nil "heartbeat-~A" name)))
    (setf (gethash heartbeat-id (scheduler-heartbeats scheduler))
          (list :id heartbeat-id
                :name name
                :interval interval
                :timeout (or timeout (* interval 2))
                :action action
                :last-beat (get-universal-time)
                :enabled t))
    (log-info "Registered heartbeat: ~A (interval: ~As)" name interval)
    t))

(defun unregister-heartbeat (scheduler heartbeat-id)
  "Unregister a heartbeat monitor.

  Args:
    SCHEDULER: Scheduler instance
    HEARTBEAT-ID: Heartbeat ID

  Returns:
    T on success"
  (when (gethash heartbeat-id (scheduler-heartbeats scheduler))
    (remhash heartbeat-id (scheduler-heartbeats scheduler))
    (log-info "Unregistered heartbeat: ~A" heartbeat-id)
    t))

(defun list-heartbeats (scheduler)
  "List all heartbeat monitors.

  Args:
    SCHEDULER: Scheduler instance

  Returns:
    List of heartbeat info plists"
  (let ((heartbeats nil))
    (maphash (lambda (id hb)
               (push (list :id id
                           :name (getf hb :name)
                           :interval (getf hb :interval)
                           :last-beat (getf hb :last-beat)
                           :enabled (getf hb :enabled))
                     heartbeats))
             (scheduler-heartbeats scheduler))
    heartbeats))

;;; ============================================================================
;;; Task Queue
;;; ============================================================================

(defun enqueue-task (scheduler task &key priority)
  "Add a task to the execution queue.

  Args:
    SCHEDULER: Scheduler instance
    TASK: Task to enqueue
    PRIORITY: Optional priority override

  Returns:
    T"
  (bt:with-lock-held ((scheduler-queue-lock scheduler))
    (if priority
        ;; Insert by priority
        (let ((inserted nil))
          (loop for i from 0 below (length (scheduler-queue scheduler))
                when (< priority (task-priority (nth i (scheduler-queue scheduler))))
                do (progn
                     (setf (scheduler-queue scheduler)
                           (append (subseq (scheduler-queue scheduler) 0 i)
                                   (list task)
                                   (subseq (scheduler-queue scheduler) i)))
                     (setf inserted t)
                     (return))
                finally (unless inserted
                          (push task (scheduler-queue scheduler)))))
        ;; Add to end
        (push task (scheduler-queue scheduler))))
  t)

(defun dequeue-task (scheduler)
  "Remove and return the highest priority task from the queue.

  Args:
    SCHEDULER: Scheduler instance

  Returns:
    Task or NIL"
  (bt:with-lock-held ((scheduler-queue-lock scheduler))
    (let ((task (car (last (scheduler-queue scheduler)))))
      (when task
        (setf (scheduler-queue scheduler)
              (butlast (scheduler-queue scheduler))))
      task)))

(defun queue-size (scheduler)
  "Get the current queue size.

  Args:
    SCHEDULER: Scheduler instance

  Returns:
    Number of tasks in queue"
  (length (scheduler-queue scheduler)))

;;; ============================================================================
;;; Execution History
;;; ============================================================================

(defun record-execution (scheduler task-id task-name status duration &key result error)
  "Record a task execution in history.

  Args:
    SCHEDULER: Scheduler instance
    TASK-ID: Task ID
    TASK-NAME: Task name
    STATUS: Execution status
    DURATION: Execution duration in seconds
    RESULT: Optional result
    ERROR: Optional error

  Returns:
    T"
  (bt:with-lock-held ((scheduler-history-lock scheduler))
    (vector-push-extend
     (list :timestamp (get-universal-time)
           :task-id task-id
           :task-name task-name
           :status status
           :duration duration
           :result result
           :error error)
     (scheduler-history scheduler)))
  t)

(defun get-execution-history (scheduler &key limit task-id)
  "Get execution history.

  Args:
    SCHEDULER: Scheduler instance
    LIMIT: Maximum entries to return
    TASK-ID: Filter by task ID

  Returns:
    List of history entries"
  (let ((history nil))
    (bt:with-lock-held ((scheduler-history-lock scheduler))
      (let ((len (length (scheduler-history scheduler))))
        (loop for i from (1- len) downto 0
              for entry = (aref (scheduler-history scheduler) i)
              when (or (null task-id)
                       (string= task-id (getf entry :task-id)))
              do (push entry history)
              when (and limit (>= (length history) limit))
              do (return))))
    history))

(defun clear-execution-history (scheduler)
  "Clear the execution history.

  Args:
    SCHEDULER: Scheduler instance

  Returns:
    T"
  (bt:with-lock-held ((scheduler-history-lock scheduler))
    (setf (scheduler-history scheduler)
          (make-array 1000 :adjustable t :fill-pointer 0)))
  t)

;;; ============================================================================
;;; Scheduler Execution
;;; ============================================================================

(defun scheduler-start (scheduler)
  "Start the scheduler.

  Args:
    SCHEDULER: Scheduler instance

  Returns:
    T"
  (when (scheduler-running-p scheduler)
    (log-warn "Scheduler already running")
    (return-from scheduler-start t))

  (setf (scheduler-running-p scheduler) t)
  (setf (scheduler-thread scheduler)
        (bt:make-thread
         (lambda ()
           (scheduler-loop scheduler))
         :name "scheduler-loop"))

  (log-info "Scheduler started")
  t)

(defun scheduler-stop (scheduler)
  "Stop the scheduler.

  Args:
    SCHEDULER: Scheduler instance

  Returns:
    T"
  (setf (scheduler-running-p scheduler) nil)
  (when (scheduler-thread scheduler)
    (bt:destroy-thread (scheduler-thread scheduler)))
  (log-info "Scheduler stopped")
  t)

(defun scheduler-loop (scheduler)
  "Main scheduler loop.

  Args:
    SCHEDULER: Scheduler instance"
  (loop while (scheduler-running-p scheduler)
        do (progn
             ;; Check and execute due tasks
             (scheduler-check-tasks scheduler)
             ;; Check cron jobs
             (scheduler-check-cron scheduler)
             ;; Check heartbeats
             (scheduler-check-heartbeats scheduler)
             ;; Sleep briefly
             (sleep 1))))

(defun scheduler-check-tasks (scheduler)
  "Check and execute due tasks.

  Args:
    SCHEDULER: Scheduler instance"
  (let ((now (get-universal-time)))
    (maphash (lambda (id task)
               (declare (ignore id))
               (when (and (eq (task-status task) :pending)
                          (<= (task-scheduled-time task) now))
                 (execute-task scheduler task)))
             (scheduler-tasks scheduler))))

(defun execute-task (scheduler task)
  "Execute a scheduled task.

  Args:
    SCHEDULER: Scheduler instance
    TASK: Task to execute"
  (setf (task-status task) :running
        (task-executed-at task) (get-universal-time))

  (let ((start-time (get-universal-time))
        (result nil)
        (error nil))
    (handler-case
        (progn
          (setf result (funcall (task-action task)))
          (setf (task-status task) :completed
                (task-result task) result))
      (error (e)
        (setf (task-status task) :failed
              (task-error task) e)
        (setf error e)))

    (let ((end-time (get-universal-time))
          (duration (- end-time start-time)))
      (record-execution scheduler
                        (task-id task)
                        (task-name task)
                        (task-status task)
                        duration
                        :result result
                        :error error))

    ;; Handle callback
    (when (task-callback task)
      (funcall (task-callback task) task))

    ;; Handle repeat
    (when (task-repeat-p task)
      (setf (task-scheduled-time task)
            (+ (get-universal-time) (task-repeat-interval task))
            (task-status task) :pending
            (task-result task) nil
            (task-error task) nil))))

(defun scheduler-check-cron (scheduler)
  "Check and trigger due cron jobs.

  Args:
    SCHEDULER: Scheduler instance"
  (let ((now (get-universal-time)))
    (maphash (lambda (id job)
               (when (and (getf job :enabled)
                          (<= (getf job :next-run 0) now))
                 ;; Execute job
                 (handler-case
                     (funcall (getf job :action))
                   (error (e)
                     (log-error "Cron job ~A failed: ~A" id e)))
                 ;; Calculate next run
                 (let* ((parsed (getf job :parsed))
                        (next (cron-next-time parsed now)))
                   (setf (getf job :next-run) next))))
             (scheduler-cron-jobs scheduler))))

(defun scheduler-check-heartbeats (scheduler)
  "Check heartbeat monitors.

  Args:
    SCHEDULER: Scheduler instance"
  (let ((now (get-universal-time)))
    (maphash (lambda (id hb)
               (when (getf hb :enabled)
                 (let ((last-beat (getf hb :last-beat))
                       (timeout (getf hb :timeout)))
                   (when (and last-beat
                              (> (- now last-beat) timeout))
                     ;; Heartbeat timeout
                     (log-warn "Heartbeat ~A timed out" (getf hb :name))
                     ;; Call action with timeout indicator
                     (when (getf hb :action)
                       (funcall (getf hb :action) :timeout t))))))
             (scheduler-heartbeats scheduler))))

;;; ============================================================================
;;; Predefined Schedules
;;; ============================================================================

(defun every-minute () "* * * * *")
(defun every-5-minutes () "*/5 * * * *")
(defun every-15-minutes () "*/15 * * * *")
(defun every-30-minutes () "*/30 * * * *")
(defun every-hour () "0 * * * *")
(defun every-6-hours () "0 */6 * * *")
(defun daily () "0 0 * * *")
(defun daily-at (hour minute) (format nil "~A ~A * * *" minute hour))
(defun weekly () "0 0 * * 0")
(defun weekly-on (weekday hour minute)
  (format nil "~A ~A * * ~A" minute hour weekday))
(defun monthly () "0 0 1 * *")
(defun monthly-on (day hour minute)
  (format nil "~A ~A ~A * *" minute hour day))

;;; ============================================================================
;;; Global Scheduler Access
;;; ============================================================================

(defun ensure-scheduler ()
  "Ensure global scheduler exists.

  Returns:
    Scheduler instance"
  (or *scheduler*
      (setf *scheduler* (make-scheduler))))

(defun start-scheduler ()
  "Start the global scheduler.

  Returns:
    T"
  (scheduler-start (ensure-scheduler)))

(defun stop-scheduler ()
  "Stop the global scheduler.

  Returns:
    T"
  (scheduler-stop (ensure-scheduler)))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-scheduler-system ()
  "Initialize the scheduler system.

  Returns:
    T"
  (ensure-scheduler)
  (log-info "Scheduler system initialized")
  t)
