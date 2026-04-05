;;; advanced/memory.lisp --- Memory Management System
;;;
;;; This file provides memory management for conversation history and context retention.

(defpackage #:lisp-claw.advanced.memory
  (:nicknames #:lc.adv.memory)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging)
  (:export
   ;; Memory class
   #:memory
   #:make-memory
   #:memory-id
   #:memory-type
   #:memory-content
   #:memory-timestamp
   #:memory-priority
   #:memory-tags
   #:memory-access-count
   ;; Memory operations
   #:store-memory
   #:retrieve-memory
   #:search-memories
   #:forget-memory
   #:list-memories
   #:get-memory-stats
   ;; Context management
   #:*memory-store*
   #:add-to-context
   #:get-context
   #:clear-context
   #:context-length
   #:*max-context-length*
   ;; Initialization
   #:initialize-memory-system))

(in-package #:lisp-claw.advanced.memory)

;;; ============================================================================
;;; Memory Types
;;; ============================================================================

(define-condition memory-error (simple-error)
  ((memory-id :initarg :memory-id :reader memory-error-memory-id))
  (:report (lambda (condition stream)
             (format stream "Memory error for ~A: ~A"
                     (memory-error-memory-id condition)
                     (simple-condition-message condition)))))

;;; ============================================================================
;;; Memory Class
;;; ============================================================================

(defclass memory ()
  ((id :initarg :id
       :initform (format nil "~A-~A" (get-universal-time) (random 1000000))
       :reader memory-id
       :documentation "Unique memory identifier")
   (type :initarg :type
         :accessor memory-type
         :documentation "Type of memory: short-term, long-term, episodic, semantic")
   (content :initarg :content
            :accessor memory-content
            :documentation "Memory content")
   (timestamp :initarg :timestamp
              :initform (get-universal-time)
              :accessor memory-timestamp
              :documentation "When memory was created")
   (priority :initarg :priority
             :initform 0.5
             :accessor memory-priority
             :documentation "Priority score 0.0-1.0")
   (tags :initarg :tags
         :initform nil
         :accessor memory-tags
         :documentation "List of tags for categorization")
   (access-count :initform 0
                 :accessor memory-access-count
                 :documentation "Number of times accessed"))
  (:documentation "Represents a single memory unit"))

(defun make-memory (type content &key (priority 0.5) tags)
  "Create a new memory.

  Args:
    TYPE: Memory type (short-term, long-term, episodic, semantic)
    CONTENT: Memory content
    PRIORITY: Priority score (default 0.5)
    TAGS: List of tags

  Returns:
    New memory instance"
  (make-instance 'memory
                 :type type
                 :content content
                 :priority priority
                 :tags tags))

;;; ============================================================================
;;; Memory Store
;;; ============================================================================

(defvar *memory-store* (make-hash-table :test 'equal)
  "Hash table storing all memories.")

(defvar *context-stack* (make-array 100 :adjustable t :fill-pointer 0)
  "Stack of recent context memories.")

(defvar *max-context-length* 50
  "Maximum number of context items to retain.")

(defun store-memory (memory)
  "Store a memory in the memory store.

  Args:
    MEMORY: Memory instance

  Returns:
    Memory ID on success"
  (let ((id (if (stringp (memory-id memory))
                (memory-id memory)
                (format nil "~A" (memory-id memory)))))
    (setf (gethash id *memory-store*) memory)
    (log-debug "Stored memory ~A of type ~A" id (memory-type memory))
    id))

(defun retrieve-memory (memory-id)
  "Retrieve a memory by ID.

  Args:
    MEMORY-ID: Memory identifier

  Returns:
    Memory instance or NIL"
  (let ((memory (gethash memory-id *memory-store*)))
    (when memory
      (incf (memory-access-count memory)))
    memory))

(defun forget-memory (memory-id)
  "Delete a memory.

  Args:
    MEMORY-ID: Memory identifier

  Returns:
    T if memory was deleted"
  (when (gethash memory-id *memory-store*)
    (remhash memory-id *memory-store*)
    (log-debug "Forgot memory ~A" memory-id)
    t))

(defun search-memories (&key type tags priority-min limit)
  "Search memories by criteria.

  Args:
    TYPE: Optional memory type filter
    TAGS: Optional list of tags to match
    PRIORITY-MIN: Minimum priority threshold
    LIMIT: Maximum number of results

  Returns:
    List of matching memories"
  (let ((results nil))
    (maphash (lambda (id memory)
               (declare (ignore id))
               (when (and (or (null type) (eq (memory-type memory) type))
                          (or (null tags)
                              (some (lambda (tag) (member tag (memory-tags memory) :test 'string=)) tags))
                          (or (null priority-min) (>= (memory-priority memory) priority-min)))
                 (push memory results)))
             *memory-store*)
    ;; Sort by priority and timestamp
    (setf results (sort results #'> :key (lambda (m)
                                           (+ (* 0.7 (memory-priority m))
                                              (* 0.3 (/ (memory-access-count m)
                                                        (max 1 (- (get-universal-time) (memory-timestamp m)))))))))
    (when limit
      (setf results (subseq results 0 (min limit (length results)))))
    results))

(defun list-memories (&optional type)
  "List all memories, optionally filtered by type.

  Args:
    TYPE: Optional memory type filter

  Returns:
    List of memories"
  (let ((results nil))
    (maphash (lambda (id memory)
               (declare (ignore id))
               (when (or (null type) (eq (memory-type memory) type))
                 (push memory results)))
             *memory-store*)
    results))

(defun get-memory-stats ()
  "Get memory statistics.

  Returns:
    Stats plist"
  (let ((short-term 0)
        (long-term 0)
        (episodic 0)
        (semantic 0)
        (total-accesses 0))
    (maphash (lambda (id memory)
               (declare (ignore id))
               (case (memory-type memory)
                 (:short-term (incf short-term))
                 (:long-term (incf long-term))
                 (:episodic (incf episodic))
                 (:semantic (incf semantic)))
               (incf total-accesses (memory-access-count memory)))
             *memory-store*)
    `(:total ,(hash-table-count *memory-store*)
      :short-term ,short-term
      :long-term ,long-term
      :episodic ,episodic
      :semantic ,semantic
      :total-accesses ,total-accesses)))

;;; ============================================================================
;;; Context Management
;;; ============================================================================

(defun add-to-context (content &key (type :short-term) priority tags)
  "Add content to context stack.

  Args:
    CONTENT: Content to add
    TYPE: Memory type (default :short-term)
    PRIORITY: Priority score
    TAGS: List of tags

  Returns:
    Memory ID"
  (let ((memory (make-memory type content :priority (or priority 0.5) :tags tags))
        (id (store-memory memory)))
    ;; Add to context stack
    (vector-push-extend memory *context-stack*)
    ;; Trim if needed
    (when (> (length *context-stack*) *max-context-length*)
      (adjust-array *context-stack* *max-context-length* :fill-pointer *max-context-length*))
    id))

(defun get-context (&optional limit)
  "Get recent context.

  Args:
    LIMIT: Maximum number of context items (default: all)

  Returns:
    List of context memories"
  (let* ((len (length *context-stack*))
         (start (if limit (max 0 (- len limit)) 0)))
    (coerce (subseq *context-stack* start len) 'list)))

(defun clear-context ()
  "Clear the context stack.

  Returns:
    T"
  (setf (fill-pointer *context-stack*) 0)
  (log-info "Context cleared")
  t)

(defun context-length ()
  "Get current context length.

  Returns:
    Number of items in context"
  (length *context-stack*))

;;; ============================================================================
;;; Memory Consolidation
;;; ============================================================================

(defun consolidate-short-term-to-long-term (&key (age-threshold 3600) (priority-threshold 0.7))
  "Consolidate short-term memories to long-term.

  Args:
    AGE-THRESHOLD: Age in seconds to consider for consolidation
    PRIORITY-THRESHOLD: Minimum priority for consolidation

  Returns:
    Number of memories consolidated"
  (let ((count 0)
        (now (get-universal-time)))
    (maphash (lambda (id memory)
               (when (and (eq (memory-type memory) :short-term)
                          (>= (memory-priority memory) priority-threshold)
                          (>= (- now (memory-timestamp memory)) age-threshold))
                 ;; Convert to long-term
                 (setf (memory-type memory) :long-term)
                 (incf count)))
             *memory-store*)
    (when (plusp count)
      (log-info "Consolidated ~A short-term memories to long-term" count))
    count))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-memory-system ()
  "Initialize the memory system.

  Returns:
    T"
  (log-info "Memory system initialized")
  t)
