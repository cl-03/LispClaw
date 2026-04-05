;;; skills/registry.lisp --- Skills Registry System
;;;
;;; This file provides skills registry and management for Lisp-Claw.
;;; Based on OpenClaw's Skills architecture.

(defpackage #:lisp-claw.skills.registry
  (:nicknames #:lc.skills.registry)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; Skill class
   #:skill
   #:make-skill
   #:skill-id
   #:skill-name
   #:skill-description
   #:skill-version
   #:skill-author
   #:skill-entry-point
   #:skill-manifest
   #:skill-enabled-p
   ;; Skill registry
   #:*skills-registry*
   #:register-skill
   #:unregister-skill
   #:get-skill
   #:list-skills
   #:enable-skill
   #:disable-skill
   ;; Skill discovery
   #:load-skill-from-file
   #:load-skill-from-manifest
   #:scan-skills-directory
   #:hot-reload-skill
   ;; Skill execution
   #:execute-skill
   #:validate-skill
   ;; Skill Hub integration
   #:fetch-skill-from-hub
   #:sync-skills-from-hub
   ;; Initialization
   #:initialize-skills-system))

(in-package #:lisp-claw.skills.registry)

;;; ============================================================================
;;; Skill Class
;;; ============================================================================

(defclass skill ()
  ((id :initarg :id
       :reader skill-id
       :documentation "Unique skill identifier")
   (name :initarg :name
         :reader skill-name
         :documentation "Human-readable skill name")
   (description :initarg :description
                :reader skill-description
                :documentation "Skill description")
   (version :initarg :version
            :reader skill-version
            :documentation "Skill version string")
   (author :initarg :author
           :reader skill-author
           :documentation "Skill author")
   (entry-point :initarg :entry-point
                :accessor skill-entry-point
                :documentation "Function to call when skill is executed")
   (manifest :initarg :manifest
             :reader skill-manifest
             :documentation "Full manifest plist")
   (enabled-p :initform t
              :accessor skill-enabled-p
              :documentation "Whether skill is enabled"))
  (:documentation "Represents a skill/plugin in Lisp-Claw"))

(defun make-skill (id name description version &key author entry-point manifest)
  "Create a new skill instance.

  Args:
    ID: Unique identifier
    NAME: Human-readable name
    DESCRIPTION: Skill description
    VERSION: Version string
    AUTHOR: Optional author
    ENTRY-POINT: Optional function to execute
    MANIFEST: Optional full manifest plist

  Returns:
    New skill instance"
  (make-instance 'skill
                 :id id
                 :name name
                 :description description
                 :version version
                 :author (or author "Unknown")
                 :entry-point entry-point
                 :manifest (or manifest '())))

;;; ============================================================================
;;; Skills Registry
;;; ============================================================================

(defvar *skills-registry* (make-hash-table :test 'equal)
  "Hash table storing all registered skills.")

(defvar *skills-directory* nil
  "Directory path for loading skills.")

(defun register-skill (skill)
  "Register a skill in the registry.

  Args:
    SKILL: Skill instance

  Returns:
    T on success"
  (setf (gethash (skill-id skill) *skills-registry*) skill)
  (log-info "Registered skill: ~A v~A" (skill-id skill) (skill-version skill))
  t)

(defun unregister-skill (skill-id)
  "Unregister a skill from the registry.

  Args:
    SKILL-ID: Skill identifier

  Returns:
    T if skill was registered"
  (when (gethash skill-id *skills-registry*)
    (remhash skill-id *skills-registry*)
    (log-info "Unregistered skill: ~A" skill-id)
    t))

(defun get-skill (skill-id)
  "Get a skill by ID.

  Args:
    SKILL-ID: Skill identifier

  Returns:
    Skill instance or NIL"
  (gethash skill-id *skills-registry*))

(defun list-skills (&optional enabled-only)
  "List all registered skills.

  Args:
    ENABLED-ONLY: If T, only list enabled skills

  Returns:
    List of skill info plists"
  (let ((result nil))
    (maphash (lambda (id skill)
               (declare (ignore id))
               (when (or (not enabled-only) (skill-enabled-p skill))
                 (push `(:id ,(skill-id skill)
                            :name ,(skill-name skill)
                            :version ,(skill-version skill)
                            :author ,(skill-author skill)
                            :enabled ,(skill-enabled-p skill)
                            :description ,(skill-description skill))
                       result)))
             *skills-registry*)
    result))

(defun enable-skill (skill-id)
  "Enable a skill.

  Args:
    SKILL-ID: Skill identifier

  Returns:
    T on success"
  (let ((skill (get-skill skill-id)))
    (when skill
      (setf (skill-enabled-p skill) t)
      (log-info "Enabled skill: ~A" skill-id)
      t)))

(defun disable-skill (skill-id)
  "Disable a skill.

  Args:
    SKILL-ID: Skill identifier

  Returns:
    T on success"
  (let ((skill (get-skill skill-id)))
    (when skill
      (setf (skill-enabled-p skill) nil)
      (log-info "Disabled skill: ~A" skill-id)
      t)))

;;; ============================================================================
;;; Skill Loading
;;; ============================================================================

(defun parse-skill-manifest (manifest-content)
  "Parse a SKILL.md manifest file.

  Args:
    MANIFEST-CONTENT: Content of SKILL.md file

  Returns:
    Plist with skill metadata"
  (handler-case
      (let* ((lines (split-sequence:split-sequence #\Newline manifest-content))
             (current-section nil)
             (result '()))
        (dolist (line lines)
          (cond
            ;; Header line
            ((and (>= (length line) 2)
                  (char= (char line 0) #\#)
                  (char= (char line 1) #\Space))
             (setf current-section
                   (intern (string-upcase (string-trim " " (subseq line 2))) :keyword)))
            ;; Content line
            ((and current-section (> (length line) 0))
             (let ((existing (getf result current-section)))
               (if existing
                   (setf (getf result current-section)
                         (format nil "~A~%~A" existing line))
                   (setf (getf result current-section) line))))))
        result)
    (error (e)
      (log-error "Failed to parse skill manifest: ~A" e)
      nil)))

(defun load-skill-from-manifest (manifest-path)
  "Load a skill from a SKILL.md manifest file.

  Args:
    MANIFEST-PATH: Path to SKILL.md file

  Returns:
    Skill instance or NIL"
  (handler-case
      (with-open-file (in manifest-path :direction :input :element-type 'character)
        (let* ((content (make-string (file-length in)))
               (_ (read-sequence content in))
               (manifest (parse-skill-manifest content))
               (id (getf manifest :id))
               (name (getf manifest :name))
               (description (getf manifest :description))
               (version (getf manifest :version)))
          (when (and id name version)
            (let ((skill (make-skill id name (or description "") version
                                     :manifest manifest)))
              (log-info "Loaded skill from manifest: ~A" id)
              skill))))
    (error (e)
      (log-error "Failed to load skill from ~A: ~A" manifest-path e)
      nil)))

(defun load-skill-from-file (skill-file)
  "Load and execute a skill from a Lisp file.

  Args:
    SKILL-FILE: Path to skill Lisp file

  Returns:
    T on success"
  (handler-case
      (progn
        (load skill-file)
        (log-info "Loaded skill file: ~A" skill-file)
        t)
    (error (e)
      (log-error "Failed to load skill file ~A: ~A" skill-file e)
      nil)))

(defun scan-skills-directory (directory)
  "Scan a directory for skills.

  Args:
    DIRECTORY: Directory path to scan

  Returns:
    Number of skills loaded"
  (let ((count 0))
    (when (probe-file directory)
      (dolist (entry (directory (merge-pathnames "*/SKILL.md" directory)))
        (let ((skill (load-skill-from-manifest entry)))
          (when skill
            (register-skill skill)
            (incf count)
            ;; Try to load corresponding Lisp file
            (let ((lisp-file (merge-pathnames (make-pathname :name (skill-id skill)
                                                             :type "lisp")
                                              (directory-namestring entry))))
              (when (probe-file lisp-file)
                (load-skill-from-file lisp-file))))))
      ;; Also scan for direct .lisp skill files
      (dolist (entry (directory (merge-pathnames "*.lisp" directory)))
        (unless (search "registry" (namestring entry))
          (load-skill-from-file entry)
          (incf count))))
    (setf *skills-directory* directory)
    (log-info "Scanned ~A skills from ~A" count directory)
    count))

;;; ============================================================================
;;; Hot Reload
;;; ============================================================================

(defun hot-reload-skill (skill-id)
  "Hot reload a skill without restarting.

  Args:
    SKILL-ID: Skill identifier

  Returns:
    T on success"
  (let ((skill (get-skill skill-id)))
    (unless skill
      (return-from hot-reload-skill nil))

    (when *skills-directory*
      (let ((lisp-file (merge-pathnames (make-pathname :name skill-id
                                                       :type "lisp")
                                        *skills-directory*)))
        (when (probe-file lisp-file)
          ;; Unload old skill
          (unregister-skill skill-id)
          ;; Reload
          (load-skill-from-file lisp-file)
          (log-info "Hot reloaded skill: ~A" skill-id)
          t)))))

;;; ============================================================================
;;; Skill Execution
;;; ============================================================================

(defun execute-skill (skill-id &rest args)
  "Execute a skill by ID.

  Args:
    SKILL-ID: Skill identifier
    ARGS: Arguments to pass to skill

  Returns:
    Skill execution result"
  (let ((skill (get-skill skill-id)))
    (unless skill
      (error "Skill not found: ~A" skill-id))
    (unless (skill-enabled-p skill)
      (error "Skill is disabled: ~A" skill-id))
    (let ((entry (skill-entry-point skill)))
      (unless entry
        (error "Skill has no entry point: ~A" skill-id))
      (apply entry args))))

(defun validate-skill (skill)
  "Validate a skill's manifest.

  Args:
    SKILL: Skill instance

  Returns:
    T if valid, error message otherwise"
  (cond
    ((null (skill-id skill)) "Missing skill ID")
    ((null (skill-name skill)) "Missing skill name")
    ((null (skill-version skill)) "Missing skill version")
    ((null (skill-description skill)) "Missing skill description")
    (t t)))

;;; ============================================================================
;;; ClawHub Integration
;;; ============================================================================

(defun fetch-skill-from-hub (skill-id &key version)
  "Fetch a skill from ClawHub registry.

  Args:
    SKILL-ID: Skill identifier
    VERSION: Optional specific version

  Returns:
    Skill manifest or NIL"
  (declare (ignore version))
  ;; Placeholder for ClawHub API integration
  (log-info "Would fetch skill ~A from ClawHub" skill-id)
  nil)

(defun sync-skills-from-hub ()
  "Sync skills from ClawHub registry.

  Returns:
    Number of skills synced"
  ;; Placeholder for ClawHub API integration
  (log-info "Would sync skills from ClawHub")
  0)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-skills-system (&optional skills-dir)
  "Initialize the skills system.

  Args:
    SKILLS-DIR: Optional skills directory

  Returns:
    T"
  (when skills-dir
    (scan-skills-directory skills-dir))
  (log-info "Skills system initialized")
  t)
