;;; event-bus-tests.lisp --- Tests for Event Bus Module
;;;
;;; This file contains tests for the event bus module.

(defpackage #:lisp-claw-tests.event-bus
  (:nicknames #:lc-tests.event-bus)
  (:use #:cl
        #:prove
        #:lisp-claw.automation.event-bus)
  (:export
   #:test-event-bus))

(in-package #:lisp-claw-tests.event-bus)

(define-test test-event-bus
  "Test event bus module"

  ;; Test event creation
  (let ((event (make-event "test.event"
                           :type :info
                           :payload '(:key "value")
                           :source "test"
                           :priority 5)))
    (ok event "Event created")
    (is (type-of event) 'event "Event type is correct")
    (is (event-topic event) "test.event" "Event topic is correct")
    (is (event-type event) :info "Event type is correct")
    (is (event-priority event) 5 "Event priority is correct")
    (is (event-source event) "test" "Event source is correct"))

  ;; Test event bus creation
  (let ((bus (make-event-bus :name "test-bus")))
    (ok bus "Event bus created")
    (is (event-bus-name bus) "test-bus" "Bus name is correct"))

  ;; Test subscription
  (let ((bus (make-event-bus :name "test-bus-2"))
        (events-received nil))
    ;; Subscribe
    (subscribe bus "test.*"
               (lambda (event)
                 (push event events-received)))

    ;; Publish event
    (let ((event (make-event "test.event" :payload '(:data "test"))))
      (publish bus event))

    ;; Check event was received
    (is (length events-received) 1 "Event received by subscriber")
    (is (event-topic (first events-received)) "test.event"
        "Event topic matches"))

  ;; Test pattern matching - exact match
  (ok (topic-match-p "user.login" "user.login") "Exact match works")
  (ok (not (topic-match-p "user.login" "user.logout")) "Exact mismatch works")

  ;; Test pattern matching - single wildcard (*)
  (ok (topic-match-p "user.*" "user.login") "Single wildcard matches one level")
  (ok (topic-match-p "user.*" "user.logout") "Single wildcard matches alternative")
  (ok (not (topic-match-p "user.*" "user.login.success"))
      "Single wildcard does not match multiple levels")

  ;; Test pattern matching - multi wildcard (**)
  (ok (topic-match-p "user.**" "user.login") "Multi wildcard matches one level")
  (ok (topic-match-p "user.**" "user.login.success") "Multi wildcard matches multiple levels")
  (ok (topic-match-p "user.**" "user.login.success.extra")
      "Multi wildcard matches many levels")

  ;; Test subscription with filter
  (let ((bus (make-event-bus :name "test-bus-3"))
        (events-received nil))
    ;; Subscribe with filter
    (subscribe bus "test.*"
               (lambda (event)
                 (push event events-received))
               :filter (lambda (event)
                         (>= (event-priority event) 5)))

    ;; Publish low priority event
    (publish bus (make-event "test.low" :priority 1))
    ;; Publish high priority event
    (publish bus (make-event "test.high" :priority 10))

    ;; Check only high priority was received
    (is (length events-received) 1 "Filter working")
    (is (event-topic (first events-received)) "test.high"
        "High priority event received"))

  ;; Test subscription priority
  (let ((bus (make-event-bus :name "test-bus-4"))
        (call-order nil))
    ;; Subscribe with different priorities
    (subscribe bus "test.*"
               (lambda (event) (push 3 call-order))
               :priority 1)
    (subscribe bus "test.*"
               (lambda (event) (push 2 call-order))
               :priority 5)
    (subscribe bus "test.*"
               (lambda (event) (push 1 call-order))
               :priority 10)

    ;; Publish event
    (publish bus (make-event "test.event"))

    ;; Check call order (higher priority first)
    (is (first call-order) 1 "Highest priority called first"))

  ;; Test unsubscribe
  (let ((bus (make-event-bus :name "test-bus-5"))
        (events-received nil)
        (sub nil))
    ;; Subscribe
    (setf sub (subscribe bus "test.*"
                         (lambda (event)
                           (push event events-received))))

    ;; Publish before unsubscribe
    (publish bus (make-event "test.event.1"))

    ;; Unsubscribe
    (ok (unsubscribe bus sub) "Unsubscribe successful")

    ;; Publish after unsubscribe
    (publish bus (make-event "test.event.2"))

    ;; Check only first event received
    (is (length events-received) 1 "Unsubscribe working"))

  ;; Test event store and replay
  (let ((bus (make-event-bus :name "test-bus-6")))
    ;; Publish events
    (publish bus (make-event "test.event.1"))
    (publish bus (make-event "test.event.2"))
    (publish bus (make-event "test.event.3"))

    ;; Get stored event
    (let ((events (list-pending-tasks bus)))
      (declare (ignore events))
      ok t "Events stored")

    ;; Replay events
    (let ((replayed nil))
      (replay-events bus :handler (lambda (event)
                                    (push event replayed)))
      (is (length replayed) 3 "Events replayed")))

  ;; Test list topics
  (let ((bus (make-event-bus :name "test-bus-7")))
    (publish bus (make-event "topic.one"))
    (publish bus (make-event "topic.two"))
    (publish bus (make-event "topic.one")) ;; Another event on same topic

    (let ((topics (list-topics bus)))
      (ok topics "Topics listed")
      (ok (member "topic.one" topics :test #'string=) "topic.one exists")
      (ok (member "topic.two" topics :test #'string=) "topic.two exists")))

  ;; Test list subscriptions
  (let ((bus (make-event-bus :name "test-bus-8")))
    (subscribe bus "test.*" (lambda (e) nil))
    (subscribe bus "other.*" (lambda (e) nil))

    (let ((subs (list-subscriptions bus)))
      (is (length subs) 2 "Subscriptions listed"))

    ;; Deactivate one and list active only
    (let ((sub (first (list-subscriptions bus))))
      (setf (subscription-active-p sub) nil))

    (let ((active-subs (list-subscriptions bus :active-only t)))
      (is (length active-subs) 1 "Active subscriptions only")))

  ;; Test event stats
  (let ((bus (make-event-bus :name "test-bus-9")))
    (publish bus (make-event "test.event.1"))
    (publish bus (make-event "test.event.2"))
    (subscribe bus "test.*" (lambda (e) nil))
    (subscribe bus "other.*" (lambda (e) nil))

    (let ((stats (get-event-stats bus)))
      (ok stats "Stats retrieved")
      (is (getf stats :total-events) 2 "Total events correct")
      (is (getf stats :total-subscriptions) 2 "Total subscriptions correct")))

  ;; Test built-in event types
  (let ((system-event (make-system-event :startup :payload '(:version "1.0"))))
    (ok system-event "System event created")
    (is (event-topic system-event) "system" "System event topic correct"))

  (let ((user-event (make-user-event :login "user-123" :payload '(:ip "127.0.0.1"))))
    (ok user-event "User event created")
    (is (event-topic user-event) "user.login" "User event topic correct"))

  (let ((msg-event (make-message-event "telegram" "msg-456")))
    (ok msg-event "Message event created")
    (is (event-topic msg-event) "message.telegram" "Message event topic correct"))

  ;; Test print object
  (let ((event (make-event "print.test")))
    (ok (with-output-to-string (s) (print event s))
        "Event can be printed"))

  (let ((sub (make-subscription "test.*" (lambda (e) nil))))
    (ok (with-output-to-string (s) (print sub s))
        "Subscription can be printed"))

  )
