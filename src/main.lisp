;;; main.lisp --- Main Entry Point for Lisp-Claw
;;;
;;; This file is the main entry point for the Lisp-Claw system.
;;; It initializes all subsystems and starts the gateway.

(defpackage #:lisp-claw.main
  (:nicknames #:lc.main)
  (:use #:cl
        #:alexandria
        #:lisp-claw
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.helpers
        #:lisp-claw.config.loader
        #:lisp-claw.gateway.server
        #:lisp-claw.gateway.health
        #:lisp-claw.channels.registry)
  (:export
   #:run
   #:start
   #:stop
   #:restart
   #:*lisp-claw-version*))

(in-package #:lisp-claw.main)

;;; ============================================================================
;;; Version Information
;;; ============================================================================

(defconstant +lisp-claw-version+ "0.1.0"
  "Lisp-Claw version string.")

(defvar *lisp-claw-version* +lisp-claw-version+
  "Current Lisp-Claw version.")

(defvar *lisp-claw-start-time* nil
  "Time when Lisp-Claw was started.")

(defvar *lisp-claw-running-p* nil
  "Whether Lisp-Claw is currently running.")

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun init-subsystems (&key config)
  "Initialize all Lisp-Claw subsystems.

  Args:
    CONFIG: Configuration alist (loads from file if NIL)

  Returns:
    T on success"
  (log-info "Initializing Lisp-Claw ~A" *lisp-claw-version*)

  ;; Load configuration
  (unless config
    (setf config (load-config)))

  ;; Initialize logging
  (let ((log-config (get-config-value :logging)))
    (setup-logging
     :level (keywordize (or (json-get log-config :level) "info"))
     :file (json-get log-config :file)))

  ;; Initialize health monitoring
  (initialize-health)
  (register-built-in-checks)

  ;; Register channel types
  ;; (register-channel-types)

  (log-info "All subsystems initialized")
  t)

;;; ============================================================================
;;; Main Entry Point
;;; ============================================================================

(defun run (&key config port bind daemon-p)
  "Main entry point for Lisp-Claw.

  Args:
    CONFIG: Configuration file path (NIL for default)
    PORT: Gateway port (overrides config)
    BIND: Gateway bind address (overrides config)
    DAEMON-P: Whether to run as daemon

  Returns:
    NIL (blocks until stopped)"
  (format t "~%")
  (format t "╔════════════════════════════════════════╗~%")
  (format t "║     Lisp-Claw AI Assistant Gateway     ║~%")
  (format t "║           Version ~A                  ║~%" *lisp-claw-version*)
  (format t "╚════════════════════════════════════════╝~%")
  (format t "~%")

  ;; Initialize
  (init-subsystems :config config)

  ;; Create gateway
  (let* ((gateway-config (load-config))
         (gateway-port (or port
                           (parse-integer
                            (or (json-get (get-config-value :gateway) :port)
                                "18789"))))
         (gateway-bind (or bind
                           (json-get (get-config-value :gateway) :bind)
                           "127.0.0.1")))
    (setf *gateway-port* gateway-port)
    (setf *gateway-bind* gateway-bind)

    (let ((gateway (make-gateway :port gateway-port
                                 :bind gateway-bind)))
      ;; Start gateway
      (start-gateway gateway)
      (setf *lisp-claw-start-time* (get-universal-time))
      (setf *lisp-claw-running-p* t)

      (format t "~%")
      (format t "Gateway started on ~A:~A~%" gateway-bind gateway-port)
      (format t "Press Ctrl+C to stop~%")
      (format t "~%")

      ;; Main loop
      (unwind-protect
           (if daemon-p
               ;; Daemon mode: just sleep
               (loop do (sleep 60))
               ;; Interactive mode
               (progn
                 (format t "Commands: status, stop, restart, help~%")
                 (loop
                   (let ((input (read-line nil nil nil)))
                     (when input
                       (let ((cmd (string-downcase (string-trim " " input))))
                         (cond
                           ((string= cmd "status")
                            (print-status))
                           ((string= cmd "stop")
                            (return))
                           ((string= cmd "restart")
                            (restart-gateway gateway))
                           ((string= cmd "help")
                            (print-help))
                           (t
                            (format t "Unknown command: ~A~%" cmd))))))))
            ;; Cleanup on exit
            (stop-gateway gateway)
            (setf *lisp-claw-running-p* nil)))))

  nil)

(defun start (&key config port bind)
  "Start Lisp-Claw gateway.

  Args:
    CONFIG: Configuration file path
    PORT: Gateway port
    BIND: Gateway bind address

  Returns:
    T on success"
  (run :config config :port port :bind bind :daemon-p t))

(defun stop ()
  "Stop Lisp-Claw gateway.

  Returns:
    T on success"
  (when *lisp-claw-running-p*
    (setf *lisp-claw-running-p* nil)
    (stop-gateway *gateway*)
    (log-info "Lisp-Claw stopped")
    t))

(defun restart ()
  "Restart Lisp-Claw gateway.

  Returns:
    T on success"
  (stop)
  (sleep 1)
  (run))

;;; ============================================================================
;;; Utility Functions
;;; ============================================================================

(defun print-status ()
  "Print current status."
  (format t "~%=== Lisp-Claw Status ===~%")
  (format t "Version: ~A~%" *lisp-claw-version*)
  (format t "Running: ~A~%*lisp-claw-running-p*)
  (format t "Uptime: ~A seconds~%"
          (if *lisp-claw-start-time*
              (- (get-universal-time) *lisp-claw-start-time*)
              0))
  (let ((health (get-health-status)))
    (format t "Health: ~A~%" (json-get health :status))
    (format t "Clients: ~A~%" (json-get health :clients))
    (format t "Memory: ~A~%" (json-get health :memory)))
  (format t "~%"))

(defun print-help ()
  "Print help information."
  (format t "~%Available commands:~%")
  (format t "  status  - Show current status~%")
  (format t "  stop    - Stop the gateway~%")
  (format t "  restart - Restart the gateway~%")
  (format t "  help    - Show this help~%")
  (format t "~%"))

;;; ============================================================================
;;; REPL Entry Point
;;; ============================================================================

(defun repl ()
  "Start Lisp-Claw in REPL mode.

  Returns:
    NIL"
  (init-subsystems)
  (format t "Lisp-Claw ~A REPL mode~%" *lisp-claw-version*)
  (format t "Use (lisp-claw.main:start) to start the gateway~%")
  (format t "Use (lisp-claw.main:stop) to stop~%")
  nil)
