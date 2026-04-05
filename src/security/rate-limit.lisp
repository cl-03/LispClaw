;;; security/rate-limit.lisp --- Rate Limiting System
;;;
;;; This file provides request rate limiting for API calls.

(defpackage #:lisp-claw.security.rate-limit
  (:nicknames #:lc.sec.rate-limit)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging)
  (:export
   ;; Rate limiter
   #:rate-limiter
   #:make-rate-limiter
   #:rate-limiter-requests
   #:rate-limiter-window
   #:rate-limiter-limit
   ;; Rate limit operations
   #:check-rate-limit
   #:reset-rate-limit
   #:get-rate-limit-status
   ;; Global limiters
   #:*api-rate-limiter*
   #:*global-rate-limiter*
   ;; Rate limit strategies
   #:sliding-window-limiter
   #:token-bucket-limiter
   #:fixed-window-limiter
   ;; Exceptions
   #:rate-limit-exceeded
   #:rate-limit-retry-after
   ;; Initialization
   #:initialize-rate-limiting))

(in-package #:lisp-claw.security.rate-limit)

;;; ============================================================================
;;; Rate Limit Conditions
;;; ============================================================================

(define-condition rate-limit-exceeded (error)
  ((retry-after :initarg :retry-after
                :reader rate-limit-retry-after
                :documentation "Seconds until retry is allowed"))
  (:report (lambda (condition stream)
             (format stream "Rate limit exceeded. Retry after ~A seconds."
                     (rate-limit-retry-after condition)))))

;;; ============================================================================
;;; Rate Limiter Class
;;; ============================================================================

(defclass rate-limiter ()
  ((requests :initform (make-hash-table :test 'equal)
             :reader rate-limiter-requests
             :documentation "Request tracking store")
   (window :initarg :window
           :initform 60
           :reader rate-limiter-window
           :documentation "Time window in seconds")
   (limit :initarg :limit
          :initform 100
          :reader rate-limiter-limit
          :documentation "Maximum requests per window"))
  (:documentation "Rate limiter using sliding window"))

(defun make-rate-limiter (&key (window 60) (limit 100))
  "Create a new rate limiter.

  Args:
    WINDOW: Time window in seconds (default 60)
    LIMIT: Maximum requests per window (default 100)

  Returns:
    New rate-limiter instance"
  (make-instance 'rate-limiter :window window :limit limit))

;;; ============================================================================
;;; Sliding Window Rate Limiter
;;; ============================================================================

(defclass sliding-window-limiter (rate-limiter)
  ()
  (:documentation "Sliding window rate limiter"))

(defun check-rate-limit (limiter client-id)
  "Check if a request is within rate limits.

  Args:
    LIMITER: Rate limiter instance
    CLIENT-ID: Client identifier

  Returns:
    T if allowed

  Raises:
    RATE-LIMIT-EXCEEDED if limit exceeded"
  (let* ((requests (slot-value limiter 'requests))
         (now (get-universal-time))
         (window (rate-limiter-window limiter))
         (limit (rate-limiter-limit limiter))
         (cutoff (- now window))
         (client-requests (gethash client-id requests nil)))
    ;; Filter out old requests
    (let ((valid-requests (remove-if (lambda (ts) (< ts cutoff)) client-requests)))
      (if (>= (length valid-requests) limit)
          ;; Rate limit exceeded
          (let* ((oldest (apply #'min valid-requests))
                 (retry-after (+ (- oldest window) (- now))))
            (log-warn "Rate limit exceeded for ~A" client-id)
            (error 'rate-limit-exceeded :retry-after retry-after))
          ;; Allow request
          (progn
            (setf (gethash client-id requests)
                  (push now valid-requests))
            t)))))

(defun reset-rate-limit (limiter client-id)
  "Reset rate limit for a client.

  Args:
    LIMITER: Rate limiter instance
    CLIENT-ID: Client identifier

  Returns:
    T"
  (remhash client-id (slot-value limiter 'requests))
  (log-info "Reset rate limit for ~A" client-id)
  t)

(defun get-rate-limit-status (limiter client-id)
  "Get rate limit status for a client.

  Args:
    LIMITER: Rate limiter instance
    CLIENT-ID: Client identifier

  Returns:
    Status plist"
  (let* ((requests (slot-value limiter 'requests))
         (now (get-universal-time))
         (window (rate-limiter-window limiter))
         (limit (rate-limiter-limit limiter))
         (cutoff (- now window))
         (client-requests (gethash client-id requests nil))
         (valid-requests (remove-if (lambda (ts) (< ts cutoff)) client-requests))
         (remaining (- limit (length valid-requests))))
    `(:remaining ,(max 0 remaining)
      :limit ,limit
      :window ,window
      :reset-at ,(+ now window))))

;;; ============================================================================
;;; Token Bucket Rate Limiter
;;; ============================================================================

(defclass token-bucket-limiter ()
  ((capacity :initarg :capacity
             :accessor token-bucket-capacity
             :documentation "Maximum tokens in bucket")
   (tokens :initarg :tokens
           :accessor token-bucket-tokens
           :documentation "Current tokens")
   (refill-rate :initarg :refill-rate
                :accessor token-bucket-refill-rate
                :documentation "Tokens per second")
   (last-refill :initform (get-universal-time)
                :accessor token-bucket-last-refill
                :documentation "Last refill timestamp"))
  (:documentation "Token bucket rate limiter"))

(defun make-token-bucket-limiter (&key (capacity 100) (refill-rate 10))
  "Create a token bucket limiter.

  Args:
    CAPACITY: Maximum tokens (default 100)
    REFILL-RATE: Tokens per second (default 10)

  Returns:
    New token-bucket-limiter instance"
  (make-instance 'token-bucket-limiter
                 :capacity capacity
                 :tokens capacity
                 :refill-rate refill-rate))

(defun check-token-bucket-limit (limiter client-id &optional (tokens-needed 1))
  "Check if request is allowed under token bucket limits.

  Args:
    LIMITER: Token bucket limiter
    CLIENT-ID: Client identifier
    TOKENS-NEEDED: Number of tokens needed (default 1)

  Returns:
    T if allowed, NIL otherwise"
  (let ((buckets (or (getf (slot-value limiter 'tokens) client-id)
                     (setf (getf (slot-value limiter 'tokens) client-id)
                           (list (token-bucket-capacity limiter) (get-universal-time))))))
    (destructuring-bind (available last-refill) buckets
      (let* ((now (get-universal-time))
             (elapsed (- now last-refill))
             (refilled (min (token-bucket-capacity limiter)
                            (+ available (* elapsed (token-bucket-refill-rate limiter))))))
        (if (>= refilled tokens-needed)
            (progn
              (setf (getf (slot-value limiter 'tokens) client-id)
                    (list (- refilled tokens-needed) now))
              t)
            nil)))))

;;; ============================================================================
;;; Fixed Window Rate Limiter
;;; ============================================================================

(defclass fixed-window-limiter (rate-limiter)
  ((current-window :initform 0
                   :accessor fixed-window-current
                   :documentation "Current window number")
   (window-count :initform 0
                 :accessor fixed-window-count
                 :documentation "Request count in current window"))
  (:documentation "Fixed window rate limiter"))

(defun make-fixed-window-limiter (&key (window 60) (limit 100))
  "Create a fixed window rate limiter.

  Args:
    WINDOW: Window size in seconds
    LIMIT: Maximum requests per window

  Returns:
    New fixed-window-limiter instance"
  (make-instance 'fixed-window-limiter :window window :limit limit))

(defun check-fixed-window-limit (limiter client-id)
  "Check if request is within fixed window limits.

  Args:
    LIMITER: Fixed window limiter
    CLIENT-ID: Client identifier

  Returns:
    T if allowed"
  (let* ((now (get-universal-time))
         (window (rate-limiter-window limiter))
         (limit (rate-limiter-limit limiter))
         (current-window (floor now window))
         (counts (or (gethash client-id (slot-value limiter 'requests))
                     (setf (gethash client-id (slot-value limiter 'requests))
                           (cons 0 0)))))
    ;; Check if we're in a new window
    (unless (= (car counts) current-window)
      (setf (car counts) current-window
            (cdr counts) 0))
    ;; Check limit
    (if (>= (cdr counts) limit)
        nil
        (progn
          (incf (cdr counts))
          t))))

;;; ============================================================================
;;; Global Rate Limiters
;;; ============================================================================

(defvar *api-rate-limiter* nil
  "Global API rate limiter.")

(defvar *global-rate-limiter* nil
  "Global rate limiter for all requests.")

(defun initialize-rate-limiting (&key (api-limit 100) (api-window 60)
                                      (global-limit 1000) (global-window 60))
  "Initialize global rate limiters.

  Args:
    API-LIMIT: API requests per window
    API-WINDOW: API time window in seconds
    GLOBAL-LIMIT: Global requests per window
    GLOBAL-WINDOW: Global time window in seconds

  Returns:
    T"
  (setf *api-rate-limiter* (make-rate-limiter :limit api-limit :window api-window))
  (setf *global-rate-limiter* (make-rate-limiter :limit global-limit :window global-window))
  (log-info "Rate limiting initialized: API=~A/~As, Global=~A/~As"
            api-limit api-window global-limit global-window)
  t)

;;; ============================================================================
;;; Utility Functions
;;; ============================================================================

(defmacro with-rate-limit ((limiter client-id) &body body)
  "Execute body with rate limiting.

  Args:
    LIMITER: Rate limiter instance
    CLIENT-ID: Client identifier

  Returns:
    Result of body

  Raises:
    RATE-LIMIT-EXCEEDED if limit exceeded"
  `(check-rate-limit limiter client-id)
  `, @body)
