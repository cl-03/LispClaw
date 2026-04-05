;;; task-queue-tests.lisp --- Tests for Task Queue Module
;;;
;;; This file contains tests for the task queue module.

(defpackage #:lisp-claw-tests.task-queue
  (:nicknames #:lc-tests.task-queue)
  (:use #:cl
        #:prove
        #:lisp-claw.automation.task-queue)
  (:export
   #:test-task-queue))

(in-package #:lisp-claw-tests.task-queue)

(define-test test-task-queue
  "Test task queue module"

  ;; Test task creation
  (let ((task (make-task "test-task"
                         :payload '(:key "value")
                         :priority 5
                         :delay 0
                         :max-retries 5)))
    (ok task "Task created")
    (is (type-of task) 'task "Task type is correct")
    (is (task-name task) "test-task" "Task name is correct")
    (is (task-priority task) 5 "Task priority is correct")
    (is (task-max-retries task) 5 "Task max-retries is correct")
    (is (task-status task) :pending "Task initial status is pending"))

  ;; Test task queue creation
  (let ((queue (make-task-queue :name "test-queue")))
    (ok queue "Task queue created")
    (is (task-queue-name queue) "test-queue" "Queue name is correct")
    (is (eq (hash-table-test (task-queue-workers queue)) 'equal)
        "Workers hash table test is correct"))

  ;; Test enqueue/dequeue
  (let ((queue (make-task-queue :name "test-queue-2"))
        (task (make-task "test-task-2" :priority 10)))
    ;; Enqueue
    (let ((task-id (enqueue queue task)))
      (ok task-id "Task enqueued")
      (is (type-of task-id) 'string "Task ID is string")

      ;; Get task
      (let ((retrieved (get-task queue task-id)))
        (ok retrieved "Task retrieved")
        (is (task-id retrieved) task-id "Task ID matches")))

    ;; Check queue size
    (is (queue-size queue) 1 "Queue size is 1")

    ;; Dequeue
    (let ((dequeued (dequeue queue)))
      (ok dequeued "Task dequeued")
      (is (task-status dequeued) :running "Task status changed to running")))

  ;; Test task cancellation
  (let ((queue (make-task-queue :name "test-queue-3"))
        (task (make-task "test-task-3")))
    (enqueue queue task)
    (let ((task-id (task-id task)))
      ;; Cancel pending task
      (ok (cancel-task queue task-id) "Task cancelled")
      (is (task-status (get-task queue task-id)) :cancelled
          "Task status is cancelled")))

  ;; Test task retry
  (let ((queue (make-task-queue :name "test-queue-4"))
        (task (make-task "test-task-4")))
    (enqueue queue task)
    (dequeue queue) ;; Start the task
    ;; Simulate failure
    (setf (task-status task) :failed)
    ;; Retry
    (ok (retry-task queue (task-id task)) "Task retried")
    (is (task-status (get-task queue (task-id task))) :pending
        "Task status is pending after retry"))

  ;; Test queue stats
  (let ((queue (make-task-queue :name "test-queue-5")))
    ;; Add tasks with different statuses
    (let ((task1 (make-task "task-1"))
          (task2 (make-task "task-2"))
          (task3 (make-task "task-3")))
      (enqueue queue task1)
      (enqueue queue task2)
      (dequeue queue) ;; task2 becomes running
      (setf (task-status task1) :completed)

      (let ((stats (get-queue-stats queue)))
        (ok stats "Queue stats retrieved")
        (is (getf stats :pending) 1 "Pending count correct")
        (is (getf stats :running) 1 "Running count correct")
        (is (getf stats :completed) 1 "Completed count correct"))))

  ;; Test list pending tasks
  (let ((queue (make-task-queue :name "test-queue-6")))
    (dotimes (i 5)
      (enqueue queue (make-task (format nil "task-~A" i))))
    (let ((pending (list-pending-tasks queue)))
      (ok pending "Pending tasks listed")
      (is (length pending) 5 "Pending count correct")))

  ;; Test sample config generation
  (let ((sample (lisp-claw.config.validator:generate-sample-config)))
    (ok sample "Sample config generated for task queue testing")
    (ok (getf sample :redis) "Sample has redis section"))

  ;; Test print object
  (let ((task (make-task "print-test")))
    (ok (with-output-to-string (s) (print task s))
        "Task can be printed"))

  )
