;;; advanced-tests.lisp --- Advanced Features Tests
;;;
;;; This file contains tests for advanced features (memory, cache).

(defpackage #:lisp-claw-tests.advanced
  (:nicknames #:lc-tests.advanced)
  (:use #:cl
        #:prove
        #:lisp-claw.advanced.memory
        #:lisp-claw.advanced.cache
        #:lisp-claw.security.rate-limit)
  (:export #:run-advanced-tests))

(in-package #:lisp-claw-tests.advanced)

;;; ============================================================================
;;; Run Advanced Tests
;;; ============================================================================

(defun run-advanced-tests ()
  "Run all advanced features tests.

  Returns:
    Test results"
  (prove:run
   (subtest "Memory creation"
     (let ((memory (make-memory :short-term "Test content" :priority 0.8 :tags '(:test))))
       (ok memory "Memory created")
       (is (memory-type memory) :short-term "Type is short-term")
       (is (memory-content memory) "Test content" "Content matches")
       (is (memory-priority memory) 0.8 "Priority matches")
       (is (memory-tags memory) '(:test) "Tags match")))

   (subtest "Memory store and retrieve"
     (setf *memory-store* (make-hash-table :test 'equal))
     (let* ((memory (make-memory :long-term "Stored content"))
            (id (store-memory memory)))
       (ok id "Store returns ID")
       (let ((retrieved (retrieve-memory id)))
         (ok retrieved "Retrieved not nil")
         (is (memory-content retrieved) "Stored content" "Content matches"))))

   (subtest "Memory search"
     (setf *memory-store* (make-hash-table :test 'equal))
     (store-memory (make-memory :short-term "Content 1" :priority 0.9 :tags '(:important)))
     (store-memory (make-memory :long-term "Content 2" :priority 0.5 :tags '(:normal)))
     (store-memory (make-memory :short-term "Content 3" :priority 0.7 :tags '(:important)))
     (let ((results (search-memories :type :short-term)))
       (is (length results) 2 "Found 2 short-term memories")))

   (subtest "Context management"
     (setf *memory-store* (make-hash-table :test 'equal))
     (setf *context-stack* (make-array 100 :adjustable t :fill-pointer 0))
     (add-to-context "Context 1")
     (add-to-context "Context 2")
     (add-to-context "Context 3")
     (is (context-length) 3 "Context length is 3")
     (clear-context)
     (is (context-length) 0 "Context cleared"))

   (subtest "Cache entry creation"
     (let ((entry (make-cache-entry "key1" "value1" :ttl 3600)))
       (ok entry "Entry created")
       (is (cache-entry-key entry) "key1" "Key matches")
       (is (cache-entry-value entry) "value1" "Value matches")))

   (subtest "Cache basic operations"
     (setf *cache-store* (make-hash-table :test 'equal))
     (ok (cache-put "test-key" "test-value" :ttl 3600) "Put returns T")
     (let ((value (cache-get "test-key")))
       (is value "test-value" "Get returns value"))
     (ok (cache-delete "test-key") "Delete returns T")
     (ok (null (cache-get "test-key")) "Key deleted"))

   (subtest "Cache stats"
     (setf *cache-store* (make-hash-table :test 'equal))
     (let ((stats (cache-stats)))
       (is (getf stats :total) 0 "Initial total is 0"))
     (cache-put "key1" "value1")
     (cache-put "key2" "value2")
     (let ((stats (cache-stats)))
       (is (getf stats :total) 2 "Total is 2")))

   (subtest "Response cache"
     (setf *response-cache* (make-hash-table :test 'equal))
     (let* ((model "gpt-4")
            (messages '((:role "user" :content "Hello")))
            (response "Hello! How can I help?"))
       (cache-response model messages response)
       (let ((cached (get-cached-response model messages)))
         (ok cached "Cached response exists"))))

   (subtest "TTL cache"
     (let ((cache (make-ttl-cache :default-ttl 3600 :max-size 100)))
       (ok (ttl-cache-put cache "key1" "value1") "Put returns T")
       (let ((value (ttl-cache-get cache "key1")))
         (is value "value1" "Get returns value")))))
  t)
