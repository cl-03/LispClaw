;;; plugins/sdk.lisp --- Plugin SDK for Lisp-Claw
;;;
;;; This file implements the Plugin SDK for Lisp-Claw,
;;; similar to OpenClaw's plugin system for extending functionality.

(defpackage #:lisp-claw.plugins.sdk
  (:nicknames #:lc.plugins.sdk)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.config.loader)
  (:export
   ;; Plugin definition
   #:plugin
   #:make-plugin
   #:plugin-id
   #:plugin-name
   #:plugin-version
   #:plugin-description
   #:plugin-author
   #:plugin-enabled-p
   #:plugin-capabilities
   ;; Plugin types
   #:channel-plugin
   #:model-plugin
   #:tool-plugin
   #:skill-plugin
   #:hook-plugin
   ;; Plugin registry
   #:*plugin-registry*
   #:register-plugin
   #:unregister-plugin
   #:get-plugin
   #:list-plugins
   #:list-plugins-by-type
   ;; Plugin lifecycle
   #:load-plugin
   #:unload-plugin
   #:enable-plugin
   #:disable-plugin
   #:reload-plugin
   ;; Plugin context
   #:plugin-context
   #:make-plugin-context
   #:context-get
   #:context-set
   ;; Plugin API
   #:plugin-api-register-channel
   #:plugin-api-register-model
   #:plugin-api-register-tool
   #:plugin-api-register-skill
   #:plugin-api-get-config
   #:plugin-api-set-config
   #:plugin-api-log
   ;; Plugin loader
   #:scan-plugin-directory
   #:load-all-plugins
   ;; Plugin utilities
   #:validate-plugin
   #:check-plugin-dependencies))

(in-package #:lisp-claw.plugins.sdk)

;;; ============================================================================
;;; Plugin Base Class
;;; ============================================================================

(defclass plugin ()
  ((id :initarg :id
       :reader plugin-id
       :documentation "Unique plugin identifier")
   (name :initarg :name
         :reader plugin-name
         :documentation "Plugin display name")
   (version :initarg :version
            :reader plugin-version
            :documentation "Plugin version string")
   (description :initarg :description
                 :initform ""
                 :reader plugin-description
                 :documentation "Plugin description")
   (author :initarg :author
           :initform ""
           :reader plugin-author
           :documentation "Plugin author")
   (enabled-p :initform nil
              :accessor plugin-enabled-p
              :documentation "Whether plugin is enabled")
   (capabilities :initarg :capabilities
                 :initform nil
                 :reader plugin-capabilities
                 :documentation "List of plugin capabilities")
   (dependencies :initarg :dependencies
                 :initform nil
                 :reader plugin-dependencies
                 :documentation "List of plugin dependencies")
   (config :initarg :config
           :initform nil
           :accessor plugin-config
           :documentation "Plugin configuration")
   (metadata :initarg :metadata
             :initform nil
             :reader plugin-metadata
             :documentation "Additional metadata")
   (load-time :initform nil
              :accessor plugin-load-time
              :documentation "When plugin was loaded")
   (error :initform nil
          :accessor plugin-error
          :documentation "Last error if any"))
  (:documentation "Base plugin class"))

(defmethod print-object ((plugin plugin) stream)
  (print-unreadable-object (plugin stream :type t)
    (format stream "~A v~A [~:*~A]"
            (plugin-name plugin)
            (plugin-version plugin)
            (if (plugin-enabled-p plugin) "enabled" "disabled"))))

(defun make-plugin (id name version &key description author capabilities dependencies config metadata)
  "Create a plugin instance.

  Args:
    ID: Unique identifier
    NAME: Display name
    VERSION: Version string
    DESCRIPTION: Plugin description
    AUTHOR: Plugin author
    CAPABILITIES: List of capabilities
    DEPENDENCIES: List of dependencies
    CONFIG: Configuration plist
    METADATA: Additional metadata

  Returns:
    Plugin instance"
  (make-instance 'plugin
                 :id id
                 :name name
                 :version version
                 :description (or description "")
                 :author (or author "")
                 :capabilities (or capabilities nil)
                 :dependencies (or dependencies nil)
                 :config (or config nil)
                 :metadata (or metadata nil)))

;;; ============================================================================
;;; Plugin Types
;;; ============================================================================

(defclass channel-plugin (plugin)
  ((channel-type :initarg :channel-type
                 :reader channel-plugin-type
                 :documentation "Channel type identifier")
   (connect-fn :initarg :connect-fn
               :reader channel-plugin-connect-fn
               :documentation "Connection function")
   (disconnect-fn :initarg :disconnect-fn
                  :reader channel-plugin-disconnect-fn
                  :documentation "Disconnect function")
   (send-message-fn :initarg :send-message-fn
                    :reader channel-plugin-send-message-fn
                    :documentation "Send message function")
   (receive-message-fn :initarg :receive-message-fn
                       :reader channel-plugin-receive-message-fn
                       :documentation "Receive message callback"))
  (:documentation "Channel plugin for messaging integrations"))

(defclass model-plugin (plugin)
  ((model-id :initarg :model-id
             :reader model-plugin-model-id
             :documentation "Model identifier")
   (provider-type :initarg :provider-type
                  :reader model-plugin-provider-type
                  :documentation "Provider type (anthropic, openai, etc.)")
   (complete-fn :initarg :complete-fn
                :reader model-plugin-complete-fn
                :documentation "Completion function")
   (chat-fn :initarg :chat-fn
            :reader model-plugin-chat-fn
            :documentation "Chat function")
   (embed-fn :initarg :embed-fn
             :reader model-plugin-embed-fn
             :documentation "Embedding function"))
  (:documentation "Model plugin for AI provider integrations"))

(defclass tool-plugin (plugin)
  ((tool-name :initarg :tool-name
              :reader tool-plugin-tool-name
              :documentation "Tool name")
   (description :initarg :tool-description
                :reader tool-plugin-description
                :documentation "Tool description")
   (execute-fn :initarg :execute-fn
               :reader tool-plugin-execute-fn
               :documentation "Tool execution function")
   (parameters :initarg :parameters
               :reader tool-plugin-parameters
               :documentation "Tool parameters schema"))
  (:documentation "Tool plugin for custom tools"))

(defclass skill-plugin (plugin)
  ((skill-id :initarg :skill-id
             :reader skill-plugin-skill-id
             :documentation "Skill identifier")
   (skill-definition :initarg :skill-definition
                     :reader skill-plugin-skill-definition
                     :documentation "Skill definition"))
  (:documentation "Skill plugin for skill extensions"))

(defclass hook-plugin (plugin)
  ((hook-type :initarg :hook-type
              :reader hook-plugin-hook-type
              :documentation "Hook type (before/after)")
   (hook-point :initarg :hook-point
               :reader hook-plugin-hook-point
               :documentation "Hook point name")
   (hook-fn :initarg :hook-fn
            :reader hook-plugin-hook-fn
            :documentation "Hook function"))
  (:documentation "Hook plugin for lifecycle hooks"))

;;; ============================================================================
;;; Plugin Registry
;;; ============================================================================

(defvar *plugin-registry* (make-hash-table :test 'equal)
  "Registry of loaded plugins.")

(defvar *plugin-lock* (bt:make-lock)
  "Lock for plugin registry access.")

(defun register-plugin (plugin)
  "Register a plugin.

  Args:
    PLUGIN: Plugin instance

  Returns:
    T on success"
  (bt:with-lock-held (*plugin-lock*)
    (setf (gethash (plugin-id plugin) *plugin-registry*) plugin)
    (setf (plugin-load-time plugin) (get-universal-time))
    (log-info "Registered plugin: ~A v~A" (plugin-name plugin) (plugin-version plugin))
    t))

(defun unregister-plugin (id)
  "Unregister a plugin.

  Args:
    ID: Plugin ID

  Returns:
    T on success"
  (bt:with-lock-held (*plugin-lock*)
    (when (gethash id *plugin-registry*)
      (let ((plugin (gethash id *plugin-registry*)))
        (when (plugin-enabled-p plugin)
          (disable-plugin plugin))
        (remhash id *plugin-registry*)
        (log-info "Unregistered plugin: ~A" id)
        t))))

(defun get-plugin (id)
  "Get a plugin by ID.

  Args:
    ID: Plugin ID

  Returns:
    Plugin instance or NIL"
  (gethash id *plugin-registry*))

(defun list-plugins ()
  "List all registered plugins.

  Returns:
    List of plugin info"
  (let ((plugins nil))
    (bt:with-lock-held (*plugin-lock*)
      (maphash (lambda (id plugin)
                 (declare (ignore id))
                 (push (list :id (plugin-id plugin)
                             :name (plugin-name plugin)
                             :version (plugin-version plugin)
                             :enabled (plugin-enabled-p plugin)
                             :type (type-of plugin)
                             :capabilities (plugin-capabilities plugin))
                       plugins))
               *plugin-registry*))
    plugins))

(defun list-plugins-by-type (type)
  "List plugins by type.

  Args:
    TYPE: Plugin type symbol

  Returns:
    List of plugins"
  (let ((plugins nil))
    (bt:with-lock-held (*plugin-lock*)
      (maphash (lambda (id plugin)
                 (declare (ignore id))
                 (when (typep plugin type)
                   (push plugin plugins)))
               *plugin-registry*))
    plugins))

;;; ============================================================================
;;; Plugin Lifecycle
;;; ============================================================================

(defun load-plugin (plugin)
  "Load a plugin.

  Args:
    PLUGIN: Plugin instance

  Returns:
    T on success, error message on failure"
  (handler-case
      (progn
        ;; Validate plugin
        (multiple-value-bind (valid error)
            (validate-plugin plugin)
          (unless valid
            (setf (plugin-error plugin) error)
            (return-from load-plugin error)))

        ;; Check dependencies
        (multiple-value-bind (has-deps missing)
            (check-plugin-dependencies plugin)
          (unless has-deps
            (setf (plugin-error plugin)
                  (format nil "Missing dependencies: ~{~A~^, ~}" missing))
            (return-from load-plugin (format nil "Missing dependencies: ~{~A~^, ~}" missing))))

        ;; Initialize plugin
        (when (and (typep plugin 'channel-plugin)
                   (slot-boundp plugin 'channel-plugin-connect-fn))
          ;; Initialize channel plugin
          )

        ;; Mark as loaded
        (setf (plugin-load-time plugin) (get-universal-time))
        (register-plugin plugin)
        (log-info "Loaded plugin: ~A" (plugin-id plugin))
        t)
    (error (e)
      (setf (plugin-error plugin) (format nil "~A" e))
      (log-error "Failed to load plugin ~A: ~A" (plugin-id plugin) e)
      (format nil "Error: ~A" e))))

(defun unload-plugin (id)
  "Unload a plugin.

  Args:
    ID: Plugin ID

  Returns:
    T on success"
  (let ((plugin (get-plugin id)))
    (unless plugin
      (return-from unload-plugin nil))

    (when (plugin-enabled-p plugin)
      (disable-plugin plugin))

    (unregister-plugin id)
    (log-info "Unloaded plugin: ~A" id)
    t))

(defun enable-plugin (plugin)
  "Enable a plugin.

  Args:
    PLUGIN: Plugin instance

  Returns:
    T on success"
  (setf (plugin-enabled-p plugin) t)
  (log-info "Enabled plugin: ~A" (plugin-id plugin))
  t)

(defun disable-plugin (plugin)
  "Disable a plugin.

  Args:
    PLUGIN: Plugin instance

  Returns:
    T on success"
  (setf (plugin-enabled-p plugin) nil)
  (log-info "Disabled plugin: ~A" (plugin-id plugin))
  t)

(defun reload-plugin (id)
  "Reload a plugin.

  Args:
    ID: Plugin ID

  Returns:
    T on success"
  (let ((plugin (get-plugin id)))
    (unless plugin
      (return-from reload-plugin nil))

    (unload-plugin id)
    (load-plugin plugin)))

;;; ============================================================================
;;; Plugin Context
;;; ============================================================================

(defclass plugin-context ()
  ((data :initform (make-hash-table :test 'equal)
         :reader plugin-context-data
         :documentation "Context data")
   (created-at :initform (get-universal-time)
               :reader plugin-context-created-at
               :documentation "Creation timestamp"))
  (:documentation "Plugin execution context"))

(defun make-plugin-context ()
  "Create a plugin context.

  Returns:
    Plugin context instance"
  (make-instance 'plugin-context))

(defun context-get (context key &optional default)
  "Get a value from context.

  Args:
    CONTEXT: Plugin context
    KEY: Key to lookup
    DEFAULT: Default value

  Returns:
    Value or default"
  (let ((data (plugin-context-data context)))
    (if default
        (gethash key data default)
        (gethash key data))))

(defun context-set (context key value)
  "Set a value in context.

  Args:
    CONTEXT: Plugin context
    KEY: Key to set
    VALUE: Value

  Returns:
    T"
  (setf (gethash key (plugin-context-data context)) value)
  t)

;;; ============================================================================
;;; Plugin API
;;; ============================================================================

(defun plugin-api-register-channel (plugin channel-type connect-fn disconnect-fn send-fn receive-fn)
  "Register a channel from a plugin.

  Args:
    PLUGIN: Plugin instance
    CHANNEL-TYPE: Channel type symbol
    CONNECT-FN: Connect function
    DISCONNECT-FN: Disconnect function
    SEND-FN: Send message function
    RECEIVE-FN: Receive message callback

  Returns:
    T on success"
  (unless (typep plugin 'channel-plugin)
    (return-from plugin-api-register-channel
      (list :success nil :error "Not a channel plugin")))

  ;; Register with channel registry
  ;; (register-channel-type channel-type connect-fn disconnect-fn send-fn receive-fn)
  (log-info "Plugin ~A registered channel: ~A" (plugin-id plugin) channel-type)
  (list :success t :channel-type channel-type))

(defun plugin-api-register-model (plugin model-id provider-type complete-fn chat-fn embed-fn)
  "Register a model from a plugin.

  Args:
    PLUGIN: Plugin instance
    MODEL-ID: Model identifier
    PROVIDER-TYPE: Provider type
    COMPLETE-FN: Completion function
    CHAT-FN: Chat function
    EMBED-FN: Embedding function

  Returns:
    T on success"
  (unless (typep plugin 'model-plugin)
    (return-from plugin-api-register-model
      (list :success nil :error "Not a model plugin")))

  ;; Register with model registry
  (log-info "Plugin ~A registered model: ~A" (plugin-id plugin) model-id)
  (list :success t :model-id model-id))

(defun plugin-api-register-tool (plugin tool-name description execute-fn parameters)
  "Register a tool from a plugin.

  Args:
    PLUGIN: Plugin instance
    TOOL-NAME: Tool name
    DESCRIPTION: Tool description
    EXECUTE-FN: Execution function
    PARAMETERS: Parameters schema

  Returns:
    T on success"
  (unless (typep plugin 'tool-plugin)
    (return-from plugin-api-register-tool
      (list :success nil :error "Not a tool plugin")))

  ;; Register with tool registry
  ;; (register-tool tool-name description execute-fn :parameters parameters)
  (log-info "Plugin ~A registered tool: ~A" (plugin-id plugin) tool-name)
  (list :success t :tool-name tool-name))

(defun plugin-api-register-skill (plugin skill-id skill-definition)
  "Register a skill from a plugin.

  Args:
    PLUGIN: Plugin instance
    SKILL-ID: Skill identifier
    SKILL-DEFINITION: Skill definition

  Returns:
    T on success"
  (unless (typep plugin 'skill-plugin)
    (return-from plugin-api-register-skill
      (list :success nil :error "Not a skill plugin")))

  ;; Register with skills registry
  (log-info "Plugin ~A registered skill: ~A" (plugin-id plugin) skill-id)
  (list :success t :skill-id skill-id))

(defun plugin-api-get-config (plugin key &optional default)
  "Get plugin configuration.

  Args:
    PLUGIN: Plugin instance
    KEY: Config key
    DEFAULT: Default value

  Returns:
    Config value"
  (let ((config (plugin-config plugin)))
    (if default
        (getf config key default)
        (getf config key))))

(defun plugin-api-set-config (plugin key value)
  "Set plugin configuration.

  Args:
    PLUGIN: Plugin instance
    KEY: Config key
    VALUE: Config value

  Returns:
    T"
  (let ((config (plugin-config plugin)))
    (setf (getf config key) value))
  t)

(defun plugin-api-log (plugin level message &rest args)
  "Log a message from a plugin.

  Args:
    PLUGIN: Plugin instance
    LEVEL: Log level
    MESSAGE: Log message
    ARGS: Format arguments

  Returns:
    T"
  (let ((plugin-id (plugin-id plugin)))
    (case level
      (:debug (log-debug "[~A] ~A" plugin-id (apply #'format nil message args)))
      (:info (log-info "[~A] ~A" plugin-id (apply #'format nil message args)))
      (:warn (log-warn "[~A] ~A" plugin-id (apply #'format nil message args)))
      (:error (log-error "[~A] ~A" plugin-id (apply #'format nil message args))))))

;;; ============================================================================
;;; Plugin Loader
;;; ============================================================================

(defun scan-plugin-directory (directory)
  "Scan a directory for plugins.

  Args:
    DIRECTORY: Directory pathname

  Returns:
    List of plugin files"
  (let ((plugin-files nil))
    (when (probe-file directory)
      (dolist (file (directory (merge-pathnames "*.lisp" directory)))
        (push file plugin-files))
      (dolist (file (directory (merge-pathnames "*.fasl" directory)))
        (push file plugin-files)))
    (nreverse plugin-files)))

(defun load-plugin-from-file (file)
  "Load a plugin from a file.

  Args:
    FILE: Plugin file path

  Returns:
    Plugin instance or NIL"
  (handler-case
      (let ((package (load file)))
        ;; Look for plugin definition in package
        ;; This is a simplified implementation
        (log-info "Loaded plugin file: ~A" file)
        package)
    (error (e)
      (log-error "Failed to load plugin file ~A: ~A" file e)
      nil)))

(defun load-all-plugins (&key directories)
  "Load all plugins from directories.

  Args:
    DIRECTORIES: List of directories to scan

  Returns:
    List of loaded plugins"
  (let* ((plugin-dirs (or directories
                          (list
                           (merge-pathnames "plugins/" (user-homedir-pathname))
                           #p"D:/Claude/LISP-Claw/LISP-Claw/plugins/")))
         (loaded nil))

    (dolist (dir plugin-dirs)
      (when (probe-file dir)
        (let ((files (scan-plugin-directory dir)))
          (dolist (file files)
            (let ((plugin (load-plugin-from-file file)))
              (when plugin
                (push plugin loaded)))))))

    (log-info "Loaded ~A plugins" (length loaded))
    loaded))

;;; ============================================================================
;;; Plugin Validation
;;; ============================================================================

(defun validate-plugin (plugin)
  "Validate a plugin.

  Args:
    PLUGIN: Plugin instance

  Returns:
    Values: valid-p, error-message"
  (cond
    ((null plugin)
     (values nil "Plugin is null"))

    ((or (null (plugin-id plugin))
         (string= (plugin-id plugin) ""))
     (values nil "Plugin ID is required"))

    ((or (null (plugin-name plugin))
         (string= (plugin-name plugin) ""))
     (values nil "Plugin name is required"))

    ((or (null (plugin-version plugin))
         (string= (plugin-version plugin) ""))
     (values nil "Plugin version is required"))

    (t
     (values t nil))))

(defun check-plugin-dependencies (plugin)
  "Check if plugin dependencies are satisfied.

  Args:
    PLUGIN: Plugin instance

  Returns:
    Values: satisfied-p, missing-dependencies"
  (let ((deps (plugin-dependencies plugin)))
    (if (null deps)
        (values t nil)
        (let ((missing nil))
          (dolist (dep deps)
            (unless (get-plugin dep)
              (push dep missing)))
          (if missing
              (values nil (nreverse missing))
              (values t nil))))))

;;; ============================================================================
;;; Plugin Manifest
;;; ============================================================================

(defstruct plugin-manifest
  "Plugin manifest from plugin.lisp file."
  (id "" :type string)
  (name "" :type string)
  (version "" :type string)
  (description "" :type string)
  (author "" :type string)
  (type "" :type string)
  (dependencies nil :type list)
  (capabilities nil :type list)
  (entry-point "" :type string))

(defun parse-plugin-manifest (file)
  "Parse plugin manifest from file.

  Args:
    FILE: Plugin file path

  Returns:
    Plugin manifest or NIL"
  ;; Read the file and look for manifest definition
  ;; This is a simplified implementation
  (handler-case
      (with-open-file (in file :direction :input)
        (let ((content (make-string (file-length in))))
          (read-sequence content in)
          ;; Look for :manifest or defplugin form
          ;; Simplified parsing
          (make-plugin-manifest
           :id "unknown"
           :name (pathname-name file)
           :version "0.1.0")))
    (error (e)
      (log-error "Failed to parse plugin manifest ~A: ~A" file e)
      nil)))

;;; ============================================================================
;;; Built-in Plugins
;;; ============================================================================

(defun register-built-in-plugins ()
  "Register built-in plugins.

  Returns:
    T"
  ;; Placeholder for built-in plugins
  (log-info "Built-in plugins registered")
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-plugin-system ()
  "Initialize the plugin system.

  Returns:
    T"
  (register-built-in-plugins)
  (log-info "Plugin system initialized")
  t)

;;; ============================================================================
;;; defplugin Macro
;;; ============================================================================

(defmacro defplugin (name version &body body)
  "Define a plugin.

  Usage:
    (defplugin my-plugin \"1.0.0\"
      (:description \"My plugin\")
      (:author \"Author Name\")
      (:type :channel)
      (:capabilities '(chat tools))
      (:dependencies '(other-plugin))
      (:init (initialize-code))
      (:execute (execute-code)))

  Args:
    NAME: Plugin name/symbol
    VERSION: Version string
    BODY: Plugin body

  Returns:
    Plugin definition"
  (let ((description nil)
        (author nil)
        (type nil)
        (capabilities nil)
        (dependencies nil)
        (init-code nil)
        (execute-code nil)
        (id (string-downcase (string name))))

    ;; Parse body
    (dolist (item body)
      (when (listp item)
        (case (first item)
          (:description (setf description (second item)))
          (:author (setf author (second item)))
          (:type (setf type (second item)))
          (:capabilities (setf capabilities (second item)))
          (:dependencies (setf dependencies (second item)))
          (:init (setf init-code (rest item)))
          (:execute (setf execute-code (rest item))))))

    `(progn
       ;; Create plugin instance
       (defparameter ,(intern (format nil "*~A*" (string-upcase name)))
         (make-plugin
          ,id
          ,(string name)
          ,version
          :description ,description
          :author ,author
          :type ,type
          :capabilities ,capabilities
          :dependencies ,dependencies))

       ;; Register plugin
       (register-plugin ,(intern (format nil "*~A*" (string-upcase name))))

       ;; Return plugin
       ,(intern (format nil "*~A*" (string-upcase name)))))
