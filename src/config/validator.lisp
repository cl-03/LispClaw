;;; config/validator.lisp --- Configuration Validator for Lisp-Claw
;;;
;;; This file provides configuration validation and migration tools.

(defpackage #:lisp-claw.config.validator
  (:nicknames #:lc.config.validator)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.config.schema)
  (:export
   ;; Validation
   #:validate-config
   #:validate-config-file
   #:get-validation-errors
   #:fix-config
   ;; Schema operations
   #:get-config-schema
   #:validate-against-schema
   ;; Migration
   #:migrate-config
   #:get-latest-config-version
   ;; Backup
   #:backup-config
   #:restore-config
   ;; Utils
   #:generate-sample-config
   #:print-config-summary))

(in-package #:lisp-claw.config.validator)

;;; ============================================================================
;;; Configuration Schema
;;; ============================================================================

(defvar *config-schema*
  (list
   ;; Gateway configuration
   (list :key :gateway
         :type :object
         :required t
         :properties (list
                      (list :key :port :type :string :required t)
                      (list :key :bind :type :string :required t)
                      (list :key :max-connections :type :integer :default "1000")
                      (list :key :timeout :type :integer :default "300")))

   ;; Logging configuration
   (list :key :logging
         :type :object
         :required t
         :properties (list
                      (list :key :level :type :string :required t
                            :allowed-values '("debug" "info" "warning" "error"))
                      (list :key :file :type :string :required t)
                      (list :key :format :type :string :default "json")
                      (list :key :max-size :type :string :default "10MB")
                      (list :key :max-files :type :integer :default "5")))

   ;; Agent configuration
   (list :key :agent
         :type :object
         :required t
         :properties (list
                      (list :key :default-provider :type :string :required t)
                      (list :key :max-tokens :type :integer :default "4096")
                      (list :key :temperature :type :float :default "0.7")
                      (list :key :timeout :type :integer :default "60")))

   ;; Memory configuration
   (list :key :memory
         :type :object
         :required nil
         :properties (list
                      (list :key :type :type :string :default "hybrid")
                      (list :key :max-short-term :type :integer :default "100")
                      (list :key :max-long-term :type :integer :default "1000")))

   ;; Vector configuration
   (list :key :vector
         :type :object
         :required nil
         :properties (list
                      (list :key :enabled :type :boolean :default t)
                      (list :key :store :type :string :default "chromadb")
                      (list :key :embedding-model :type :string)))

   ;; Security configuration
   (list :key :security
         :type :object
         :required nil
         :properties (list
                      (list :key :rate-limit :type :object)
                      (list :key :audit :type :object))))
  "Configuration schema for validation.")

(defvar *config-versions*
  '((:version "0.1.0"
     :changes ())
    (:version "0.2.0"
     :changes ((:add :vector)
               (:add :security)))
    (:version "0.3.0"
     :changes ((:add :memory :compression)
               (:add :monitoring))))
  "Configuration version history for migration.")

(defvar *validation-errors* nil
  "List of validation errors from last validation.")

;;; ============================================================================
;;; Validation Functions
;;; ============================================================================

(defun validate-config (config &key strict)
  "Validate configuration.

  Args:
    CONFIG: Configuration plist
    STRICT: Strict mode (fail on warnings)

  Returns:
    T if valid, NIL otherwise"
  (let ((errors nil)
        (warnings nil))

    ;; Check required sections
    (dolist (section *config-schema*)
      (let ((key (getf section :key))
            (required (getf section :required))
            (properties (getf section :properties)))

        (when required
          (unless (getf config key)
            (push (list :type :error :message (format nil "Missing required section: ~A" key))
                  errors)))))

    ;; Validate gateway section
    (let ((gateway (getf config :gateway)))
      (when gateway
        ;; Validate port
        (let ((port (json-get gateway :port)))
          (unless (and port (stringp port) (every #'digit-char-p port))
            (push (list :type :error :message "Gateway port must be a string number") errors)))

        ;; Validate bind address
        (let ((bind (json-get gateway :bind)))
          (unless (and bind (stringp bind)
                       (or (string= bind "0.0.0.0")
                           (string= bind "127.0.0.1")
                           (valid-ip-p bind)))
            (push (list :type :error :message "Gateway bind must be a valid IP address") errors)))))

    ;; Validate logging section
    (let ((logging (getf config :logging)))
      (when logging
        (let ((level (json-get logging :level)))
          (unless (and level (member (string-downcase level) '("debug" "info" "warning" "error") :test #'string=))
            (push (list :type :warning :message "Invalid logging level, using default: info") warnings)))))

    ;; Validate agent section
    (let ((agent (getf config :agent)))
      (when agent
        (let ((provider (json-get agent :default-provider)))
          (unless (and provider (member (string-downcase provider)
                                        '("anthropic" "openai" "ollama" "groq" "xai" "google")
                                        :test #'string=))
            (push (list :type :error :message "Invalid default provider") errors)))

        ;; Validate temperature
        (let ((temp (json-get agent :temperature)))
          (when temp
            (let ((temp-float (handler-case (coerce temp 'float) (error nil))))
              (unless (and temp-float (>= temp-float 0.0) (<= temp-float 2.0))
                (push (list :type :warning :message "Temperature should be between 0.0 and 2.0") warnings)))))))

    ;; Store errors
    (setf *validation-errors* (append errors warnings))

    ;; Return result
    (if (null errors)
        (if strict (null warnings) t)
        nil))))

(defun validate-config-file (file-path)
  "Validate configuration file.

  Args:
    FILE-PATH: Path to configuration file

  Returns:
    T if valid, NIL otherwise"
  (handler-case
      (let ((config (load-config file-path)))
        (validate-config config))
    (error (e)
      (push (list :type :error :message (format nil "Failed to load config: ~A" e))
            *validation-errors*)
      nil))))

(defun get-validation-errors ()
  "Get validation errors from last validation.

  Returns:
    List of error plists"
  *validation-errors*))

(defun fix-config (config)
  "Fix common configuration issues.

  Args:
    CONFIG: Configuration plist

  Returns:
    Fixed configuration"
  ;; Fix gateway port
  (let ((gateway (getf config :gateway)))
    (when gateway
      (let ((port (json-get gateway :port)))
        (when (and port (not (every #'digit-char-p port)))
          (setf (gethash :port gateway) "18789")))))

  ;; Fix logging level
  (let ((logging (getf config :logging)))
    (when logging
      (let ((level (json-get logging :level)))
        (unless (and level (member (string-downcase level) '("debug" "info" "warning" "error") :test #'string=))
          (setf (gethash :level logging) "info")))))

  ;; Fix agent temperature
  (let ((agent (getf config :agent)))
    (when agent
      (let ((temp (json-get agent :temperature)))
        (when temp
          (let ((temp-float (handler-case (coerce temp 'float) (error nil))))
            (when (or (null temp-float) (< temp-float 0.0) (> temp-float 2.0))
              (setf (gethash :temperature agent) 0.7)))))))

  config))

;;; ============================================================================
;;; Helper Functions
;;; ============================================================================

(defun valid-ip-p (ip)
  "Check if IP address is valid.

  Args:
    IP: IP address string

  Returns:
    T if valid"
  (or (string= ip "0.0.0.0")
      (string= ip "127.0.0.1")
      (cl-ppcre:scan "^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$" ip)))

(defun validate-against-schema (config schema)
  "Validate configuration against schema.

  Args:
    CONFIG: Configuration plist
    SCHEMA: Schema plist

  Returns:
    T if valid, NIL otherwise"
  (let ((valid t))
    (dolist (field schema)
      (let ((key (getf field :key))
            (required (getf field :required))
            (type (getf field :type))
            (allowed (getf field :allowed-values)))

        (when required
          (unless (getf config key)
            (setf valid nil)
            (push (list :type :error :message (format nil "Missing required field: ~A" key))
                  *validation-errors*)))

        (when (and (getf config key) type)
          (let ((value (getf config key)))
            (unless (type-match-p value type)
              (setf valid nil)
              (push (list :type :error :message (format nil "Invalid type for ~A: expected ~A" key type))
                    *validation-errors*)))

          (when allowed
            (unless (member value allowed :test #'string=)
              (setf valid nil)
              (push (list :type :error :message (format nil "Invalid value for ~A: ~A" key value))
                    *validation-errors*))))))
    valid))

(defun type-match-p (value type)
  "Check if value matches type.

  Args:
    VALUE: Value to check
    TYPE: Expected type

  Returns:
    T if matches"
  (ecase type
    (:string (stringp value))
    (:integer (or (integerp value)
                  (and (stringp value) (every #'digit-char-p value))))
    (:float (or (floatp value) (integerp value)))
    (:boolean (member value '(t nil :true :false "true" "false")))
    (:object (or (hash-table-p value) (plistp value)))
    (:array (or (listp value) (vectorp value)))))

;;; ============================================================================
;;; Migration Functions
;;; ============================================================================

(defun get-latest-config-version ()
  "Get latest configuration version.

  Returns:
    Version string"
  (first (first *config-versions*)))

(defun migrate-config (config &key from-version to-version)
  "Migrate configuration between versions.

  Args:
    CONFIG: Configuration plist
    FROM-VERSION: Source version (auto-detect if NIL)
    TO-VERSION: Target version (latest if NIL)

  Returns:
    Migrated configuration"
  (let* ((current-version (or from-version "0.1.0"))
         (target-version (or to-version (get-latest-config-version)))
         (migrated config))

    ;; Apply migrations in order
    (dolist (version-info *config-versions*)
      (let ((version (getf version-info :version))
            (changes (getf version-info :changes)))

        (when (string> version current-version)
          (when (string<= version target-version)
            ;; Apply changes
            (dolist (change changes)
              (let ((action (first change))
                    (section (second change))
                    (subsection (third change)))

                (ecase action
                  (:add
                   (let ((section-data (getf migrated section)))
                     (unless section-data
                       (setf (gethash section migrated) (make-hash-table :test 'equal))))
                   (when subsection
                     (let ((section-data (getf migrated section)))
                       (unless (gethash subsection section-data)
                         (setf (gethash subsection section-data) (make-hash-table :test 'equal))))))

                  (:rename
                   ;; Handle rename
                   ))))

            (setf current-version version)))))

    migrated))

;;; ============================================================================
;;; Backup Functions
;;; ============================================================================

(defun backup-config (&key (backup-dir "~/lisp-claw/backups/"))
  "Backup current configuration.

  Args:
    BACKUP-DIR: Backup directory

  Returns:
    Backup file path"
  (let* ((config-dir (uiop:getenv "LISP_CLAW_CONFIG_DIR"))
         (config-file (merge-pathnames "config.json" (or config-dir "~/.lisp-claw/")))
         (backup-path (merge-pathnames
                       (format nil "config-backup-~A.json" (get-universal-time))
                       (uiop:ensure-directory-pathname backup-dir))))

    ;; Create backup directory
    (uiop:ensure-directory-pathname backup-dir)

    ;; Copy config file
    (uiop:copy-file config-file backup-path)

    (log-info "Configuration backed up to ~A" backup-path)
    backup-path))

(defun restore-config (backup-file)
  "Restore configuration from backup.

  Args:
    BACKUP-FILE: Backup file path

  Returns:
    T on success"
  (let* ((config-dir (uiop:getenv "LISP_CLAW_CONFIG_DIR"))
         (config-file (merge-pathnames "config.json" (or config-dir "~/.lisp-claw/"))))

    ;; Restore config file
    (uiop:copy-file backup-file config-file)

    (log-info "Configuration restored from ~A" backup-file)
    t))

;;; ============================================================================
;;; Utility Functions
;;; ============================================================================

(defun generate-sample-config ()
  "Generate sample configuration.

  Returns:
    Sample configuration plist"
  (list :gateway (list :port "18789"
                       :bind "127.0.0.1"
                       :max-connections "1000"
                       :timeout "300")
        :logging (list :level "info"
                       :file "~/.lisp-claw/logs/lisp-claw.log"
                       :format "json"
                       :max-size "10MB"
                       :max-files "5")
        :agent (list :default-provider "anthropic"
                     :max-tokens "4096"
                     :temperature "0.7"
                     :timeout "60")
        :memory (list :type "hybrid"
                      :max-short-term "100"
                      :max-long-term "1000")
        :vector (list :enabled t
                      :store "chromadb"
                      :embedding-model "text-embedding-ada-002")
        :security (list :rate-limit (list :enabled t
                                          :requests-per-minute "60")
                        :audit (list :enabled t
                                     :retention-days "90"))))

(defun print-config-summary ()
  "Print configuration summary.

  Returns:
    T"
  (let ((config (load-config)))
    (format t "~%=== Lisp-Claw Configuration Summary ===~%")
    (format t "~%Gateway:~%")
    (let ((gateway (getf config :gateway)))
      (format t "  Port: ~A~%" (json-get gateway :port))
      (format t "  Bind: ~A~%" (json-get gateway :bind))
      (format t "  Max Connections: ~A~%" (json-get gateway :max-connections)))

    (format t "~%Agent:~%")
    (let ((agent (getf config :agent)))
      (format t "  Default Provider: ~A~%" (json-get agent :default-provider))
      (format t "  Max Tokens: ~A~%" (json-get agent :max-tokens))
      (format t "  Temperature: ~A~%" (json-get agent :temperature)))

    (format t "~%Memory:~%")
    (let ((memory (getf config :memory)))
      (format t "  Type: ~A~%" (json-get memory :type))
      (format t "  Max Short-term: ~A~%" (json-get memory :max-short-term))
      (format t "  Max Long-term: ~A~%" (json-get memory :max-long-term)))

    (format t "~%Vector:~%")
    (let ((vector (getf config :vector)))
      (format t "  Enabled: ~A~%" (json-get vector :enabled))
      (format t "  Store: ~A~%" (json-get vector :store)))

    (format t "~%Security:~%")
    (let ((security (getf config :security)))
      (when security
        (format t "  Rate Limit: ~A~%" (if (json-get (json-get security :rate-limit) :enabled) "Enabled" "Disabled"))
        (format t "  Audit: ~A~%" (if (json-get (json-get security :audit) :enabled) "Enabled" "Disabled"))))

    (format t "~%"))
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-config-validator-system ()
  "Initialize configuration validator.

  Returns:
    T"
  (log-info "Configuration validator initialized")
  t)
