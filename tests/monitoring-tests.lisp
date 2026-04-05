;;; monitoring-tests.lisp --- Tests for Monitoring Module
;;;
;;; This file contains tests for the Prometheus monitoring module.

(defpackage #:lisp-claw-tests.monitoring
  (:nicknames #:lc-tests.monitoring)
  (:use #:cl
        #:prove
        #:lisp-claw.monitoring.prometheus)
  (:export
   #:test-monitoring))

(in-package #:lisp-claw-tests.monitoring)

(define-test test-monitoring
  "Test Prometheus monitoring module"

  ;; Test counter creation
  (let ((counter (make-counter "test_counter" "Test counter description")))
    (ok counter "Counter created")
    (is (type-of counter) 'prometheus-counter "Counter type is correct")
    (is (counter-value counter) 0 "Counter initial value is 0")

    ;; Test counter increment
    (incf-counter counter)
    (is (counter-value counter) 1 "Counter incremented")

    (incf-counter counter :amount 5)
    (is (counter-value counter) 6 "Counter incremented by 5"))

  ;; Test gauge creation
  (let ((gauge (make-gauge "test_gauge" "Test gauge description")))
    (ok gauge "Gauge created")
    (is (type-of gauge) 'prometheus-gauge "Gauge type is correct")
    (is (gauge-value gauge) 0.0 "Gauge initial value is 0.0")

    ;; Test gauge operations
    (incf-gauge gauge)
    (is (gauge-value gauge) 1.0 "Gauge incremented")

    (decf-gauge gauge)
    (is (gauge-value gauge) 0.0 "Gauge decremented")

    (set-gauge gauge 42.5)
    (is (gauge-value gauge) 42.5 "Gauge value set"))

  ;; Test histogram creation
  (let ((histogram (make-histogram "test_histogram" "Test histogram description"
                                   :buckets '(1.0 5.0 10.0))))
    (ok histogram "Histogram created")
    (is (type-of histogram) 'prometheus-histogram "Histogram type is correct")

    ;; Test histogram observation
    (observe-histogram histogram 3.0)
    (is (histogram-count histogram) 1 "Histogram count is 1")
    (is (histogram-sum histogram) 3.0 "Histogram sum is 3.0"))

  ;; Test metrics listing
  (let ((metrics (list-metrics)))
    (ok (>= (length metrics) 3) "Multiple metrics registered"))

  ;; Test Prometheus format export
  (let ((output (metrics-to-prometheus-format)))
    (ok (stringp output) "Prometheus format output is string")
    (ok (> (length output) 0) "Prometheus format output is not empty")))
