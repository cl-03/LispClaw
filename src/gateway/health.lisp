;;; health.lisp --- Gateway Health Monitoring for Lisp-Claw
;;;
;;; This file implements health monitoring and status reporting
;;; for the Lisp-Claw gateway.

(defpackage #:lisp-claw.gateway.health
  (:nicknames #:lc.gateway.health)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging)
  (:export
   #:*health-status*
   #:get-health-status
   #:check-system-health
   #:get-memory-usage
   #:get-thread-count
   #:get-uptime
   #:health-check
   #:run-health-checks))

(in-package #:lisp-claw.gateway.health)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *health-status* :healthy
  "Current overall health status.")

(defvar *health-checks* (make-hash-table :test 'equal)
  "Hash table of individual health check results.")

(defvar *start-time* nil
  "Gateway start time (universal time).")

(defvar *health-lock* (bt:make-lock)
  "Lock for health status updates.")

;;; ============================================================================
;;; Health Status
;;; ============================================================================

(defun initialize-health ()
  "Initialize health monitoring system.

  Returns:
    T on success"
  (setf *start-time* (get-universal-time))
  (setf *health-status* :healthy)
  (log-info "Health monitoring initialized")
  t)

(defun get-health-status ()
  "Get the current health status.

  Returns:
    Health status alist"
  (bt:with-lock-held (*health-lock*)
    `((:status . ,(string *health-status*))
      (:uptime . ,(- (get-universal-time) (or *start-time* (get-universal-time))))
      (:timestamp . ,(get-universal-time))
      (:memory . ,(get-memory-usage))
      (:threads . ,(get-thread-count))
      (:checks . ,(get-all-checks)))))

(defun set-health-status (status)
  "Set the overall health status.

  Args:
    STATUS: Status keyword (:healthy, :degraded, :unhealthy)

  Returns:
    T on success"
  (bt:with-lock-held (*health-lock*)
    (when (member status '(:healthy :degraded :unhealthy))
      (setf *health-status* status)
      (log-info "Health status changed to: ~A" status)
      t)))

;;; ============================================================================
;;; Health Checks
;;; ============================================================================

(defun register-health-check (name check-function)
  "Register a health check.

  Args:
    NAME: Check name
    CHECK-FUNCTION: Function that returns (ok message)

  Returns:
    T on success"
  (setf (gethash name *health-checks*)
        (list :function check-function
              :last-result nil
              :last-error nil
              :last-run nil))
  (log-debug "Registered health check: ~A" name)
  t)

(defun run-health-check (name)
  "Run a specific health check.

  Args:
    NAME: Check name

  Returns:
    (values ok message)"
  (let ((check (gethash name *health-checks*)))
    (unless check
      (return-from run-health-check (values nil "Check not found"))))

  (let* ((check-func (plist-get check :function))
         (ok nil)
         (message nil))
    (handler-case
        (multiple-value-setq (ok message)
          (funcall check-func))
      (error (e)
        (setf ok nil)
        (setf message (format nil "Error: ~A" e))))

    ;; Update check result
    (bt:with-lock-held (*health-lock*)
      (setf (gethash name *health-checks*)
            (list :function check-func
                  :last-result ok
                  :last-message message
                  :last-run (get-universal-time))))

    (values ok message)))

(defun run-all-health-checks ()
  "Run all registered health checks.

  Returns:
    Alist of check results"
  (let ((results nil)
        (all-ok t))
    (maphash (lambda (name check)
               (declare (ignore check))
               (multiple-value-bind (ok message)
                   (run-health-check name)
                 (push (cons name (list :ok ok :message message)) results)
                 (unless ok
                   (setf all-ok nil))))
             *health-checks*)

    ;; Update overall status
    (if all-ok
        (set-health-status :healthy)
        (set-health-status :degraded))

    (nreverse results)))

(defun get-all-checks ()
  "Get all health check results.

  Returns:
    Alist of check results"
  (let ((results nil))
    (maphash (lambda (name check)
               (push (cons name
                           (list :ok (plist-get check :last-result)
                                 :message (plist-get check :last-message)
                                 :last-run (plist-get check :last-run))))
                     results))
    (nreverse results)))

(defun get-check-result (name)
  "Get the result of a specific health check.

  Args:
    NAME: Check name

  Returns:
    Check result alist or NIL"
  (let ((check (gethash name *health-checks*)))
    (when check
      (list :ok (plist-get check :last-result)
            :message (plist-get check :last-message)
            :last-run (plist-get check :last-run)))))

;;; ============================================================================
;;; Built-in Health Checks
;;; ============================================================================

(defun check-memory ()
  "Check memory usage.

  Returns:
    (values ok message)"
  (let ((usage (get-memory-usage)))
    (if usage
        (values t (format nil "Memory usage: ~A" usage))
        (values t "Memory info not available"))))

(defun check-threads ()
  "Check thread count.

  Returns:
    (values ok message)"
  (let ((count (get-thread-count)))
    (if (< count 100)
        (values t (format nil "Thread count: ~A" count))
        (values nil (format nil "High thread count: ~A" count)))))

(defun check-uptime ()
  "Check gateway uptime.

  Returns:
    (values ok message)"
  (if *start-time*
      (let ((uptime (- (get-universal-time) *start-time*)))
        (values t (format nil "Uptime: ~A seconds" uptime)))
      (values nil "Start time not set")))

(defun register-built-in-checks ()
  "Register built-in health checks.

  Returns:
    T on success"
  (register-health-check "memory" #'check-memory)
  (register-health-check "threads" #'check-threads)
  (register-health-check "uptime" #'check-uptime)
  (log-info "Built-in health checks registered")
  t)

;;; ============================================================================
;;; System Information
;;; ============================================================================

(defun get-memory-usage ()
  "Get current memory usage.

  Returns:
    Memory usage in bytes or NIL if unavailable"
  ;; Common Lisp doesn't have standard memory info
  ;; This would need implementation-specific code
  #+sbcl
  (let ((room-info (sb-ext:room-stats)))
    (plist-get room-info :live-bytes))
  #+ccl
  (ccl:free-heap-size)
  #-(or sbcl ccl)
  nil)

(defun get-thread-count ()
  "Get current thread count.

  Returns:
    Number of threads"
  (length (bt:list-all-threads)))

(defun get-uptime ()
  "Get gateway uptime in seconds.

  Returns:
    Uptime in seconds"
  (if *start-time*
      (- (get-universal-time) *start-time*)
      0))

(defun get-system-info ()
  "Get system information.

  Returns:
    System info alist"
  `((:lisp-implementation . ,(lisp-implementation-type))
    (:lisp-version . ,(lisp-implementation-version))
    (:machine . ,(machine-type))
    (:os . ,(software-type))
    (:memory . ,(get-memory-usage))
    (:threads . ,(get-thread-count))
    (:uptime . ,(get-uptime))))

;;; ============================================================================
;;; Health Report
;;; ============================================================================

(defun health-check ()
  "Perform a complete health check.

  Returns:
    Health report alist"
  (run-all-health-checks)
  (get-health-status))

(defun print-health-report (&optional (stream t))
  "Print a health report.

  Args:
    STREAM: Output stream (default: standard-output)

  Returns:
    NIL"
  (let ((status (health-check)))
    (format stream "=== Lisp-Claw Health Report ===~%")
    (format stream "Status: ~A~%" (plist-get status :status))
    (format stream "Uptime: ~A seconds~%" (plist-get status :uptime))
    (format stream "Memory: ~A~%" (plist-get status :memory))
    (format stream "Threads: ~A~%" (plist-get status :threads))
    (format stream "~%Health Checks:~%")
    (dolist (check (plist-get status :checks))
      (let ((name (car check))
            (result (cdr check)))
        (format stream "  ~A: ~A~%"
                name
                (if (plist-get result :ok) "OK" "FAIL"))
        (when (plist-get result :message)
          (format stream "    ~A~%" (plist-get result :message)))))))
