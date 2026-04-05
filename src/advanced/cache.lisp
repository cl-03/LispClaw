;;; advanced/cache.lisp --- Response Cache System
;;;
;;; This file provides response caching for AI interactions.

(defpackage #:lisp-claw.advanced.cache
  (:nicknames #:lc.adv.cache)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging)
  (:export
   ;; Cache entry
   #:cache-entry
   #:make-cache-entry
   #:cache-entry-key
   #:cache-entry-value
   #:cache-entry-created
   #:cache-entry-expires
   #:cache-entry-access-count
   ;; Cache operations
   #:cache-get
   #:cache-put
   #:cache-delete
   #:cache-clear
   #:cache-stats
   #:cache-keys
   ;; Response cache
   #:response-cache
   #:cache-response
   #:get-cached-response
   #:invalidate-response-cache
   #:compute-response-cache-key
   ;; TTL cache
   #:ttl-cache
   #:make-ttl-cache
   #:ttl-cache-get
   #:ttl-cache-put
   #:ttl-cache-cleanup
   ;; Initialization
   #:initialize-cache-system))

(in-package #:lisp-claw.advanced.cache)

;;; ============================================================================
;;; Cache Entry Class
;;; ============================================================================

(defclass cache-entry ()
  ((key :initarg :key
        :reader cache-entry-key
        :documentation "Cache entry key")
   (value :initarg :value
          :accessor cache-entry-value
          :documentation "Cached value")
   (created :initarg :created
            :initform (get-universal-time)
            :reader cache-entry-created
            :documentation "Creation timestamp")
   (expires :initarg :expires
            :initform nil
            :accessor cache-entry-expires
            :documentation "Expiration timestamp or NIL for no expiry")
   (access-count :initform 0
                 :accessor cache-entry-access-count
                 :documentation "Number of accesses"))
  (:documentation "A single cache entry"))

(defun make-cache-entry (key value &key ttl)
  "Create a new cache entry.

  Args:
    KEY: Cache key
    VALUE: Value to cache
    TTL: Time-to-live in seconds (optional)

  Returns:
    New cache-entry instance"
  (make-instance 'cache-entry
                 :key key
                 :value value
                 :expires (when ttl (+ (get-universal-time) ttl))))

;;; ============================================================================
;;; Basic Cache Operations
;;; ============================================================================

(defvar *cache-store* (make-hash-table :test 'equal)
  "Global cache store.")

(defun cache-get (key)
  "Get a value from cache.

  Args:
    KEY: Cache key

  Returns:
    Values or NIL if not found/expired"
  (let ((entry (gethash key *cache-store*)))
    (when entry
      (if (and (cache-entry-expires entry)
               (> (get-universal-time) (cache-entry-expires entry)))
          ;; Expired
          (progn
            (remhash key *cache-store*)
            nil)
          ;; Valid
          (progn
            (incf (cache-entry-access-count entry))
            (cache-entry-value entry))))))

(defun cache-put (key value &key ttl)
  "Put a value in cache.

  Args:
    KEY: Cache key
    VALUE: Value to cache
    TTL: Time-to-live in seconds

  Returns:
    T"
  (setf (gethash key *cache-store*) (make-cache-entry key value :ttl ttl))
  (log-debug "Cached key ~A with TTL ~A seconds" key ttl)
  t)

(defun cache-delete (key)
  "Delete a key from cache.

  Args:
    KEY: Cache key

  Returns:
    T if key existed"
  (when (gethash key *cache-store*)
    (remhash key *cache-store*)
    t))

(defun cache-clear ()
  "Clear all cache entries.

  Returns:
    T"
  (clrhash *cache-store*)
  (log-info "Cache cleared")
  t)

(defun cache-stats ()
  "Get cache statistics.

  Returns:
    Stats plist"
  (let ((total 0)
        (expired 0)
        (total-accesses 0)
        (now (get-universal-time)))
    (maphash (lambda (k v)
               (declare (ignore k))
               (incf total)
               (incf total-accesses (cache-entry-access-count v))
               (when (and (cache-entry-expires v)
                          (> now (cache-entry-expires v)))
                 (incf expired)))
             *cache-store*)
    `(:total ,total
      :expired ,expired
      :total-accesses ,total-accesses
      :hit-rate ,(if (plusp total-accesses)
                     (/ total-accesses (+ total-accesses total))
                     0))))

(defun cache-keys ()
  "List all cache keys.

  Returns:
    List of keys"
  (let ((keys nil))
    (maphash (lambda (k v)
               (declare (ignore v))
               (push k keys))
             *cache-store*)
    keys))

;;; ============================================================================
;;; Response Cache
;;; ============================================================================

(defvar *response-cache* (make-hash-table :test 'equal)
  "Cache for AI responses.")

(defun compute-response-cache-key (model messages &optional system-prompt)
  "Compute a cache key for a response.

  Args:
    MODEL: Model name
    MESSAGES: List of messages
    SYSTEM-PROMPT: Optional system prompt

  Returns:
    Cache key string"
  (let* ((messages-hash (sxhash (prin1-to-string messages)))
         (system-hash (sxhash (or system-prompt ""))))
    (format nil "response:~A:~A:~A" model messages-hash system-hash)))

(defun cache-response (model messages response &key system-prompt (ttl 3600))
  "Cache an AI response.

  Args:
    MODEL: Model name
    MESSAGES: Input messages
    RESPONSE: Response to cache
    SYSTEM-PROMPT: Optional system prompt
    TTL: Time-to-live in seconds (default 1 hour)

  Returns:
    Cache key"
  (let ((key (compute-response-cache-key model messages system-prompt)))
    (setf (gethash key *response-cache*)
          (make-cache-entry key response :ttl ttl))
    (log-debug "Cached response for model ~A" model)
    key))

(defun get-cached-response (model messages &optional system-prompt)
  "Get a cached AI response.

  Args:
    MODEL: Model name
    MESSAGES: Input messages
    SYSTEM-PROMPT: Optional system prompt

  Returns:
    Cached response or NIL"
  (let ((key (compute-response-cache-key model messages system-prompt)))
    (cache-get key)))

(defun invalidate-response-cache (&key model)
  "Invalidate response cache.

  Args:
    MODEL: Optional model filter

  Returns:
    Number of entries invalidated"
  (let ((count 0))
    (maphash (lambda (k v)
               (when (or (null model)
                         (search (format nil "response:~A:" model) k))
                 (remhash k *response-cache*)
                 (incf count)))
             *response-cache*)
    (when (plusp count)
      (log-info "Invalidated ~A response cache entries" count))
    count))

;;; ============================================================================
;;; TTL Cache Class
;;; ============================================================================

(defclass ttl-cache ()
  ((store :initform (make-hash-table :test 'equal)
          :documentation "Internal cache store")
   (default-ttl :initarg :default-ttl
                :accessor ttl-cache-default-ttl
                :documentation "Default TTL in seconds")
   (max-size :initarg :max-size
             :accessor ttl-cache-max-size
             :documentation "Maximum cache size"))
  (:documentation "TTL-based cache with size limit"))

(defun make-ttl-cache (&key (default-ttl 3600) (max-size 1000))
  "Create a new TTL cache.

  Args:
    DEFAULT-TTL: Default time-to-live in seconds
    MAX-SIZE: Maximum number of entries

  Returns:
    New ttl-cache instance"
  (make-instance 'ttl-cache
                 :default-ttl default-ttl
                 :max-size max-size))

(defun ttl-cache-get (cache key)
  "Get value from TTL cache.

  Args:
    CACHE: TTL cache instance
    KEY: Cache key

  Returns:
    Value or NIL"
  (let* ((store (slot-value cache 'store))
         (entry (gethash key store)))
    (when entry
      (if (and (cache-entry-expires entry)
               (> (get-universal-time) (cache-entry-expires entry)))
          (progn
            (remhash key store)
            nil)
          (progn
            (incf (cache-entry-access-count entry))
            (cache-entry-value entry))))))

(defun ttl-cache-put (cache key value &key ttl)
  "Put value in TTL cache.

  Args:
    CACHE: TTL cache instance
    KEY: Cache key
    VALUE: Value to cache
    TTL: Optional custom TTL

  Returns:
    T"
  (let* ((store (slot-value cache 'store))
         (actual-ttl (or ttl (ttl-cache-default-ttl cache)))
         (max-size (ttl-cache-max-size cache)))
    ;; Evict if at capacity
    (when (>= (hash-table-count store) max-size)
      ;; Remove oldest entry
      (let ((oldest-key nil)
            (oldest-time most-positive-fixnum))
        (maphash (lambda (k v)
                   (declare (ignore k))
                   (let ((created (cache-entry-created v)))
                     (when (< created oldest-time)
                       (setf oldest-time created
                             oldest-key k))))
                 store)
        (when oldest-key
          (remhash oldest-key store))))
    ;; Add entry
    (setf (gethash key store)
          (make-cache-entry key value :ttl actual-ttl))
    t))

(defun ttl-cache-cleanup (cache)
  "Remove expired entries from cache.

  Args:
    CACHE: TTL cache instance

  Returns:
    Number of entries removed"
  (let* ((store (slot-value cache 'store))
         (count 0)
         (now (get-universal-time)))
    (maphash (lambda (k v)
               (when (and (cache-entry-expires v)
                          (> now (cache-entry-expires v)))
                 (remhash k store)
                 (incf count)))
             store)
    (when (plusp count)
      (log-debug "TTL cache cleanup removed ~A entries" count))
    count))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-cache-system ()
  "Initialize the cache system.

  Returns:
    T"
  (log-info "Cache system initialized")
  t)
