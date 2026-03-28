;;; protocol-tests.lisp --- Protocol Tests for Lisp-Claw
;;;
;;; This file contains tests for the WebSocket protocol.

(in-package #:lisp-claw-tests)

(defsuite test-protocol "Protocol tests")

;;; ============================================================================
;;; Protocol Constants Tests
;;; ============================================================================

(deftest test-protocol-version "Protocol version constant"
  (is (string= lisp-claw.gateway.protocol:+protocol-version+ "1.0")))

(deftest test-frame-types "Frame type constants"
  (is (equal lisp-claw.gateway.protocol:+frame-type-request+ :req))
  (is (equal lisp-claw.gateway.protocol:+frame-type-response+ :res))
  (is (equal lisp-claw.gateway.protocol:+frame-type-event+ :event)))

(deftest test-methods "Request method constants"
  (is (string= lisp-claw.gateway.protocol:+method-connect+ "connect"))
  (is (string= lisp-claw.gateway.protocol:+method-health+ "health"))
  (is (string= lisp-claw.gateway.protocol:+method-agent+ "agent"))
  (is (string= lisp-claw.gateway.protocol:+method-send+ "send")))

(deftest test-events "Event constants"
  (is (string= lisp-claw.gateway.protocol:+event-agent+ "agent"))
  (is (string= lisp-claw.gateway.protocol:+event-chat+ "chat"))
  (is (string= lisp-claw.gateway.protocol:+event-presence+ "presence"))
  (is (string= lisp-claw.gateway.protocol:+event-health+ "health")))

;;; ============================================================================
;;; Connect Frame Tests
;;; ============================================================================

(deftest test-connect-frame "Connect frame creation"
  (let ((frame (lisp-claw.gateway.protocol:make-connect-frame
                '((:type . "client") (:name . "test-client"))
                :auth '((:token . "secret")))))
    (is (typep frame 'lisp-claw.gateway.protocol:request-frame))
    (is (string= (lisp-claw.gateway.protocol:request-frame-method frame) "connect"))
    (is (equal (lisp-claw.gateway.protocol:json-get
                (lisp-claw.gateway.protocol:request-frame-params frame) :type)
               "client"))))

;;; ============================================================================
;;; Health Frame Tests
;;; ============================================================================

(deftest test-health-request "Health request frame"
  (let ((frame (lisp-claw.gateway.protocol:make-request-frame "health")))
    (is (string= (lisp-claw.gateway.protocol:request-frame-method frame) "health"))
    (is (frame-id frame))))

(deftest test-health-response "Health response frame"
  (let ((frame (lisp-claw.gateway.protocol:make-response-frame
                "req-1" t
                :payload '((:status . "ok")
                           (:clients . 5)))))
    (is (equal (lisp-claw.gateway.protocol:response-frame-ok frame) t))
    (is (equal (lisp-claw.gateway.protocol:json-get
                (lisp-claw.gateway.protocol:response-frame-payload frame) :status)
               "ok"))))

;;; ============================================================================
;;; Error Handling Tests
;;; ============================================================================

(deftest test-invalid-frame-error "Invalid frame error"
  (let ((json '((:type . "invalid"))))
    (signals lisp-claw.gateway.protocol:invalid-frame-error
      (lisp-claw.gateway.protocol:parse-frame json))))

(deftest test-missing-method-error "Missing method error"
  (let ((json '((:type . "req") (:id . "1"))))
    (signals lisp-claw.gateway.protocol:protocol-error
      (lisp-claw.gateway.protocol:parse-frame json))))

;;; ============================================================================
;;; Frame Validation Tests
;;; ============================================================================

(deftest test-frame-validation "Frame validation"
  (let ((frame (lisp-claw.gateway.protocol:make-request-frame "health")))
    (ok (lisp-claw.gateway.protocol:validate-frame frame))))

(deftest test-frame-predicate "Frame type predicate"
  (let ((frame (lisp-claw.gateway.protocol:make-request-frame "test")))
    (ok (lisp-claw.gateway.protocol:frame-p frame)))
  (ok (not (lisp-claw.gateway.protocol:frame-p "not a frame"))))

;;; ============================================================================
;;; ID Generation Tests
;;; ============================================================================

(deftest test-id-generation "Frame ID generation"
  (let ((id1 (lisp-claw.gateway.protocol:generate-frame-id))
        (id2 (lisp-claw.gateway.protocol:generate-frame-id)))
    ;; IDs should be unique
    (ok (not (string= id1 id2)))
    ;; IDs should be non-empty strings
    (ok (and (stringp id1) (> (length id1) 0)))
    (ok (and (stringp id2) (> (length id2) 0)))))

;;; ============================================================================
;;; Serialization Round-trip Tests
;;; ============================================================================

(deftest test-request-roundtrip "Request serialization round-trip"
  (let* ((original (lisp-claw.gateway.protocol:make-request-frame
                    "test" :id "test-123" :params '((:key . "value"))))
         (json (lisp-claw.gateway.protocol:frame-to-json original))
         (restored (lisp-claw.gateway.protocol:parse-frame json)))
    (is (typep restored 'lisp-claw.gateway.protocol:request-frame))
    (is (string= (lisp-claw.gateway.protocol:request-frame-method restored) "test"))
    (is (string= (lisp-claw.gateway.protocol:frame-id restored) "test-123"))))

(deftest test-response-roundtrip "Response serialization round-trip"
  (let* ((original (lisp-claw.gateway.protocol:make-response-frame
                    "req-1" t :payload '((:result . "success"))))
         (json (lisp-claw.gateway.protocol:frame-to-json original))
         (restored (lisp-claw.gateway.protocol:parse-frame json)))
    (is (typep restored 'lisp-claw.gateway.protocol:response-frame))
    (is (equal (lisp-claw.gateway.protocol:response-frame-ok restored) t))))

(deftest test-event-roundtrip "Event serialization round-trip"
  (let* ((original (lisp-claw.gateway.protocol:make-event-frame
                    "test.event" :payload '((:data . 123)) :seq 42))
         (json (lisp-claw.gateway.protocol:frame-to-json original))
         (restored (lisp-claw.gateway.protocol:parse-frame json)))
    (is (typep restored 'lisp-claw.gateway.protocol:event-frame))
    (is (string= (lisp-claw.gateway.protocol:event-frame-event restored) "test.event"))
    (is (equal (lisp-claw.gateway.protocol:event-frame-seq restored) 42))))

;;; ============================================================================
;;; Run Protocol Tests
;;; ============================================================================

(defun run-protocol-tests ()
  "Run all protocol tests.

  Returns:
    Test results"
  (prove:run #'test-protocol))
