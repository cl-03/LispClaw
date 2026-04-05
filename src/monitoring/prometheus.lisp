;;; monitoring/prometheus.lisp --- Prometheus Metrics Export for Lisp-Claw
;;;
;;; This file implements Prometheus metrics collection and export.

(defpackage #:lisp-claw.monitoring.prometheus
  (:nicknames #:lc.monitoring.prometheus)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; Metrics types
   #:prometheus-counter
   #:prometheus-gauge
   #:prometheus-histogram
   #:prometheus-summary
   ;; Metric operations
   #:make-counter
   #:make-gauge
   #:make-histogram
   #:incf-counter
   #:incf-gauge
   #:decf-gauge
   #:set-gauge
   #:observe-histogram
   ;; Registry
   #:*metric-registry*
   #:register-metric
   #:unregister-metric
   #:get-metric
   #:list-metrics
   ;; Export
   #:metrics-to-prometheus-format
   #:start-metrics-server
   #:stop-metrics-server
   ;; Built-in metrics
   #:record-request-latency
   #:record-active-connections
   #:record-memory-usage
   #:record-cpu-usage
   #:record-error-count
   ;; Initialization
   #:initialize-prometheus-system))

(in-package #:lisp-claw.monitoring.prometheus)

;;; ============================================================================
;;; Metric Classes
;;; ============================================================================

(defclass prometheus-metric ()
  ((name :initarg :name
         :reader metric-name
         :documentation "Metric name")
   (help :initarg :help
         :reader metric-help
         :documentation "Help text")
   (type :initarg :type
         :reader metric-type
         :documentation "Metric type: counter, gauge, histogram, summary")
   (labels :initarg :labels
           :initform nil
           :reader metric-labels
           :documentation "Label names")
   (created-at :initform (get-universal-time)
               :reader metric-created-at
               :documentation "Creation timestamp"))
  (:documentation "Base Prometheus metric"))

(defclass prometheus-counter (prometheus-metric)
  ((value :initform 0
          :accessor counter-value
          :documentation "Counter value"))
  (:documentation "Prometheus counter metric"))

(defclass prometheus-gauge (prometheus-metric)
  ((value :initform 0.0
          :accessor gauge-value
          :documentation "Gauge value"))
  (:documentation "Prometheus gauge metric"))

(defclass prometheus-histogram (prometheus-metric)
  ((buckets :initarg :buckets
            :initform '(0.001 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1.0 2.5 5.0 10.0)
            :reader histogram-buckets
            :documentation "Bucket boundaries")
   (bucket-counts :initform nil
                  :accessor histogram-bucket-counts
                  :documentation "Counts per bucket")
   (sum :initform 0.0
        :accessor histogram-sum
        :documentation "Sum of all observations")
   (count :initform 0
          :accessor histogram-count
          :documentation "Total number of observations"))
  (:documentation "Prometheus histogram metric"))

(defclass prometheus-summary (prometheus-metric)
  ((observations :initform nil
                 :accessor summary-observations
                 :documentation "List of observations")
   (sum :initform 0.0
        :accessor summary-sum
        :documentation "Sum of observations")
   (count :initform 0
          :accessor summary-count
          :documentation "Number of observations"))
  (:documentation "Prometheus summary metric"))

;;; ============================================================================
;;; Metric Registry
;;; ============================================================================

(defvar *metric-registry* (make-hash-table :test 'equal)
  "Registry of all metrics.")

(defvar *registry-lock* (bt:make-lock)
  "Lock for thread-safe registry access.")

(defun register-metric (metric)
  "Register a metric.

  Args:
    METRIC: Metric instance

  Returns:
    T on success"
  (bt:with-lock-held (*registry-lock*)
    (setf (gethash (metric-name metric) *metric-registry*) metric)
    (log-info "Registered Prometheus metric: ~A" (metric-name metric))
    t))

(defun unregister-metric (name)
  "Unregister a metric.

  Args:
    NAME: Metric name

  Returns:
    T if metric was removed"
  (bt:with-lock-held (*registry-lock*)
    (when (gethash name *metric-registry*)
      (remhash name *metric-registry*)
      t)))

(defun get-metric (name)
  "Get a metric by name.

  Args:
    NAME: Metric name

  Returns:
    Metric instance or NIL"
  (gethash name *metric-registry*))

(defun list-metrics ()
  "List all registered metrics.

  Returns:
    List of metric names"
  (let ((names nil))
    (maphash (lambda (k v)
               (declare (ignore v))
               (push k names))
             *metric-registry*)
    names))

;;; ============================================================================
;;; Metric Creation
;;; ============================================================================

(defun make-counter (name help &key labels)
  "Create a counter metric.

  Args:
    NAME: Metric name
    HELP: Help text
    LABELS: List of label names

  Returns:
    Counter instance"
  (let ((counter (make-instance 'prometheus-counter
                                :name name
                                :help help
                                :type :counter
                                :labels labels)))
    (register-metric counter)
    counter))

(defun make-gauge (name help &key labels)
  "Create a gauge metric.

  Args:
    NAME: Metric name
    HELP: Help text
    LABELS: List of label names

  Returns:
    Gauge instance"
  (let ((gauge (make-instance 'prometheus-gauge
                              :name name
                              :help help
                              :type :gauge
                              :labels labels)))
    (register-metric gauge)
    gauge))

(defun make-histogram (name help &key labels buckets)
  "Create a histogram metric.

  Args:
    NAME: Metric name
    HELP: Help text
    LABELS: List of label names
    BUCKETS: Bucket boundaries (default: standard buckets)

  Returns:
    Histogram instance"
  (let ((histogram (make-instance 'prometheus-histogram
                                  :name name
                                  :help help
                                  :type :histogram
                                  :labels labels
                                  :buckets (or buckets
                                               '(0.001 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1.0 2.5 5.0 10.0)))))
    ;; Initialize bucket counts
    (setf (histogram-bucket-counts histogram)
          (make-list (length (slot-value histogram 'buckets)) :initial-element 0))
    (register-metric histogram)
    histogram))

(defun make-summary (name help &key labels)
  "Create a summary metric.

  Args:
    NAME: Metric name
    HELP: Help text
    LABELS: List of label names

  Returns:
    Summary instance"
  (let ((summary (make-instance 'prometheus-summary
                                :name name
                                :help help
                                :type :summary
                                :labels labels)))
    (register-metric summary)
    summary))

;;; ============================================================================
;;; Metric Operations
;;; ============================================================================

(defun incf-counter (counter &key (amount 1) labels)
  "Increment a counter.

  Args:
    COUNTER: Counter instance
    AMOUNT: Amount to increment (default: 1)
    LABELS: Label values (alist)

  Returns:
    New value"
  (declare (ignore labels))  ; Label filtering not implemented for simplicity
  (incf (counter-value counter) amount))

(defun incf-gauge (gauge &key (amount 1.0) labels)
  "Increment a gauge.

  Args:
    GAUGE: Gauge instance
    AMOUNT: Amount to increment (default: 1.0)
    LABELS: Label values

  Returns:
    New value"
  (declare (ignore labels))
  (incf (gauge-value gauge) amount))

(defun decf-gauge (gauge &key (amount 1.0) labels)
  "Decrement a gauge.

  Args:
    GAUGE: Gauge instance
    AMOUNT: Amount to decrement (default: 1.0)
    LABELS: Label values

  Returns:
    New value"
  (declare (ignore labels))
  (decf (gauge-value gauge) amount))

(defun set-gauge (gauge value &key labels)
  "Set a gauge value.

  Args:
    GAUGE: Gauge instance
    VALUE: New value
    LABELS: Label values

  Returns:
    VALUE"
  (declare (ignore labels))
  (setf (gauge-value gauge) value))

(defun observe-histogram (histogram value &key labels)
  "Record an observation in a histogram.

  Args:
    HISTOGRAM: Histogram instance
    VALUE: Observed value
    LABELS: Label values

  Returns:
    T"
  (declare (ignore labels))
  ;; Increment bucket counts
  (let ((buckets (histogram-bucket-counts histogram))
        (edges (histogram-buckets histogram)))
    (loop for i below (length edges)
          for edge = (nth i edges)
          when (<= value edge)
          do (incf (nth i buckets))))
  ;; Update sum and count
  (incf (histogram-sum histogram) value)
  (incf (histogram-count histogram))
  t)

;;; ============================================================================
;; Built-in Metrics
;;; ============================================================================

(defvar *request-latency-histogram* nil
  "Histogram for request latency.")

(defvar *active-connections-gauge* nil
  "Gauge for active connections.")

(defvar *memory-usage-gauge* nil
  "Gauge for memory usage.")

(defvar *cpu-usage-gauge* nil
  "Gauge for CPU usage.")

(defvar *error-counter* nil
  "Counter for errors.")

(defvar *message-counter* nil
  "Counter for messages processed.")

(defun create-built-in-metrics ()
  "Create built-in metrics.

  Returns:
    T"
  (setf *request-latency-histogram*
        (make-histogram "lisp_claw_request_latency_seconds"
                        "Request latency in seconds"
                        :buckets '(0.001 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1.0 2.5 5.0)))

  (setf *active-connections-gauge*
        (make-gauge "lisp_claw_active_connections"
                    "Number of active connections"))

  (setf *memory-usage-gauge*
        (make-gauge "lisp_claw_memory_usage_bytes"
                    "Memory usage in bytes"))

  (setf *cpu-usage-gauge*
        (make-gauge "lisp_claw_cpu_usage_percent"
                    "CPU usage percentage"))

  (setf *error-counter*
        (make-counter "lisp_claw_errors_total"
                      "Total number of errors"))

  (setf *message-counter*
        (make-counter "lisp_claw_messages_processed_total"
                      "Total number of messages processed"))

  (log-info "Built-in Prometheus metrics created")
  t)

(defun record-request-latency (latency-seconds)
  "Record request latency.

  Args:
    LATENCY-SECONDS: Latency in seconds

  Returns:
    T"
  (when *request-latency-histogram*
    (observe-histogram *request-latency-histogram* latency-seconds))
  t)

(defun record-active-connections (count)
  "Record active connections.

  Args:
    COUNT: Number of connections

  Returns:
    T"
  (when *active-connections-gauge*
    (set-gauge *active-connections-gauge* count))
  t)

(defun record-memory-usage (bytes)
  "Record memory usage.

  Args:
    BYTES: Memory usage in bytes

  Returns:
    T"
  (when *memory-usage-gauge*
    (set-gauge *memory-usage-gauge* bytes))
  t)

(defun record-cpu-usage (percent)
  "Record CPU usage.

  Args:
    PERCENT: CPU usage percentage

  Returns:
    T"
  (when *cpu-usage-gauge*
    (set-gauge *cpu-usage-gauge* percent))
  t)

(defun record-error-count (&key (amount 1) error-type)
  "Record error count.

  Args:
    AMOUNT: Number of errors
    ERROR-TYPE: Type of error

  Returns:
    T"
  (when *error-counter*
    (incf-counter *error-counter* :amount amount))
  (declare (ignore error-type))
  t)

(defun record-message-processed ()
  "Record a processed message.

  Returns:
    T"
  (when *message-counter*
    (incf-counter *message-counter* :amount 1))
  t)

;;; ============================================================================
;;; Prometheus Format Export
;;; ============================================================================

(defun counter-to-prometheus (counter)
  "Convert counter to Prometheus format.

  Args:
    COUNTER: Counter instance

  Returns:
    Prometheus format string"
  (format nil "# HELP ~A ~A~%# TYPE ~A counter~%~A ~A~%"
          (metric-name counter)
          (metric-help counter)
          (metric-name counter)
          (metric-name counter)
          (counter-value counter)))

(defun gauge-to-prometheus (gauge)
  "Convert gauge to Prometheus format.

  Args:
    GAUGE: Gauge instance

  Returns:
    Prometheus format string"
  (format nil "# HELP ~A ~A~%# TYPE ~A gauge~%~A ~A~%"
          (metric-name gauge)
          (metric-help gauge)
          (metric-name gauge)
          (metric-name gauge)
          (gauge-value gauge)))

(defun histogram-to-prometheus (histogram)
  "Convert histogram to Prometheus format.

  Args:
    HISTOGRAM: Histogram instance

  Returns:
    Prometheus format string"
  (let ((name (metric-name histogram))
        (help (metric-help histogram))
        (buckets (histogram-buckets histogram))
        (counts (histogram-bucket-counts histogram))
        (sum (histogram-sum histogram))
        (count (histogram-count histogram))
        (output nil))

    ;; HELP and TYPE
    (push (format nil "# HELP ~A ~A~%" name help) output)
    (push (format nil "# TYPE ~A histogram~%" name) output)

    ;; Bucket counts
    (let ((cumulative 0))
      (loop for i below (length buckets)
            for bucket = (nth i buckets)
            for bucket-count = (nth i counts)
            do (incf cumulative bucket-count)
               (push (format nil "~A_bucket{le=\"~A\"} ~A~%" name bucket cumulative) output)))

    ;; Infinity bucket
    (push (format nil "~A_bucket{le=\"+Inf\"} ~A~%" name count) output)

    ;; Sum and count
    (push (format nil "~A_sum ~A~%" name sum) output)
    (push (format nil "~A_count ~A~%" name count) output)

    (apply #'concatenate 'string (nreverse output))))

(defun metrics-to-prometheus-format ()
  "Convert all metrics to Prometheus format.

  Returns:
    Prometheus format string"
  (let ((output nil))
    (maphash (lambda (name metric)
               (declare (ignore name))
               (push (ecase (metric-type metric)
                       ((:counter) (counter-to-prometheus metric))
                       ((:gauge) (gauge-to-prometheus metric))
                       ((:histogram) (histogram-to-prometheus metric))
                       ((:summary) ""))  ; Summary not fully implemented
                     output))
             *metric-registry*)
    (apply #'concatenate 'string (nreverse output))))

;;; ============================================================================
;;; Metrics HTTP Server
;;; ============================================================================

(defvar *metrics-server* nil
  "Metrics HTTP server instance.")

(defvar *metrics-port* 9090
  "Port for metrics endpoint.")

(defun start-metrics-server (&key port)
  "Start HTTP server for metrics endpoint.

  Args:
    PORT: Port number (default: 9090)

  Returns:
    T"
  (setf *metrics-port* (or port 9090))

  ;; Simple HTTP server using Hunchentoot
  (let ((acceptor (make-instance 'hunchentoot:easy-acceptor
                                 :port *metrics-port*)))
    (setf hunchentoot:*message-log-destination* nil)
    (setf hunchentoot:*access-log-destination* nil)

    ;; Define metrics endpoint
    (hunchentoot:define-easy-handler (metrics :uri "/metrics") ()
      (setf (hunchentoot:content-type*) "text/plain; version=0.0.4")
      (metrics-to-prometheus-format))

    ;; Define health endpoint
    (hunchentoot:define-easy-handler (health :uri "/health") ()
      (setf (hunchentoot:content-type*) "application/json")
      (json-to-string '(:status "healthy" :service "lisp-claw-metrics")))

    (hunchentoot:start acceptor)
    (setf *metrics-server* acceptor)
    (log-info "Prometheus metrics server started on port ~A" *metrics-port*))
  t)

(defun stop-metrics-server ()
  "Stop metrics server.

  Returns:
    T"
  (when *metrics-server*
    (hunchentoot:stop *metrics-server*)
    (setf *metrics-server* nil)
    (log-info "Prometheus metrics server stopped"))
  t)

;;; ============================================================================
;;; Collection Loop
;;; ============================================================================

(defvar *collection-thread* nil
  "Thread for metrics collection.")

(defvar *collection-running-p* nil
  "Whether collection is running.")

(defun collect-system-metrics ()
  "Collect system metrics.

  Returns:
    T"
  ;; Memory usage (simplified)
  (let ((memory-usage (get-bytes-consed)))
    (record-memory-usage memory-usage))

  ;; CPU usage would require external library
  ;; Placeholder for now

  t)

(defun start-metrics-collection (&key interval)
  "Start periodic metrics collection.

  Args:
    INTERVAL: Collection interval in seconds (default: 15)

  Returns:
    T"
  (let ((collection-interval (or interval 15)))
    (setf *collection-running-p* t)
    (setf *collection-thread*
          (bt:make-thread
           (lambda ()
             (loop while *collection-running-p*
                   do (collect-system-metrics)
                   do (sleep collection-interval)))
           :name "metrics-collection")))
  (log-info "Prometheus metrics collection started")
  t)

(defun stop-metrics-collection ()
  "Stop metrics collection.

  Returns:
    T"
  (setf *collection-running-p* nil)
  (when *collection-thread*
    (bt:destroy-thread *collection-thread*)
    (setf *collection-thread* nil))
  (log-info "Prometheus metrics collection stopped")
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-prometheus-system (&key port collection-interval)
  "Initialize Prometheus monitoring system.

  Args:
    PORT: Metrics server port (default: 9090)
    COLLECTION-INTERVAL: Collection interval in seconds (default: 15)

  Returns:
    T"
  (create-built-in-metrics)
  (start-metrics-server :port (or port 9090))
  (start-metrics-collection :interval (or collection-interval 15))
  (log-info "Prometheus monitoring system initialized")
  t)
