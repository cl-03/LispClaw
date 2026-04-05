;;; plugins/loader.lisp --- Plugin Loader for Lisp-Claw
;;;
;;; This file implements the plugin loader mechanism for Lisp-Claw.

(defpackage #:lisp-claw.plugins.loader
  (:nicknames #:lc.plugins.loader)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.plugins.sdk)
  (:export
   ;; Plugin loader
   #:plugin-loader
   #:make-plugin-loader
   #:loader-plugin-directory
   #:loader-auto-load
   ;; Loading functions
   #:load-plugin-file
   #:unload-plugin-file
   #:reload-plugin-file
   ;; Plugin discovery
   #:discover-plugins
   #:parse-plugin-info
   ;; Plugin installation
   #:install-plugin
   #:uninstall-plugin
   #:list-installed-plugins
   ;; Plugin repository
   #:add-plugin-repository
   #:remove-plugin-repository
   #:list-plugin-repositories
   #:search-plugin-repository))

(in-package #:lisp-claw.plugins.loader)

;;; ============================================================================
;;; Plugin Loader
;;; ============================================================================

(defclass plugin-loader ()
  ((plugin-directory :initarg :plugin-directory
                     :initform (merge-pathnames "plugins/" (user-homedir-pathname))
                     :accessor loader-plugin-directory
                     :documentation "Directory to load plugins from")
   (auto-load-p :initarg :auto-load
                :initform t
                :accessor loader-auto-load
                :documentation "Whether to auto-load plugins")
   (loaded-plugins :initform (make-hash-table :test 'equal)
                   :accessor loader-loaded-plugins
                   :documentation "Map of loaded plugins")
   (repositories :initform (list "https://plugins.lisp-claw.org")
                 :accessor loader-repositories
                 :documentation "Plugin repositories")
   (lock :initform (bt:make-lock)
         :reader loader-lock
         :documentation "Lock for thread safety"))
  (:documentation "Plugin loader"))

(defmethod print-object ((loader plugin-loader) stream)
  (print-unreadable-object (loader stream :type t)
    (format stream "~A [~A plugins]"
            (loader-plugin-directory loader)
            (hash-table-count (loader-loaded-plugins loader)))))

(defun make-plugin-loader (&key plugin-directory auto-load)
  "Create a plugin loader.

  Args:
    PLUGIN-DIRECTORY: Directory to load plugins from
    AUTO-LOAD: Whether to auto-load plugins

  Returns:
    Plugin loader instance"
  (make-instance 'plugin-loader
                 :plugin-directory (or plugin-directory
                                       (merge-pathnames "plugins/" (user-homedir-pathname)))
                 :auto-load (or auto-load t)))

;;; ============================================================================
;;; Plugin Loading
;;; ============================================================================

(defun load-plugin-file (file &key loader)
  "Load a plugin from a file.

  Args:
    FILE: Plugin file path
    LOADER: Optional plugin loader

  Returns:
    Plugin instance or NIL"
  (let ((loader (or loader *plugin-loader*)))
    (unless (probe-file file)
      (log-error "Plugin file not found: ~A" file)
      (return-from load-plugin-file nil))

    (bt:with-lock-held ((loader-lock loader))
      (handler-case
          (progn
            ;; Load the file
            (let ((package (load file)))
              (when package
                ;; Get plugin from package
                (let ((plugin (get-plugin-from-package package file)))
                  (when plugin
                    ;; Register and enable
                    (register-plugin plugin)
                    (enable-plugin plugin)
                    (setf (gethash (plugin-id plugin)
                                   (loader-loaded-plugins loader))
                          plugin)
                    (log-info "Loaded plugin: ~A from ~A" (plugin-id plugin) file)
                    plugin)))))
        (error (e)
          (log-error "Failed to load plugin ~A: ~A" file e)
          nil)))))

(defun get-plugin-from-package (package file)
  "Extract plugin from loaded package.

  Args:
    PACKAGE: Loaded package
    FILE: Source file

  Returns:
    Plugin instance or NIL"
  ;; Look for plugin definition in package
  ;; This is a simplified implementation
  (let ((plugin-name (pathname-name file)))
    ;; Check for manifest file
    (let ((manifest-file (merge-pathnames
                          (make-pathname :name "plugin" :type "json")
                          (directory-namestring file))))
      (when (probe-file manifest-file)
        (let ((manifest (parse-plugin-manifest-file manifest-file)))
          (when manifest
            (return-from get-plugin-from-package
              (manifest-to-plugin manifest))))))

    ;; Create default plugin
    (make-plugin plugin-name plugin-name "0.1.0"
                 :description (format nil "Plugin: ~A" plugin-name)))))

(defun unload-plugin-file (plugin-id &key loader)
  "Unload a plugin.

  Args:
    PLUGIN-ID: Plugin ID
    LOADER: Optional plugin loader

  Returns:
    T on success"
  (let ((loader (or loader *plugin-loader*)))
    (bt:with-lock-held ((loader-lock loader))
      (let ((plugin (gethash plugin-id (loader-loaded-plugins loader))))
        (when plugin
          (unregister-plugin plugin-id)
          (remhash plugin-id (loader-loaded-plugins loader))
          (log-info "Unloaded plugin: ~A" plugin-id)
          t)))))

(defun reload-plugin-file (plugin-id &key loader)
  "Reload a plugin.

  Args:
    PLUGIN-ID: Plugin ID
    LOADER: Optional plugin loader

  Returns:
    T on success"
  (unload-plugin-file plugin-id :loader loader)
  ;; Re-load from stored path
  (let ((loader (or loader *plugin-loader*)))
    (let ((plugin (gethash plugin-id (loader-loaded-plugins loader))))
      (when plugin
        ;; Would need to store file path in plugin
        (log-info "Reload not fully implemented for: ~A" plugin-id)
        nil))))

;;; ============================================================================
;;; Plugin Discovery
;;; ============================================================================

(defun discover-plugins (&optional directory)
  "Discover plugins in a directory.

  Args:
    DIRECTORY: Directory to scan

  Returns:
    List of plugin info plists"
  (let ((dir (or directory
                 (merge-pathnames "plugins/" (user-homedir-pathname))))
        (plugins nil))

    (when (probe-file dir)
      ;; Scan for .lisp files
      (dolist (file (directory (merge-pathnames "*.lisp" dir)))
        (let ((info (parse-plugin-info file)))
          (when info
            (push info plugins))))

      ;; Scan for plugin directories (each with plugin.json)
      (dolist (subdir (directory (merge-pathnames "*/" dir)))
        (let ((manifest (merge-pathnames subdir "plugin.json")))
          (when (probe-file manifest)
            (let ((info (parse-plugin-manifest-file manifest)))
              (when info
                (push info plugins)))))))

    (nreverse plugins)))

(defun parse-plugin-info (file)
  "Parse plugin info from a file.

  Args:
    FILE: Plugin file

  Returns:
    Plugin info plist or NIL"
  (handler-case
      (let ((name (pathname-name file)))
        ;; Try to read first S-expression to find plugin definition
        (with-open-file (in file :direction :input)
          (let ((first-form (read in nil nil)))
            (when (and (listp first-form)
                       (eq (first first-form) 'defplugin))
              (list :id name
                    :name name
                    :file (namestring file)
                    :version (second first-form)))))

        ;; Fallback to basic info
        (list :id name
              :name name
              :file (namestring file)
              :version "unknown"))
    (error (e)
      (log-warn "Failed to parse plugin info ~A: ~A" file e)
      nil)))

(defun parse-plugin-manifest-file (file)
  "Parse plugin.json manifest file.

  Args:
    FILE: Manifest file path

  Returns:
    Manifest plist or NIL"
  (handler-case
      (with-open-file (in file :direction :input)
        (let ((content (make-string (file-length in))))
          (read-sequence content in)
          (parse-json content)))
    (error (e)
      (log-error "Failed to parse plugin manifest ~A: ~A" file e)
      nil)))

(defun manifest-to-plugin (manifest)
  "Convert manifest plist to plugin instance.

  Args:
    MANIFEST: Manifest plist

  Returns:
    Plugin instance"
  (make-plugin (getf manifest :id)
               (getf manifest :name)
               (getf manifest :version)
               :description (getf manifest :description)
               :author (getf manifest :author)
               :capabilities (getf manifest :capabilities)
               :dependencies (getf manifest :dependencies)
               :config (getf manifest :config)
               :metadata (list :type (getf manifest :type)
                               :entry-point (getf manifest :entry-point))))

;;; ============================================================================
;;; Plugin Installation
;;; ============================================================================

(defun install-plugin (plugin-id &key version source loader)
  "Install a plugin.

  Args:
    PLUGIN-ID: Plugin identifier
    VERSION: Specific version (latest if NIL)
    SOURCE: Source URL or path
    LOADER: Optional plugin loader

  Returns:
    Installation result plist"
  (let ((loader (or loader *plugin-loader*)))
    ;; Check if already installed
    (when (get-plugin plugin-id)
      (return-from install-plugin
        (list :success nil :error "Plugin already installed")))

    ;; Download or copy plugin
    (let ((plugin-file (merge-pathnames
                        (make-pathname :name plugin-id :type "lisp")
                        (loader-plugin-directory loader))))
      (if source
          ;; Copy from source
          (handler-case
              (progn
                ;; Check if source is URL or local path
                (if (or (search "http://" source)
                        (search "https://" source))
                    ;; Download from URL
                    (let ((content (dex:get source)))
                      (ensure-directories-exist plugin-file)
                      (with-open-file (out plugin-file :direction :output
                                           :if-exists :supersede)
                        (write-string content out)))
                    ;; Copy from local path
                    (uiop:copy-file source plugin-file))

                (log-info "Installed plugin: ~A" plugin-id)
                (list :success t :plugin-id plugin-id :file (namestring plugin-file)))
            (error (e)
              (log-error "Failed to install plugin: ~A" e)
              (list :success nil :error (format nil "~A" e))))

          ;; Search repositories
          (search-and-install plugin-id version loader)))))

(defun search-and-install (plugin-id version loader)
  "Search repositories and install plugin.

  Args:
    PLUGIN-ID: Plugin ID
    VERSION: Version
    LOADER: Plugin loader

  Returns:
    Installation result"
  (dolist (repo (loader-repositories loader))
    ;; Search repository
    (let ((result (search-plugin-repository repo plugin-id)))
      (when result
        ;; Download and install
        (return-from search-and-install
          (install-plugin plugin-id
                          :version version
                          :source (getf result :download-url)
                          :loader loader)))))

  (list :success nil :error "Plugin not found in repositories"))

(defun uninstall-plugin (plugin-id &key loader)
  "Uninstall a plugin.

  Args:
    PLUGIN-ID: Plugin ID
    LOADER: Optional plugin loader

  Returns:
    T on success"
  (let ((loader (or loader *plugin-loader*)))
    ;; Unload if loaded
    (unload-plugin-file plugin-id :loader loader)

    ;; Delete file
    (let ((plugin-file (merge-pathnames
                        (make-pathname :name plugin-id :type "lisp")
                        (loader-plugin-directory loader))))
      (when (probe-file plugin-file)
        (delete-file plugin-file)
        (log-info "Uninstalled plugin: ~A" plugin-id)
        t))))

(defun list-installed-plugins (&key loader)
  "List all installed plugins.

  Args:
    LOADER: Optional plugin loader

  Returns:
    List of plugin info"
  (let ((loader (or loader *plugin-loader*)))
    (discover-plugins (loader-plugin-directory loader))))

;;; ============================================================================
;;; Plugin Repository
;;; ============================================================================

(defun add-plugin-repository (url &key loader)
  "Add a plugin repository.

  Args:
    URL: Repository URL
    LOADER: Optional plugin loader

  Returns:
    T"
  (let ((loader (or loader *plugin-loader*)))
    (pushnew url (loader-repositories loader) :test #'string=)
    (log-info "Added plugin repository: ~A" url)
    t))

(defun remove-plugin-repository (url &key loader)
  "Remove a plugin repository.

  Args:
    URL: Repository URL
    LOADER: Optional plugin loader

  Returns:
    T"
  (let ((loader (or loader *plugin-loader*)))
    (setf (loader-repositories loader)
          (remove url (loader-repositories loader) :test #'string=))
    (log-info "Removed plugin repository: ~A" url)
    t))

(defun list-plugin-repositories (&key loader)
  "List all plugin repositories.

  Args:
    LOADER: Optional plugin loader

  Returns:
    List of URLs"
  (let ((loader (or loader *plugin-loader*)))
    (loader-repositories loader)))

(defun search-plugin-repository (repository query)
  "Search a plugin repository.

  Args:
    REPOSITORY: Repository URL
    QUERY: Search query

  Returns:
    Plugin info or NIL"
  ;; Simplified implementation
  ;; In production, would make HTTP request to repository API
  (handler-case
      (let ((url (format nil "~A/api/search?q=~A" repository query)))
        (let ((response (dex:get url)))
          (parse-json response)))
    (error (e)
      (log-warn "Failed to search repository ~A: ~A" repository e)
      nil)))

;;; ============================================================================
;;; Global State
;;; ============================================================================

(defvar *plugin-loader* nil
  "Default plugin loader instance.")

(defun get-plugin-loader ()
  "Get or create the default plugin loader.

  Returns:
    Plugin loader instance"
  (or *plugin-loader*
      (setf *plugin-loader* (make-plugin-loader))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-plugin-loader ()
  "Initialize the plugin loader.

  Returns:
    T"
  (setf *plugin-loader* (make-plugin-loader))

  ;; Auto-load plugins if enabled
  (when (loader-auto-load *plugin-loader*)
    (load-all-plugins :directories (list (loader-plugin-directory *plugin-loader*))))

  (log-info "Plugin loader initialized")
  t)
