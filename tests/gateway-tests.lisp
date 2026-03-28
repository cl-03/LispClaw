;;; gateway-tests.lisp --- Gateway Tests for Lisp-Claw
;;;
;;; This file contains tests for the Lisp-Claw gateway.

(in-package #:lisp-claw-tests)

(defsuite test-gateway "Gateway tests")

;;; ============================================================================
;;; JSON Utilities Tests
;;; ============================================================================

(deftest test-json-parse-basic "Basic JSON parsing"
  (is (equal (parse-json "{\"name\": \"test\"}")
             '((:name . "test"))))
  (is (equal (parse-json "{\"value\": 42}")
             '((:value . 42))))
  (is (equal (parse-json "{\"enabled\": true}")
             '((:enabled . t)))))

(deftest test-json-parse-array "JSON array parsing"
  (is (equal (parse-json "[1, 2, 3]")
             #(1 2 3))))

(deftest test-json-stringify "JSON serialization"
  (is (string= (stringify-json '((:name . "test") (:value . 42)))
               "{\"name\":\"test\",\"value\":42}")))

(deftest test-json-get "JSON accessor"
  (let ((json '((:name . "test") (:nested . ((:value . 42))))))
    (is (string= (json-get json :name) "test"))
    (is (equal (json-get json :nested) '((:value . 42))))))

(deftest test-json-get* "Nested JSON accessor"
  (let ((json '((:data . ((:user . ((:name . "John")))))))
    (is (string= (json-get* json :data :user :name) "John"))))

;;; ============================================================================
;;; String Utilities Tests
;;; ============================================================================

(deftest test-trim "String trimming"
  (is (string= (trim "  hello  ") "hello"))
  (is (string= (trim "\t\nhello\n\t") "hello")))

(deftest test-empty-string-p "Empty string check"
  (ok (empty-string-p ""))
  (ok (empty-string-p "   "))
  (ok (empty-string-p nil))
  (ok (not (empty-string-p "hello"))))

(deftest test-truncate-string "String truncation"
  (is (string= (truncate-string "hello world" 5) "he..."))
  (is (string= (truncate-string "hi" 10) "hi")))

;;; ============================================================================
;;; Helper Tests
;;; ============================================================================

(deftest test-ensure-list "Ensure list"
  (is (equal (ensure-list 1) '(1)))
  (is (equal (ensure-list '(1 2)) '(1 2))))

(deftest test-safe-subseq "Safe subsequence"
  (is (equal (safe-subseq '(1 2 3 4 5) 1 3) '(2 3)))
  (is (equal (safe-subseq '(1 2 3) 10) nil)))

;;; ============================================================================
;;; Protocol Tests
;;; ============================================================================

(deftest test-frame-creation "Frame creation"
  (let ((frame (make-request-frame "health" :id "test-1")))
    (is (equal (frame-type frame) :req))
    (is (string= (request-frame-method frame) "health"))
    (is (string= (frame-id frame) "test-1"))))

(deftest test-response-frame "Response frame"
  (let ((frame (make-response-frame "test-1" t :payload '((:status . "ok")))))
    (is (equal (frame-type frame) :res))
    (is (equal (response-frame-ok frame) t))
    (is (equal (response-frame-payload frame) '((:status . "ok"))))))

(deftest test-event-frame "Event frame"
  (let ((frame (make-event-frame "health"
                                 :payload '((:status . "ok"))
                                 :seq 1)))
    (is (equal (frame-type frame) :event))
    (is (string= (event-frame-event frame) "health"))
    (is (equal (event-frame-seq frame) 1))))

(deftest test-frame-to-json "Frame serialization"
  (let ((frame (make-request-frame "health" :id "test-1")))
    (let ((json (frame-to-json frame)))
      (is (string= (json-get json :type) "req"))
      (is (string= (json-get json :method) "health")))))

(deftest test-parse-frame "Frame parsing"
  (let ((json '((:type . "req")
                (:id . "test-1")
                (:method . "health"))))
    (let ((frame (parse-frame json)))
      (is (typep frame 'request-frame))
      (is (string= (request-frame-method frame) "health")))))

;;; ============================================================================
;;; Config Tests
;;; ============================================================================

(deftest test-config-merge "Config merging"
  (let ((default '((:gateway . ((:port . 18789)))))
        (user '((:gateway . ((:bind . "0.0.0.0"))))))
    (let ((merged (merge-configs default user)))
      (is (equal (json-get* merged :gateway :port) 18789))
      (is (string= (json-get* merged :gateway :bind) "0.0.0.0")))))

(deftest test-config-get-set "Config get/set"
  (let ((config '((:gateway . ((:port . 18789)))))
    (setf *current-config* config)
    (is (equal (get-config-value :gateway :port) 18789))))

;;; ============================================================================
;;; Run All Tests
;;; ============================================================================

(defun run-all-tests ()
  "Run all Lisp-Claw tests.

  Returns:
    Test results"
  (prove:run #'test-gateway))
