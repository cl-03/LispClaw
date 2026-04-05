;;; vector-tests.lisp --- Tests for Vector Module
;;;
;;; This file contains tests for the Qdrant vector database module.

(defpackage #:lisp-claw-tests.vector
  (:nicknames #:lc-tests.vector)
  (:use #:cl
        #:prove
        #:lisp-claw.vector.qdrant)
  (:export
   #:test-vector-qdrant))

(in-package #:lisp-claw-tests.vector)

(define-test test-vector-qdrant
  "Test Qdrant vector database module"

  ;; Test client creation
  (let ((client (make-qdrant-client :host "localhost" :port 6333)))
    (ok client "Qdrant client created")
    (is (type-of client) 'qdrant-client "Client type is correct")

    ;; Test client properties
    (is (qdrant-host client) "localhost" "Host is correct")
    (is (qdrant-port client) 6333 "Port is correct")

    ;; Note: Connection test requires running Qdrant server
    ;; (ok (qdrant-ping client) "Can ping Qdrant server")
    )

  ;; Test filter creation
  (let ((filter (qdrant-make-filter
                 :must (list (qdrant-make-match-filter "category" "test"))
                 :must-not (list (qdrant-make-range-filter "age" :lt 18)))))
    (ok filter "Filter created")
    (ok (gethash "must" filter) "Filter has must clause")
    (ok (gethash "must_not" filter) "Filter has must_not clause"))

  ;; Test range filter
  (let ((range-filter (qdrant-make-range-filter "score" :gte 0.5 :lte 1.0)))
    (ok range-filter "Range filter created")
    (ok (getf range-filter :key) "Range filter has key")
    (ok (getf range-filter :range) "Range filter has range"))

  ;; Test match filter
  (let ((match-filter (qdrant-make-match-filter "status" "active")))
    (ok match-filter "Match filter created")
    (is (getf match-filter :key) "status" "Match filter key is correct"))

  ;; Test sample config generation
  (let ((sample (lisp-claw.config.validator:generate-sample-config)))
    (ok sample "Sample config generated for vector testing")
    (ok (getf sample :vector) "Sample has vector section")))
