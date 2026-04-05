;;; config.lisp --- Configuration Loader for Lisp-Claw
;;;
;;; This file implements configuration loading and management
;;; for the Lisp-Claw system. Supports JSON configuration files.

(defpackage #:lisp-claw.config.loader
  (:nicknames #:lc.config.loader)
  (:use #:cl
        #:lisp-claw.utils.json
        #:lisp-claw.utils.helpers
        #:lisp-claw.utils.logging)
  (:export
   #:*config-path*
   #:*default-config*
   #:*current-config*
   #:load-config
   #:save-config
   #:get-config-value
   #:set-config-value
   #:merge-configs
   #:validate-config
   #:config-file-exists-p
   #:create-default-config))

(in-package #:lisp-claw.config.loader)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *config-path* nil
  "Path to the configuration file. If NIL, uses default location.
   Default: ~/.lisp-claw/lisp-claw.json")

(defvar *current-config* nil
  "Currently loaded configuration.")

(defvar *default-config*
  '((:agent . ((:model . "anthropic/claude-opus-4-6")
               (:thinking-level . "medium")
               (:verbose-level . "normal")))
    (:gateway . ((:port . 18789)
                 (:bind . "127.0.0.1")
                 (:auth . ((:mode . "token")
                           (:token . nil)))
                 (:tailscale . ((:mode . "off")))))
    (:channels . ((:whatsapp . ((:enabled . nil)))
                  (:telegram . ((:enabled . nil)
                                (:bot-token . nil)))
                  (:discord . ((:enabled . nil)
                               (:token . nil)))
                  (:slack . ((:enabled . nil)
                             (:bot-token . nil)
                             (:app-token . nil)))))
    (:browser . ((:enabled . nil)
                 (:profile . nil)))
    (:logging . ((:level . "info")
                 (:file . nil))))
  "Default configuration template.")

;;; ============================================================================
;;; Configuration Paths
;;; ============================================================================

(defun get-default-config-path ()
  "Get the default configuration file path.

  Returns:
    Pathname to the default config file"
  (let ((home-dir (uiop:getenv "HOME")))
    (if home-dir
        (merge-pathnames (make-pathname :directory '(:relative ".lisp-claw")
                                        :name "lisp-claw"
                                        :type "json")
                         (pathname home-dir))
        ;; Fallback to current directory
        (merge-pathnames "lisp-claw.json" (uiop:getcwd)))))

(defun get-config-path ()
  "Get the current configuration file path.

  Returns:
    Pathname to the config file"
  (if *config-path*
      (pathname *config-path*)
      (get-default-config-path)))

;;; ============================================================================
;;; Configuration Loading
;;; ============================================================================

(defun load-config (&optional (path nil))
  "Load configuration from a file.

  Args:
    PATH: Optional path to config file (uses default if NIL)

  Returns:
    Configuration alist

  Signals:
    CONFIG-ERROR: If file cannot be read or parsed"
  (let* ((config-path (if path (pathname path) (get-config-path)))
         (config-dir (directory-namestring config-path)))
    ;; Ensure config directory exists
    (ensure-directory config-path)

    (if (file-exists-p config-path)
        (handler-case
            (let* ((content (read-file-contents config-path))
                   (config (parse-json content)))
              (when config
                (setf *current-config* (merge-configs *default-config* config))
                (log-info "Configuration loaded from ~A" config-path)
                *current-config*))
          (error (e)
            (log-error "Failed to load config: ~A" e)
            (error 'config-error :message (format nil "Failed to load config: ~A" e))))
        ;; Config file doesn't exist, create default
        (progn
          (log-info "Config file not found, creating default at ~A" config-path)
          (create-default-config config-path)
          (setf *current-config* *default-config*)))))

(defun load-config-from-string (json-string)
  "Load configuration from a JSON string.

  Args:
    JSON-STRING: JSON configuration string

  Returns:
    Configuration alist"
  (let ((config (parse-json json-string)))
    (setf *current-config* (merge-configs *default-config* config))
    *current-config*))

;;; ============================================================================
;;; Configuration Saving
;;; ============================================================================

(defun save-config (&optional (path nil) (config nil))
  "Save configuration to a file.

  Args:
    PATH: Optional path (uses current config path if NIL)
    CONFIG: Optional config to save (uses current config if NIL)

  Returns:
    T on success

  Signals:
    CONFIG-ERROR: If file cannot be written"
  (let* ((config-path (if path (pathname path) (get-config-path)))
         (config-to-save (or config *current-config*)))
    (handler-case
        (progn
          (ensure-directory config-path)
          (write-file-contents config-path
                               (stringify-json config-to-save t))
          (log-info "Configuration saved to ~A" config-path)
          t)
      (error (e)
        (log-error "Failed to save config: ~A" e)
        (error 'config-error :message (format nil "Failed to save config: ~A" e))))))

(defun create-default-config (&optional (path nil))
  "Create a default configuration file.

  Args:
    PATH: Optional path (uses default if NIL)

  Returns:
    T on success"
  (let ((config-path (if path (pathname path) (get-default-config-path))))
    (save-config config-path *default-config*)))

;;; ============================================================================
;;; Configuration Access
;;; ============================================================================

(defun get-config-value (&rest keys)
  "Get a configuration value using a path of keys.

  Args:
    KEYS: A sequence of keys to traverse

  Returns:
    The value at the specified path, or NIL if not found

  Example:
    (get-config-value :gateway :port) => 18789"
  (unless *current-config*
    (load-config))

  (loop with result = *current-config*
        for key in keys
        do (setf result (json-get result key))
        while result
        finally (return result)))

(defun set-config-value (value &rest keys)
  "Set a configuration value using a path of keys.

  Args:
    VALUE: The value to set
    KEYS: A sequence of keys to traverse

  Returns:
    The new configuration

  Example:
    (set-config-value 18790 :gateway :port)"
  (unless *current-config*
    (load-config))

  (setf *current-config*
        (set-nested-value *current-config* value keys))
  *current-config*)

(defun set-nested-value (config value keys)
  "Set a nested value in an alist.

  Args:
    CONFIG: Configuration alist
    VALUE: Value to set
    KEYS: List of keys to traverse

  Returns:
    New configuration alist"
  (cond
    ((null keys) value)
    ((null (rest keys))
     ;; Last key, set the value
     (let ((key (first keys)))
       (cons (cons key value)
             (remove-if (lambda (pair)
                          (equal (car pair) key))
                        config))))
    (t
     ;; Recursive case
     (let* ((key (first keys))
            (existing (assoc key config :test #'equal))
            (rest-keys (rest keys)))
       (if existing
           ;; Key exists, update nested value
           (cons (cons key (set-nested-value (cdr existing) value rest-keys))
                 (remove-if (lambda (pair)
                              (equal (car pair) key))
                            config))
           ;; Key doesn't exist, create it
           (cons (cons key (set-nested-value '() value rest-keys))
                 config))))))

;;; ============================================================================
;;; Configuration Utilities
;;; ============================================================================

(defun merge-configs (default-config user-config)
  "Deep merge two configurations.

  Args:
    DEFAULT-CONFIG: Default configuration
    USER-CONFIG: User configuration (takes precedence)

  Returns:
    Merged configuration"
  (cond
    ((null default-config) user-config)
    ((null user-config) default-config)
    (t
     (let ((result (copy-tree default-config)))
       (dolist (pair user-config)
         (let ((key (car pair))
               (value (cdr pair))
               (existing (assoc key result :test #'equal)))
           (if (and existing
                    (alist-p (cdr existing))
                    (alist-p value))
               ;; Recursive merge for nested alists
               (setf (cdr existing)
                     (merge-configs (cdr existing) value))
               ;; Replace or add value
               (if existing
                   (setf (cdr existing) value)
                   (push (cons key value) result)))))
       result))))

(defun validate-config (config)
  "Validate a configuration.

  Args:
    CONFIG: Configuration to validate

  Returns:
    Values: (valid-p errors)
    - valid-p: T if config is valid
    - errors: List of error messages"
  (let ((errors nil))
    ;; Validate gateway port
    (let ((port (json-get* config :gateway :port)))
      (when (and port (not (and (integerp port)
                                (>= port 1)
                                (<= port 65535))))
        (push "Gateway port must be between 1 and 65535" errors)))

    ;; Validate gateway bind address
    (let ((bind (json-get* config :gateway :bind)))
      (when (and bind
                 (not (member bind '("127.0.0.1" "0.0.0.0" "::1" "::")
                               :test #'string=)))
        (push "Gateway bind must be 127.0.0.1, 0.0.0.0, ::1, or ::" errors)))

    ;; Validate auth mode
    (let ((auth-mode (json-get* config :gateway :auth :mode)))
      (when (and auth-mode
                 (not (member auth-mode '("none" "token" "password")
                               :test #'string=)))
        (push "Auth mode must be none, token, or password" errors)))

    ;; Return results
    (values (null errors) (nreverse errors))))

(defun config-file-exists-p ()
  "Check if the configuration file exists.

  Returns:
    T if file exists, NIL otherwise"
  (file-exists-p (get-config-path)))

;;; ============================================================================
;;; Conditions
;;; ============================================================================

(define-condition config-error (error)
  ((message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "Configuration Error: ~A"
                     (error-message condition)))))
