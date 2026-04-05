;;; skills/hub.lisp --- Skills Hub/Marketplace Integration for Lisp-Claw
;;;
;;; This file provides integration with a skills marketplace (similar to
;;; OpenClaw's ClawHub) for discovering, installing, and managing skills.

(defpackage #:lisp-claw.skills.hub
  (:nicknames #:lc.skills.hub)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.skills.registry)
  (:export
   ;; Hub client
   #:hub-client
   #:make-hub-client
   #:hub-client-url
   #:hub-client-api-key
   ;; Skills discovery
   #:list-available-skills
   #:search-skills
   #:get-skill-details
   #:get-skill-manifest
   ;; Installation
   #:install-skill
   #:uninstall-skill
   #:update-skill
   #:list-installed-skills
   ;; Categories
   #:list-skill-categories
   #:get-skills-by-category
   ;; Ratings
   #:get-skill-rating
   #:rate-skill
   ;; Featured & trending
   #:get-featured-skills
   #:get-trending-skills
   ;; Repository
   #:add-skill-repository
   #:remove-skill-repository
   #:list-skill-repositories))

(in-package #:lisp-claw.skills.hub)

;;; ============================================================================
;; Hub Client
;;; ============================================================================

(defclass hub-client ()
  ((url :initarg :url
        :initform "https://hub.lisp-claw.org"
        :reader hub-client-url
        :documentation "Skills hub URL")
   (api-key :initarg :api-key
            :accessor hub-client-api-key
            :documentation "API key for authenticated requests")
   (repositories :initform (list "https://hub.lisp-claw.org")
                 :accessor hub-client-repositories
                 :documentation "List of skill repositories")
   (cache :initform (make-hash-table :test 'equal)
          :accessor hub-client-cache
          :documentation "Response cache")
   (cache-ttl :initarg :cache-ttl
              :initform 3600
              :accessor hub-client-cache-ttl
              :documentation "Cache TTL in seconds"))
  (:documentation "Skills hub client"))

(defmethod print-object ((client hub-client) stream)
  (print-unreadable-object (client stream :type t)
    (format stream "~A" (hub-client-url client))))

(defun make-hub-client (&key (url "https://hub.lisp-claw.org") api-key cache-ttl)
  "Create a hub client.

  Args:
    URL: Hub URL
    API-KEY: API key for authenticated requests
    CACHE-TTL: Cache TTL in seconds

  Returns:
    Hub client instance"
  (make-instance 'hub-client
                 :url url
                 :api-key api-key
                 :cache-ttl (or cache-ttl 3600)))

;;; ============================================================================
;;; HTTP Helpers
;;; ============================================================================

(defun hub-request (client method path &key body params)
  "Make HTTP request to skills hub.

  Args:
    CLIENT: Hub client
    METHOD: HTTP method
    PATH: API path
    BODY: Request body (plist)
    PARAMS: Query parameters

  Returns:
    Response plist or NIL"
  (let* ((url (concatenate 'string
                           (hub-client-url client)
                           "/api/v1"
                           path))
         (headers (list (cons "Accept" "application/json")
                        (cons "Content-Type" "application/json")
                        (when (hub-client-api-key client)
                          (cons "Authorization"
                                (format nil "Bearer ~A" (hub-client-api-key client))))))
         (response nil))

    ;; Build URL with query params
    (when params
      (let ((query (format nil "~{~A=~A~^&~}"
                           (loop for (k . v) in params
                                 collect (cons k (url-encode (princ-to-string v)))))))
        (setf url (concatenate 'string url "?" query))))

    (handler-case
        (let ((response-text
               (case method
                 (:get (dex:get url :headers headers))
                 (:post (dex:post url
                                  :headers headers
                                  :content (when body (stringify-json body))))
                 (:put (dex:put url
                                :headers headers
                                :content (when body (stringify-json body))))
                 (:delete (dex:delete url :headers headers)))))
          (setf response (parse-json response-text))
          response)
      (error (e)
        (log-error "Hub request failed: ~A ~A - ~A" method path e)
        nil))))

(defun url-encode (string)
  "URL encode a string.

  Args:
    STRING: String to encode

  Returns:
    URL encoded string"
  ;; Simple implementation - in production use proper library
  (coerce
   (map 'list
        (lambda (c)
          (if (alphanumericp c)
              (coerce (string c) 'character)
              (code-char (parse-integer
                          (format nil "~2,'0X" (char-code c))))))
        string)
   'string))

;;; ============================================================================
;;; Skills Discovery
;;; ============================================================================

(defun list-available-skills (client &key category limit offset)
  "List available skills from the hub.

  Args:
    CLIENT: Hub client
    CATEGORY: Optional category filter
    LIMIT: Maximum results
    OFFSET: Result offset

  Returns:
    List of skill summaries"
  (let ((params (append (when limit `((:limit . ,limit)))
                        (when offset `((:offset . ,offset)))
                        (when category `((:category . ,category))))))
    (hub-request client :get "/skills" :params params)))

(defun search-skills (client query &key category tags limit)
  "Search for skills.

  Args:
    CLIENT: Hub client
    QUERY: Search query
    CATEGORY: Optional category filter
    TAGS: Optional tags filter
    LIMIT: Maximum results

  Returns:
    List of matching skills"
  (let ((params (append `((:q . ,query))
                        (when category `((:category . ,category)))
                        (when tags `((:tags . ,(format nil "~{~A~^,~}" tags))))
                        (when limit `((:limit . ,limit))))))
    (hub-request client :get "/skills/search" :params params)))

(defun get-skill-details (client skill-id)
  "Get detailed information about a skill.

  Args:
    CLIENT: Hub client
    SKILL-ID: Skill identifier

  Returns:
    Skill details plist"
  (hub-request client :get (format nil "/skills/~A" skill-id)))

(defun get-skill-manifest (client skill-id)
  "Get skill manifest/package.

  Args:
    CLIENT: Hub client
    SKILL-ID: Skill identifier

  Returns:
    Skill manifest plist"
  (hub-request client :get (format nil "/skills/~A/manifest" skill-id)))

;;; ============================================================================
;;; Installation Management
;;; ============================================================================

(defun install-skill (client skill-id &key version)
  "Install a skill from the hub.

  Args:
    CLIENT: Hub client
    SKILL-ID: Skill identifier
    VERSION: Specific version (default: latest)

  Returns:
    Installation result plist"
  (let* ((manifest (get-skill-manifest client skill-id))
         (source-url (getf manifest :sourceUrl))
         (dependencies (getf manifest :dependencies)))

    (unless manifest
      (return-from install-skill (list :success nil :error "Skill not found")))

    ;; Download skill source
    (let ((source-code (dex:get source-url)))
      (when source-code
        ;; Save to skills directory
        (let ((skill-path (format nil "~A/.lisp-claw/skills/~A.lisp"
                                  (user-homedir-pathname) skill-id)))
          (ensure-directories-exist skill-path)
          (with-open-file (out skill-path :direction :output
                               :if-exists :supersede)
            (write-string source-code out))

          ;; Load the skill
          (handler-case
              (load skill-path)
            (error (e)
              (return-from install-skill
                (list :success nil :error (format nil "Failed to load skill: ~A" e)))))

          ;; Register the skill
          (register-skill-from-manifest manifest)

          ;; Install dependencies
          (dolist (dep dependencies)
            (install-skill client dep))

          (log-info "Installed skill: ~A" skill-id)
          (list :success t :skill-id skill-id :version (getf manifest :version)))))))

(defun uninstall-skill (client skill-id)
  "Uninstall a skill.

  Args:
    CLIENT: Hub client (not used)
    SKILL-ID: Skill identifier

  Returns:
    Uninstallation result plist"
  (declare (ignore client))
  (let ((skill-path (format nil "~A/.lisp-claw/skills/~A.lisp"
                            (user-homedir-pathname) skill-id)))
    (when (probe-file skill-path)
      (delete-file skill-path)
      (unregister-skill skill-id)
      (log-info "Uninstalled skill: ~A" skill-id)
      (list :success t :skill-id skill-id))))

(defun update-skill (client skill-id)
  "Update an installed skill.

  Args:
    CLIENT: Hub client
    SKILL-ID: Skill identifier

  Returns:
    Update result plist"
  (uninstall-skill client skill-id)
  (install-skill client skill-id))

(defun list-installed-skills (client)
  "List all installed skills.

  Args:
    CLIENT: Hub client

  Returns:
    List of installed skill info"
  (declare (ignore client))
  (let ((skills-dir (format nil "~A/.lisp-claw/skills/" (user-homedir-pathname))))
    (if (probe-file skills-dir)
        (let ((installed nil))
          (dolist (file (directory (merge-pathnames "*.lisp" skills-dir)))
            (let ((skill-id (pathname-name file)))
              (push (list :id skill-id
                          :path (namestring file))
                    installed)))
          installed)
        nil)))

;;; ============================================================================
;;; Categories
;;; ============================================================================

(defun list-skill-categories (client)
  "List all skill categories.

  Args:
    CLIENT: Hub client

  Returns:
    List of categories"
  (hub-request client :get "/categories"))

(defun get-skills-by-category (client category &key limit)
  "Get skills in a specific category.

  Args:
    CLIENT: Hub client
    CATEGORY: Category name
    LIMIT: Maximum results

  Returns:
    List of skills"
  (list-available-skills client :category category :limit limit))

;;; ============================================================================
;;; Ratings & Reviews
;;; ============================================================================

(defun get-skill-rating (client skill-id)
  "Get rating information for a skill.

  Args:
    CLIENT: Hub client
    SKILL-ID: Skill identifier

  Returns:
    Rating info plist"
  (hub-request client :get (format nil "/skills/~A/rating" skill-id)))

(defun rate-skill (client skill-id rating &key review)
  "Rate a skill.

  Args:
    CLIENT: Hub client
    SKILL-ID: Skill identifier
    RATING: Rating (1-5)
    REVIEW: Optional review text

  Returns:
    Result plist"
  (unless (and (>= rating 1) (<= rating 5))
    (return-from rate-skill (list :success nil :error "Rating must be 1-5")))

  (hub-request client :post
               (format nil "/skills/~A/rating" skill-id)
               :body `(:rating ,rating :review ,review)))

;;; ============================================================================
;;; Featured & Trending
;;; ============================================================================

(defun get-featured-skills (client &key limit)
  "Get featured skills.

  Args:
    CLIENT: Hub client
    LIMIT: Maximum results

  Returns:
    List of featured skills"
  (hub-request client :get "/featured" :params (when limit `((:limit . ,limit)))))

(defun get-trending-skills (client &key limit period)
  "Get trending skills.

  Args:
    CLIENT: Hub client
    LIMIT: Maximum results
    PERIOD: Time period (day, week, month)

  Returns:
    List of trending skills"
  (hub-request client :get "/trending"
               :params (append (when limit `((:limit . ,limit)))
                               (when period `((:period . ,period))))))

;;; ============================================================================
;;; Repository Management
;;; ============================================================================

(defun add-skill-repository (client url)
  "Add a skill repository.

  Args:
    CLIENT: Hub client
    URL: Repository URL

  Returns:
    T on success"
  (pushnew url (hub-client-repositories client) :test #'string=)
  (log-info "Added skill repository: ~A" url)
  t)

(defun remove-skill-repository (client url)
  "Remove a skill repository.

  Args:
    CLIENT: Hub client
    URL: Repository URL

  Returns:
    T on success"
  (setf (hub-client-repositories client)
        (remove url (hub-client-repositories client) :test #'string=))
  (log-info "Removed skill repository: ~A" url)
  t)

(defun list-skill-repositories (client)
  "List all configured repositories.

  Args:
    CLIENT: Hub client

  Returns:
    List of repository URLs"
  (hub-client-repositories client))

;;; ============================================================================
;;; Skill Manifest Handling
;;; ============================================================================

(defun register-skill-from-manifest (manifest)
  "Register a skill from its manifest.

  Args:
    MANIFEST: Skill manifest plist

  Returns:
    T on success"
  (let* ((id (getf manifest :id))
         (name (getf manifest :name))
         (description (getf manifest :description))
         (version (getf manifest :version))
         (author (getf manifest :author))
         (entry-point (getf manifest :entryPoint)))

    ;; Create skill instance
    (make-skill :id id
                :name name
                :description description
                :version version
                :author author
                :entry-point entry-point
                :manifest manifest)

    (log-info "Registered skill from manifest: ~A" id)
    t))

;;; ============================================================================
;;; Cache Management
;;; ============================================================================

(defun clear-hub-cache (client)
  "Clear the hub client cache.

  Args:
    CLIENT: Hub client

  Returns:
    T"
  (clrhash (hub-client-cache client))
  (log-info "Hub cache cleared")
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defvar *default-hub-client* nil
  "Default hub client instance.")

(defun initialize-skills-hub (&key url api-key)
  "Initialize the skills hub integration.

  Args:
    URL: Hub URL (default: https://hub.lisp-claw.org)
    API-KEY: API key for authenticated requests

  Returns:
    Hub client instance"
  (setf *default-hub-client* (make-hub-client :url url :api-key api-key))
  (log-info "Skills hub initialized: ~A" url)
  *default-hub-client*)

(defun get-default-hub-client ()
  "Get the default hub client.

  Returns:
    Hub client instance"
  (or *default-hub-client*
      (setf *default-hub-client* (make-hub-client))))
