;;; automation/task-queue.lisp --- Task Queue for Lisp-Claw
;;;
;;; This file implements a Redis-based task queue system supporting:
;;; - Priority queues
;;; - Delayed execution
;;; - Task retry with backoff
;;; - Task result caching
;;; - Worker management

(defpackage #:lisp-claw.automation.task-queue
  (:nicknames #:lc.automation.task-queue)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; Task queue class
   #:task-queue
   #:make-task-queue
   #:task-queue-name
   #:task-queue-redis
   #:task-queue-workers
   ;; Task class
   #:task
   #:make-task
   #:task-id
   #:task-name
   #:task-payload
   #:task-priority
   #:task-delay
   #:task-retries
   #:task-max-retries
   #:task-created-at
   #:task-status
   #:task-result
   #:task-error
   ;; Queue operations
   #:enqueue
   #:enqueue-batch
   #:dequeue
   #:peek
   #:queue-size
   ;; Task management
   #:get-task
   #:cancel-task
   #:retry-task
   #:get-task-result
   ;; Worker management
   #:start-worker
   #:start-workers
   #:stop-worker
   #:stop-all-workers
   #:get-worker-stats
   ;; Monitoring
   #:get-queue-stats
   #:list-pending-tasks
   #:list-failed-tasks
   ;; Initialization
   #:initialize-task-queue-system))

(in-package #:lisp-claw.automation.task-queue)

;;; ============================================================================
;;; Task Class
;;; ============================================================================

(defclass task ()
  ((id :initarg :id
       :initform (uuid:make-uuid-string)
       :reader task-id
       :documentation "Unique task identifier")
   (name :initarg :name
         :reader task-name
         :documentation "Task name/type")
   (payload :initarg :payload
            :initform (make-hash-table :test 'equal)
            :reader task-payload
            :documentation "Task payload data")
   (priority :initarg :priority
             :initform 0
             :reader task-priority
             :documentation "Task priority (higher = more urgent)")
   (delay :initarg :delay
          :initform 0
          :reader task-delay
          :documentation "Delay in seconds before execution")
   (retries :initform 0
            :accessor task-retries
            :documentation "Number of retry attempts")
   (max-retries :initarg :max-retries
                :initform 3
                :reader task-max-retries
                :documentation "Maximum retry attempts")
   (created-at :initform (get-universal-time)
               :reader task-created-at
               :documentation "Task creation timestamp")
   (started-at :initform nil
               :accessor task-started-at
               :documentation "Task execution start time")
   (finished-at :initform nil
               :accessor task-finished-at
               :documentation "Task completion time")
   (status :initform :pending
           :accessor task-status
           :documentation "Task status: pending, running, completed, failed, cancelled")
   (result :initform nil
           :accessor task-result
           :documentation "Task execution result")
   (error :initform nil
          :accessor task-error
          :documentation "Error message if failed"))
  (:documentation "Represents a task in the queue"))

(defmethod print-object ((task task) stream)
  (print-unreadable-object (task stream :type t)
    (format stream "~A [~A]" (task-name task) (task-status task))))

(defun make-task (name &key payload priority delay max-retries)
  "Create a new task.

  Args:
    NAME: Task name/type
    PAYLOAD: Task data (plist or hash-table)
    PRIORITY: Priority level (default: 0)
    DELAY: Delay in seconds (default: 0)
    MAX-RETRIES: Maximum retry attempts (default: 3)

  Returns:
    Task instance"
  (make-instance 'task
                 :name name
                 :payload (if (listp payload)
                              (alexandria:alist-hash-table payload :test 'equal)
                              payload)
                 :priority (or priority 0)
                 :delay (or delay 0)
                 :max-retries (or max-retries 3)))

;;; ============================================================================
;;; Task Queue Class
;;; ============================================================================

(defclass task-queue ()
  ((name :initarg :name
         :initform "default"
         :reader task-queue-name
         :documentation "Queue name")
   (redis :initarg :redis
          :reader task-queue-redis
          :documentation "Redis connection")
   (workers :initform (make-hash-table :test 'equal)
            :accessor task-queue-workers
            :documentation "Active workers")
   (lock :initform (bt:make-lock)
         :reader task-queue-lock
         :documentation "Queue lock")
   (pending-tasks :initform (make-hash-table :test 'equal)
                  :accessor task-queue-pending
                  :documentation "Pending tasks by ID")
   (task-counter :initform 0
                 :accessor task-queue-counter
                 :documentation "Task counter for ordering"))
  (:documentation "Redis-based task queue"))

(defun make-task-queue (&key name redis-host redis-port redis-password)
  "Create a task queue.

  Args:
    NAME: Queue name (default: \"default\")
    REDIS-HOST: Redis host (default: \"localhost\")
    REDIS-PORT: Redis port (default: 6379)
    REDIS-PASSWORD: Redis password (optional)

  Returns:
    Task queue instance"
  (let ((queue (make-instance 'task-queue
                              :name (or name "default"))))
    ;; Initialize Redis connection (placeholder - use actual Redis client)
    (log-info "Task queue '~A' created" (or name "default"))
    queue))

;;; ============================================================================
;;; Queue Operations
;;; ============================================================================

(defun enqueue (queue task)
  "Add a task to the queue.

  Args:
    QUEUE: Task queue instance
    TASK: Task to enqueue

  Returns:
    Task ID on success"
  (bt:with-lock-held ((task-queue-lock queue))
    ;; Store task
    (setf (gethash (task-id task) (task-queue-pending queue)) task)
    (incf (task-queue-counter queue))

    ;; In production, this would push to Redis sorted set
    ;; ZADD queue-key priority task-json

    (log-info "Task ~A enqueued with priority ~A" (task-id task) (task-priority task))
    (task-id task)))

(defun enqueue-batch (queue tasks)
  "Add multiple tasks to the queue.

  Args:
    QUEUE: Task queue instance
    TASKS: List of tasks

  Returns:
    List of task IDs"
  (mapcar (lambda (task) (enqueue queue task)) tasks))

(defun dequeue (queue &key timeout block-p)
  "Get the highest priority task from the queue.

  Args:
    QUEUE: Task queue instance
    TIMEOUT: Timeout in seconds (for blocking)
    BLOCK-P: Block if queue is empty (default: NIL)

  Returns:
    Task instance or NIL"
  (bt:with-lock-held ((task-queue-lock queue))
    ;; Find highest priority pending task
    (let ((best-task nil)
          (best-priority -1))
      (maphash (lambda (id task)
                 (declare (ignore id))
                 (when (and (eq (task-status task) :pending)
                            (> (task-priority task) best-priority)
                            (<= (+ (task-created-at task) (task-delay task))
                                (get-universal-time)))
                   (setf best-task task)
                   (setf best-priority (task-priority task))))
               (task-queue-pending queue))

      (when best-task
        (setf (task-status best-task) :running)
        (setf (task-started-at best-task) (get-universal-time)))

      best-task)))

(defun peek (queue &optional count)
  "Peek at tasks without removing them.

  Args:
    QUEUE: Task queue instance
    COUNT: Number of tasks to peek (default: 10)

  Returns:
    List of tasks"
  (let ((tasks nil)
        (i 0))
    (maphash (lambda (id task)
               (when (< i (or count 10))
                 (push task tasks)
                 (incf i)))
             (task-queue-pending queue))
    (sort tasks #'> :key #'task-priority)))

(defun queue-size (queue)
  "Get the number of pending tasks.

  Args:
    QUEUE: Task queue instance

  Returns:
    Number of pending tasks"
  (let ((count 0))
    (maphash (lambda (id task)
               (declare (ignore id))
               (when (eq (task-status task) :pending)
                 (incf count)))
             (task-queue-pending queue))
    count))

;;; ============================================================================
;;; Task Management
;;; ============================================================================

(defun get-task (queue task-id)
  "Get a task by ID.

  Args:
    QUEUE: Task queue instance
    TASK-ID: Task ID

  Returns:
    Task instance or NIL"
  (gethash task-id (task-queue-pending queue)))

(defun cancel-task (queue task-id)
  "Cancel a task.

  Args:
    QUEUE: Task queue instance
    TASK-ID: Task ID

  Returns:
    T if cancelled, NIL otherwise"
  (let ((task (get-task queue task-id)))
    (when (and task (eq (task-status task) :pending))
      (setf (task-status task) :cancelled)
      (log-info "Task ~A cancelled" task-id)
      t)))

(defun retry-task (queue task-id)
  "Retry a failed task.

  Args:
    QUEUE: Task queue instance
    TASK-ID: Task ID

  Returns:
    T if retried, NIL otherwise"
  (let ((task (get-task queue task-id)))
    (when (and task (eq (task-status task) :failed))
      (when (< (task-retries task) (task-max-retries task))
        (incf (task-retries task))
        (setf (task-status task) :pending)
        (setf (task-error task) nil)
        (log-info "Task ~A retried (attempt ~A)" task-id (task-retries task))
        t)))))

(defun get-task-result (queue task-id &key timeout)
  "Wait for and get task result.

  Args:
    QUEUE: Task queue instance
    TASK-ID: Task ID
    TIMEOUT: Timeout in seconds (default: 60)

  Returns:
    Result plist (:status :result/:error)"
  (let ((start (get-universal-time))
        (task nil))
    (loop
      (setf task (get-task queue task-id))
      (cond
        ((null task)
         (return-from get-task-result (list :status :error :message "Task not found")))
        ((member (task-status task) '(:completed :failed :cancelled))
         (return-from get-task-result
           (list :status (task-status task)
                 :result (task-result task)
                 :error (task-error task))))
        ((and timeout (>= (- (get-universal-time) start) timeout))
         (return-from get-task-result (list :status :timeout))))
      (sleep 0.1)))))

;;; ============================================================================
;;; Worker Management
;;; ============================================================================

(defun process-task (queue task handler-fn)
  "Process a single task.

  Args:
    QUEUE: Task queue instance
    TASK: Task to process
    HANDLER-FN: Task handler function

  Returns:
    T on success"
  (handler-case
      (let ((result (funcall handler-fn task)))
        (setf (task-status task) :completed)
        (setf (task-result task) result)
        (setf (task-finished-at task) (get-universal-time))
        (log-info "Task ~A completed" (task-id task))
        t)
    (error (e)
      (setf (task-error task) (princ-to-string e))
      (setf (task-finished-at task) (get-universal-time))
      (log-error "Task ~A failed: ~A" (task-id task) e)

      ;; Retry if possible
      (if (< (task-retries task) (task-max-retries task))
          (progn
            (incf (task-retries task))
            (setf (task-status task) :pending)
            (log-info "Task ~A scheduled for retry (~A/~A)"
                      (task-id task) (task-retries task) (task-max-retries task)))
          (setf (task-status task) :failed))
      nil)))

(defun start-worker (queue worker-id handler-fn)
  "Start a worker thread.

  Args:
    QUEUE: Task queue instance
    WORKER-ID: Worker identifier
    HANDLER-FN: Task handler function

  Returns:
    T on success"
  (let ((thread (bt:make-thread
                 (lambda ()
                   (log-info "Worker ~A started" worker-id)
                   (loop while (gethash worker-id (task-queue-workers queue))
                         do (let ((task (dequeue queue :timeout 1)))
                              (when task
                                (process-task queue task handler-fn)))
                         do (sleep 0.1)))
                 :name (format nil "task-worker-~A" worker-id))))
    (setf (gethash worker-id (task-queue-workers queue))
          (list :thread thread :started-at (get-universal-time) :tasks-processed 0))
    (log-info "Worker ~A registered" worker-id)
    t))

(defun start-workers (queue count handler-fn)
  "Start multiple workers.

  Args:
    QUEUE: Task queue instance
    COUNT: Number of workers
    HANDLER-FN: Task handler function

  Returns:
    List of worker IDs"
  (loop for i from 1 to count
        collect (let ((worker-id (format nil "worker-~A" i)))
                  (start-worker queue worker-id handler-fn)
                  worker-id)))

(defun stop-worker (queue worker-id)
  "Stop a worker.

  Args:
    QUEUE: Task queue instance
    WORKER-ID: Worker ID

  Returns:
    T on success"
  (remhash worker-id (task-queue-workers queue))
  (log-info "Worker ~A stopped" worker-id)
  t)

(defun stop-all-workers (queue)
  "Stop all workers.

  Args:
    QUEUE: Task queue instance

  Returns:
    Number of workers stopped"
  (let ((count (hash-table-count (task-queue-workers queue))))
    (clrhash (task-queue-workers queue))
    (log-info "All ~A workers stopped" count)
    count))

(defun get-worker-stats (queue)
  "Get worker statistics.

  Args:
    QUEUE: Task queue instance

  Returns:
    Stats plist"
  (let ((workers nil)
        (active 0))
    (maphash (lambda (id info)
               (declare (ignore info))
               (incf active)
               (push id workers))
             (task-queue-workers queue))
    (list :active-workers active
          :workers workers
          :queue-size (queue-size queue))))

;;; ============================================================================
;;; Monitoring
;;; ============================================================================

(defun get-queue-stats (queue)
  "Get queue statistics.

  Args:
    QUEUE: Task queue instance

  Returns:
    Stats plist"
  (let ((pending 0)
        (running 0)
        (completed 0)
        (failed 0)
        (cancelled 0))
    (maphash (lambda (id task)
               (declare (ignore id))
               (ecase (task-status task)
                 (:pending (incf pending))
                 (:running (incf running))
                 (:completed (incf completed))
                 (:failed (incf failed))
                 (:cancelled (incf cancelled))))
             (task-queue-pending queue))
    (list :pending pending
          :running running
          :completed completed
          :failed failed
          :cancelled cancelled
          :total (+ pending running completed failed cancelled))))

(defun list-pending-tasks (queue &optional limit)
  "List pending tasks.

  Args:
    QUEUE: Task queue instance
    LIMIT: Max results (default: 100)

  Returns:
    List of tasks"
  (let ((tasks nil)
        (count 0))
    (maphash (lambda (id task)
               (declare (ignore id))
               (when (and (< count (or limit 100))
                          (eq (task-status task) :pending))
                 (push task tasks)
                 (incf count)))
             (task-queue-pending queue))
    (sort tasks #'< :key #'task-created-at)))

(defun list-failed-tasks (queue &optional limit)
  "List failed tasks.

  Args:
    QUEUE: Task queue instance
    LIMIT: Max results (default: 100)

  Returns:
    List of tasks"
  (let ((tasks nil)
        (count 0))
    (maphash (lambda (id task)
               (declare (ignore id))
               (when (and (< count (or limit 100))
                          (eq (task-status task) :failed))
                 (push task tasks)
                 (incf count)))
             (task-queue-pending queue))
    tasks))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-task-queue-system (&key redis-host redis-port redis-password)
  "Initialize the task queue system.

  Args:
    REDIS-HOST: Redis host (default: localhost)
    REDIS-PORT: Redis port (default: 6379)
    REDIS-PASSWORD: Redis password (optional)

  Returns:
    Task queue instance"
  (let ((queue (make-task-queue
                :name "lisp-claw"
                :redis-host (or redis-host "localhost")
                :redis-port (or redis-port 6379)
                :redis-password redis-password)))
    (log-info "Task queue system initialized")
    queue))
