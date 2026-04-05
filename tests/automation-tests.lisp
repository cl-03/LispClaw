;;; automation-tests.lisp --- Automation Tests for Lisp-Claw
;;;
;;; This file contains tests for the Lisp-Claw automation system.

(defpackage #:lisp-claw-tests.automation
  (:nicknames #:lc-tests.automation)
  (:use #:cl
        #:prove
        #:lisp-claw.automation.webhook
        #:lisp-claw.automation.cron
        #:lisp-claw.automation.task-queue
        #:lisp-claw.automation.event-bus))

(in-package #:lisp-claw-tests.automation)

(defsuite test-automation "Automation tests")

;;; ============================================================================
;;; Webhook Tests
;;; ============================================================================

(deftest test-webhook-creation "Webhook creation"
  (let ((handler (lambda (payload) (declare (ignore payload)) t))
        (webhook (make-webhook "test-1" "/hooks/test" handler)))
    (ok webhook)
    (is (string= (webhook-id webhook) "test-1"))
    (is (string= (webhook-path webhook) "/hooks/test"))
    (is (eq (webhook-handler webhook) handler))
    (is (zerop (webhook-call-count webhook)))))

(deftest test-webhook-with-secret "Webhook with secret"
  (let ((webhook (make-webhook "test-2" "/hooks/secure" (lambda (p) p) :secret "my-secret")))
    (ok webhook)
    (is (string= (webhook-secret webhook) "my-secret"))))

(deftest test-webhook-register-unregister "Webhook register/unregister"
  ;; Clear existing webhooks
  (setf *webhooks* (make-hash-table :test 'equal))

  (let ((webhook (make-webhook "test-3" "/hooks/test3" (lambda (p) p))))
    ;; Register
    (ok (register-webhook webhook))

    ;; Verify registration
    (is (not (null (find-webhook-by-id "test-3"))))

    ;; Unregister
    (ok (unregister-webhook "test-3"))
    (ok (null (find-webhook-by-id "test-3")))))

(deftest test-webhook-url-generation "Webhook URL generation"
  (let ((url (generate-webhook-url "test-webhook" :port 18792 :host "127.0.0.1")))
    (is (string= url "http://127.0.0.1:18792/webhooks/test-webhook"))))

(deftest test-find-webhook-by-path "Find webhook by path"
  (setf *webhooks* (make-hash-table :test 'equal))

  (let ((webhook (make-webhook "test-4" "/hooks/test4" (lambda (p) p))))
    (register-webhook webhook)

    (is (eq (find-webhook-by-path "/hooks/test4") webhook))))

(deftest test-list-webhooks "List webhooks"
  (setf *webhooks* (make-hash-table :test 'equal))

  ;; Initially empty
  (is (zerop (length (list-webhooks))))

  ;; Add webhooks
  (register-webhook (make-webhook "list-1" "/hooks/list1" (lambda (p) p)))
  (register-webhook (make-webhook "list-2" "/hooks/list2" (lambda (p) p)))

  (is (= (length (list-webhooks)) 2)))

;;; ============================================================================
;;; Cron Tests
;;; ============================================================================

(deftest test-cron-job-creation "Cron job creation"
  (let ((job (make-cron-job "test-job" "0 * * * *" (lambda () t))))
    (ok job)
    (is (string= (cron-job-name job) "test-job"))
    (is (string= (cron-job-schedule job) "0 * * * *"))))

(deftest test-cron-parse-schedule "Cron schedule parsing"
  (let ((schedule (parse-cron-schedule "0 12 * * *")))
    (ok schedule)
    (is (= (getf schedule :minute) 0))
    (is (= (getf schedule :hour) 12))))

(deftest test-cron-register "Cron job registration"
  (setf *cron-jobs* (make-hash-table :test 'equal))

  (let ((job (make-cron-job "reg-job" "0 * * * *" (lambda () t))))
    (ok (register-cron-job job))
    (is (not (null (get-cron-job "reg-job")))))

  ;; Cleanup
  (unregister-cron-job "reg-job"))

;;; ============================================================================
;;; Task Queue Tests
;;; ============================================================================

(deftest test-task-creation "Task creation"
  (let ((task (make-task "test-task" :payload '(:key "value") :priority 5)))
    (ok task)
    (is (string= (task-name task) "test-task"))
    (is (= (task-priority task) 5))
    (is (eq (task-status task) :pending))))

(deftest test-task-queue-creation "Task queue creation"
  (let ((queue (make-task-queue :name "test-queue")))
    (ok queue)
    (is (string= (task-queue-name queue) "test-queue"))))

(deftest test-task-enqueue "Task enqueue"
  (let ((queue (make-task-queue :name "test-queue-2"))
        (task (make-task "test-task-2")))
    (let ((task-id (enqueue queue task)))
      (ok task-id)
      (is (= (queue-size queue) 1)))))

(deftest test-task-dequeue "Task dequeue"
  (let ((queue (make-task-queue :name "test-queue-3"))
        (task (make-task "test-task-3" :priority 10)))
    (enqueue queue task)
    (let ((dequeued (dequeue queue)))
      (ok dequeued)
      (is (eq (task-status dequeued) :running)))))

;;; ============================================================================
;;; Event Bus Tests
;;; ============================================================================

(deftest test-event-creation "Event creation"
  (let ((event (make-event "test.event" :type :info :payload '(:data "test"))))
    (ok event)
    (is (string= (event-topic event) "test.event"))
    (is (eq (event-type event) :info))))

(deftest test-event-bus-creation "Event bus creation"
  (let ((bus (make-event-bus :name "test-bus")))
    (ok bus)
    (is (string= (event-bus-name bus) "test-bus"))))

(deftest test-topic-match "Topic pattern matching"
  ;; Exact match
  (ok (topic-match-p "user.login" "user.login"))
  ;; Single wildcard
  (ok (topic-match-p "user.*" "user.login"))
  (ok (not (topic-match-p "user.*" "user.login.success")))
  ;; Multi wildcard
  (ok (topic-match-p "user.**" "user.login"))
  (ok (topic-match-p "user.**" "user.login.success")))

(deftest test-event-publish-subscribe "Event publish/subscribe"
  (let ((bus (make-event-bus :name "test-bus-2"))
        (received nil))
    (subscribe bus "test.*" (lambda (e) (push e received)))
    (publish bus (make-event "test.event"))
    (is (= (length received) 1))))

;;; ============================================================================
;;; Run Automation Tests
;;; ============================================================================

(defun run-automation-tests ()
  "Run all automation tests.

  Returns:
    Test results"
  (prove:run #'test-automation))
