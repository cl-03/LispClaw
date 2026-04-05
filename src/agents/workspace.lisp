;;; agents/workspace.lisp --- Workspace Management for Lisp-Claw
;;;
;;; This file implements workspace management similar to OpenClaw,
;;; providing Markdown-based configuration files for agents, identity,
;;; policies, and memory.

(defpackage #:lisp-claw.agents.workspace
  (:nicknames #:lc.agents.workspace)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.config.loader
        #:lisp-claw.agent.session
        #:lisp-claw.agent.workflows
        #:lisp-claw.advanced.memory)
  (:export
   ;; Workspace
   #:workspace
   #:make-workspace
   #:workspace-root
   #:workspace-config
   #:workspace-agents
   #:workspace-soul
   #:workspace-user
   #:workspace-policy
   ;; Workspace functions
   #:get-workspace-root
   #:initialize-workspace
   #:load-workspace-config
   #:save-workspace-config
   ;; Markdown config files
   #:parse-agents-md
   #:parse-soul-md
   #:parse-user-md
   #:parse-policy-md
   #:generate-agents-md
   #:generate-soul-md
   #:generate-user-md
   #:generate-policy-md
   ;; File operations
   #:read-markdown-file
   #:write-markdown-file
   #:parse-yaml-frontmatter
   ;; Templates
   #:get-agents-template
   #:get-soul-template
   #:get-user-template
   #:get-policy-template))

(in-package #:lisp-claw.agents.workspace)

;;; ============================================================================
;;; Workspace Class
;;; ============================================================================

(defclass workspace ()
  ((root :initarg :root
         :reader workspace-root
         :documentation "Workspace root directory")
   (config :initform nil
           :accessor workspace-config
           :documentation "Workspace configuration")
   (agents :initform nil
           :accessor workspace-agents
           :documentation "Agent definitions from AGENTS.md")
   (soul :initform nil
         :accessor workspace-soul
         :documentation "Agent identity from SOUL.md")
   (user :initform nil
         :accessor workspace-user
         :documentation "User preferences from USER.md")
   (policy :initform nil
           :accessor workspace-policy
           :documentation "Security policy from POLICY.md")
   (last-loaded :initform (get-universal-time)
                :accessor workspace-last-loaded
                :documentation "Last load timestamp"))
  (:documentation "Lisp-Claw workspace"))

(defmethod print-object ((ws workspace) stream)
  (print-unreadable-object (ws stream :type t)
    (format stream "~A" (workspace-root ws))))

(defun make-workspace (root)
  "Create a workspace instance.

  Args:
    ROOT: Workspace root directory path

  Returns:
    Workspace instance"
  (make-instance 'workspace :root root))

;;; ============================================================================
;;; Workspace Root
;;; ============================================================================

(defvar *default-workspace-root* nil
  "Default workspace root directory.")

(defun get-workspace-root ()
  "Get the workspace root directory.

  Returns:
    Pathname of workspace root"
  (or *default-workspace-root*
      (let ((env-home (uiop:getenv "LISP_CLAW_HOME")))
        (if env-home
            (pathname env-home)
            (merge-pathnames
             (make-pathname :directory '(:relative ".lisp-claw"))
             (user-homedir-pathname))))))

(defun set-workspace-root! (path)
  "Set the workspace root directory.

  Args:
    PATH: New workspace root path

  Returns:
    T"
  (setf *default-workspace-root* (pathname path))
  (log-info "Workspace root set to: ~A" path)
  t)

;;; ============================================================================
;;; Workspace Initialization
;;; ============================================================================

(defun initialize-workspace (&optional root)
  "Initialize the workspace.

  Args:
    ROOT: Optional workspace root

  Returns:
    Workspace instance"
  (let* ((ws-root (or root (get-workspace-root)))
         (workspace (make-workspace ws-root)))

    ;; Ensure directories exist
    (ensure-directories-exist (merge-pathnames "skills/" ws-root))
    (ensure-directories-exist (merge-pathnames "sessions/" ws-root))
    (ensure-directories-exist (merge-pathnames "memory/" ws-root))

    ;; Create default config files if missing
    (ensure-config-files workspace)

    ;; Load configuration
    (load-workspace-config workspace)

    (log-info "Workspace initialized at: ~A" ws-root)
    workspace))

(defun ensure-config-files (workspace)
  "Create default config files if they don't exist.

  Args:
    WORKSPACE: Workspace instance

  Returns:
    T"
  (let ((root (workspace-root workspace)))
    ;; AGENTS.md
    (unless (probe-file (merge-pathnames "AGENTS.md" root))
      (let ((path (merge-pathnames "AGENTS.md" root)))
        (with-open-file (out path :direction :output :if-exists :supersede)
          (write-string (get-agents-template) out))
        (log-info "Created: AGENTS.md")))

    ;; SOUL.md
    (unless (probe-file (merge-pathnames "SOUL.md" root))
      (let ((path (merge-pathnames "SOUL.md" root)))
        (with-open-file (out path :direction :output :if-exists :supersede)
          (write-string (get-soul-template) out))
        (log-info "Created: SOUL.md")))

    ;; USER.md
    (unless (probe-file (merge-pathnames "USER.md" root))
      (let ((path (merge-pathnames "USER.md" root)))
        (with-open-file (out path :direction :output :if-exists :supersede)
          (write-string (get-user-template) out))
        (log-info "Created: USER.md")))

    ;; POLICY.md
    (unless (probe-file (merge-pathnames "POLICY.md" root))
      (let ((path (merge-pathnames "POLICY.md" root)))
        (with-open-file (out path :direction :output :if-exists :supersede)
          (write-string (get-policy-template) out))
        (log-info "Created: POLICY.md")))

    ;; TOOLS.md
    (unless (probe-file (merge-pathnames "TOOLS.md" root))
      (let ((path (merge-pathnames "TOOLS.md" root)))
        (with-open-file (out path :direction :output :if-exists :supersede)
          (write-string "# Tools Documentation~%~%Auto-generated tool documentation.~%") out))
        (log-info "Created: TOOLS.md")))

    ;; MEMORY.md
    (unless (probe-file (merge-pathnames "MEMORY.md" root))
      (let ((path (merge-pathnames "MEMORY.md" root)))
        (with-open-file (out path :direction :output :if-exists :supersede)
          (write-string "# Memory Index~%~%~{## ~A~%~%~}~%" nil) out))
        (log-info "Created: MEMORY.md")))

    ;; openclaw.json (main config)
    (unless (probe-file (merge-pathnames "openclaw.json" root))
      (let ((path (merge-pathnames "openclaw.json" root)))
        (with-open-file (out path :direction :output :if-exists :supersede)
          (write-string (stringify-json
                         '(:version "0.1.0"
                           :gateway (:port 18789 :bind "127.0.0.1")
                           :logging (:level "info"))) out))
        (log-info "Created: openclaw.json"))))
  t)

;;; ============================================================================
;;; Configuration Loading
;;; ============================================================================

(defun load-workspace-config (workspace)
  "Load all workspace configuration.

  Args:
    WORKSPACE: Workspace instance

  Returns:
    T"
  (let ((root (workspace-root workspace)))
    ;; Load AGENTS.md
    (when (probe-file (merge-pathnames "AGENTS.md" root))
      (setf (workspace-agents workspace)
            (parse-agents-md (read-markdown-file (merge-pathnames "AGENTS.md" root)))))

    ;; Load SOUL.md
    (when (probe-file (merge-pathnames "SOUL.md" root))
      (setf (workspace-soul workspace)
            (parse-soul-md (read-markdown-file (merge-pathnames "SOUL.md" root)))))

    ;; Load USER.md
    (when (probe-file (merge-pathnames "USER.md" root))
      (setf (workspace-user workspace)
            (parse-user-md (read-markdown-file (merge-pathnames "USER.md" root)))))

    ;; Load POLICY.md
    (when (probe-file (merge-pathnames "POLICY.md" root))
      (setf (workspace-policy workspace)
            (parse-policy-md (read-markdown-file (merge-pathnames "POLICY.md" root)))))

    (setf (workspace-last-loaded workspace) (get-universal-time))
    (log-info "Workspace configuration loaded"))
  t)

(defun save-workspace-config (workspace)
  "Save workspace configuration.

  Args:
    WORKSPACE: Workspace instance

  Returns:
    T"
  (let ((root (workspace-root workspace)))
    ;; Save AGENTS.md
    (when (workspace-agents workspace)
      (write-markdown-file (merge-pathnames "AGENTS.md" root)
                           (generate-agents-md (workspace-agents workspace))))

    ;; Save SOUL.md
    (when (workspace-soul workspace)
      (write-markdown-file (merge-pathnames "SOUL.md" root)
                           (generate-soul-md (workspace-soul workspace))))

    ;; Save USER.md
    (when (workspace-user workspace)
      (write-markdown-file (merge-pathnames "USER.md" root)
                           (generate-user-md (workspace-user workspace))))

    ;; Save POLICY.md
    (when (workspace-policy workspace)
      (write-markdown-file (merge-pathnames "POLICY.md" root)
                           (generate-policy-md (workspace-policy workspace))))

    (log-info "Workspace configuration saved"))
  t)

;;; ============================================================================
;;; Markdown File Operations
;;; ============================================================================

(defun read-markdown-file (pathname)
  "Read a Markdown file.

  Args:
    PATHNAME: File path

  Returns:
    File contents as string"
  (with-open-file (in pathname :direction :input)
    (let ((content (make-string (file-length in))))
      (read-sequence content in)
      content)))

(defun write-markdown-file (pathname content)
  "Write a Markdown file.

  Args:
    PATHNAME: File path
    CONTENT: Content string

  Returns:
    T"
  (ensure-directories-exist pathname)
  (with-open-file (out pathname :direction :output :if-exists :supersede)
    (write-string content out))
  t)

(defun parse-yaml-frontmatter (content)
  "Parse YAML frontmatter from Markdown content.

  Args:
    CONTENT: Markdown content

  Returns:
    Plist of frontmatter values"
  (let* ((lines (split-sequence:split-sequence #\Newline content))
         (frontmatter nil)
         (in-frontmatter nil)
         (current-key nil)
         (current-value nil))

    ;; Check for frontmatter delimiter
    (when (and lines (string= (first lines) "---"))
      (setf in-frontmatter t)

      ;; Parse frontmatter lines
      (loop for line in (rest lines)
            until (string= line "---")
            do (if (and (not current-key)
                        (find #\: line))
                   ;; Key-value line
                   (let* ((parts (split-sequence:split-sequence #\: line))
                          (key (string-trim '(#\Space) (first parts)))
                          (val (string-trim '(#\Space #\")
                                            (if (rest parts)
                                                (format nil "~{~A~^:~}" (rest parts))
                                                ""))))
                     (when (and key (not (string= key "")))
                       (setf current-key (intern (string-upcase key) :keyword)
                             current-value val)
                       (when val
                         (setf frontmatter (append frontmatter (list current-key current-value))
                               current-key nil
                               current-value nil))))
                   ;; Continuation of previous value
                   (when current-key
                     (setf current-value (concatenate 'string current-value " "
                                                      (string-trim '(#\Space) line)))
                     (setf frontmatter
                           (append (butlast frontmatter 2)
                                   (list current-key current-value))
                           current-key nil)))))

    frontmatter))

;;; ============================================================================
;;; AGENTS.md Parser
;;; ============================================================================

(defun parse-agents-md (content)
  "Parse AGENTS.md content.

  Args:
    CONTENT: AGENTS.md content

  Returns:
    List of agent definitions"
  (let ((agents nil)
        (current-agent nil))

    ;; Split by agent headers (## Agent Name)
    (let* ((lines (split-sequence:split-sequence #\Newline content))
           (sections (split-into-sections lines)))

      (dolist (section sections)
        (when (and section (>= (length section) 2))
          (let* ((header (first section))
                 (body (rest section)))

            ;; Parse header for agent name
            (when (search "## " header)
              (let* ((name (string-trim '(#\Space) (subseq header 3)))
                     (props (parse-agent-properties body)))

                (when name
                  (push (list :name name
                              :id (string-downcase (remove #\Space name))
                              :role (getf props :role)
                              :model (getf props :model)
                              :system-prompt (getf props :system-prompt)
                              :capabilities (getf props :capabilities)
                              :routing-rules (getf props :routing-rules))
                        agents)))))))))

    (nreverse agents)))

(defun parse-agent-properties (lines)
  "Parse agent properties from body lines.

  Args:
    LINES: List of body lines

  Returns:
    Plist of properties"
  (let ((props nil)
        (current-section nil)
        (current-value nil))

    (dolist (line lines)
      (cond
        ;; Section header like ### Role
        ((and (>= (length line) 4)
              (string= "### " (subseq line 0 4)))
         (when current-section
           (setf props (append props (list current-section (nreverse current-value)))))
         (setf current-section (intern (string-upcase (subseq line 4)) :keyword)
               current-value nil))

        ;; Property line like **Model**: claude-sonnet-4-6
        ((and (search "**:" line) current-section)
         (let* ((parts (split-sequence:split-sequence #\: line))
                (key (string-trim '(#\Space #\*) (first parts)))
                (val (string-trim '(#\Space)
                                  (if (rest parts)
                                      (format nil "~{~A~^:~}" (rest parts))
                                      ""))))
           (when (and key (not (string= key "")))
             (push (cons (intern (string-upcase key) :keyword) val) current-value))))

        ;; Regular text (part of current section)
        (t
         (when (and line (not (string= line "")))
           (push line current-value)))))

    ;; Save last section
    (when current-section
      (setf props (append props (list current-section
                                      (if (and current-value (listp current-value))
                                          (nreverse current-value)
                                          current-value)))))

    ;; Convert to standard format
    (list :role (format-section (getf props :role))
          :model (getf props :model)
          :system-prompt (format-section (getf props :system-prompt))
          :capabilities (parse-capabilities (getf props :capabilities))
          :routing-rules (parse-routing-rules (getf props :routing-rules)))))

(defun format-section (value)
  "Format a section value.

  Args:
    VALUE: Section value (list or string)

  Returns:
    Formatted string"
  (cond
    ((null value) nil)
    ((stringp value) value)
    ((listp value)
     (format nil "~{~A~^ ~}" (mapcar (lambda (x) (if (stringp x) x (princ-to-string x)))
                                     value)))))

(defun parse-capabilities (value)
  "Parse capabilities list.

  Args:
    VALUE: Capabilities value

  Returns:
    List of capabilities"
  (cond
    ((null value) nil)
    ((stringp value)
     (split-sequence:split-sequence #\, value :remove-empty-subseqs t))
    ((listp value)
     (mapcar (lambda (x) (if (stringp x) x (princ-to-string x))) value))))

(defun parse-routing-rules (value)
  "Parse routing rules.

  Args:
    VALUE: Routing rules value

  Returns:
    List of routing rules"
  ;; Simple implementation - just return as list
  (cond
    ((null value) nil)
    ((stringp value) (list value))
    ((listp value) value)))

(defun split-into-sections (lines)
  "Split lines into sections by ## headers.

  Args:
    LINES: List of lines

  Returns:
    List of sections"
  (let ((sections nil)
        (current-section nil))

    (dolist (line lines)
      (if (and (>= (length line) 2)
               (string= "##" (subseq line 0 2))
               (not (string= (subseq line 0 3) "###")))
          ;; New section
          (progn
            (when current-section
              (push current-section sections))
            (setf current-section (list line)))
          ;; Continue current section
          (push line current-section)))

    (when current-section
      (push current-section sections))

    (nreverse sections)))

;;; ============================================================================
;;; SOUL.md Parser
;;; ============================================================================

(defun parse-soul-md (content)
  "Parse SOUL.md content.

  Args:
    CONTENT: SOUL.md content

  Returns:
    Soul configuration plist"
  (let ((frontmatter (parse-yaml-frontmatter content))
        (body content))

    (list :identity (getf frontmatter :identity)
          :personality (getf frontmatter :personality)
          :tone (getf frontmatter :tone)
          :style (getf frontmatter :style)
          :values (parse-values (getf frontmatter :values))
          :greeting (getf frontmatter :greeting)
          :signature (getf frontmatter :signature)
          :body body)))

(defun parse-values (value)
  "Parse values list.

  Args:
    VALUE: Values string or list

  Returns:
    List of values"
  (cond
    ((null value) nil)
    ((stringp value)
     (split-sequence:split-sequence #\, value :remove-empty-subseqs t))
    ((listp value) value)))

;;; ============================================================================
;;; USER.md Parser
;;; ============================================================================

(defun parse-user-md (content)
  "Parse USER.md content.

  Args:
    CONTENT: USER.md content

  Returns:
    User preferences plist"
  (let ((frontmatter (parse-yaml-frontmatter content)))
    (list :name (getf frontmatter :name)
          :timezone (getf frontmatter :timezone)
          :language (getf frontmatter :language)
          :preferences (parse-preferences content)
          :context (parse-context content))))

(defun parse-preferences (content)
  "Parse user preferences from content.

  Args:
    CONTENT: USER.md content

  Returns:
    Preferences plist"
  ;; Simple implementation - extract key-value pairs
  nil)

(defun parse-context (content)
  "Parse user context from content.

  Args:
    CONTENT: USER.md content

  Returns:
    Context string"
  content)

;;; ============================================================================
;;; POLICY.md Parser
;;; ============================================================================

(defun parse-policy-md (content)
  "Parse POLICY.md content.

  Args:
    CONTENT: POLICY.md content

  Returns:
    Policy configuration plist"
  (let ((frontmatter (parse-yaml-frontmatter content)))
    (list :allowed-tools (parse-allowed-tools (getf frontmatter :allowed-tools))
          :blocked-tools (parse-blocked-tools (getf frontmatter :blocked-tools))
          :max-tokens (parse-integer-safe (getf frontmatter :max-tokens))
          :allowed-models (parse-allowed-models (getf frontmatter :allowed-models))
          :blocked-models (parse-blocked-models (getf frontmatter :blocked-models))
          :require-confirmation (getf frontmatter :require-confirmation)
          :body content)))

(defun parse-integer-safe (value)
  "Safely parse an integer.

  Args:
    VALUE: Value to parse

  Returns:
    Integer or NIL"
  (when value
    (handler-case (parse-integer value)
      (error (e)
        (declare (ignore e))
        nil))))

(defun parse-allowed-tools (value)
  "Parse allowed tools list.

  Args:
    VALUE: Tools value

  Returns:
    List of tool names"
  (cond
    ((null value) nil)
    ((stringp value)
     (split-sequence:split-sequence #\, value :remove-empty-subseqs t))
    ((listp value) value)))

(defun parse-blocked-tools (value)
  "Parse blocked tools list."
  (parse-allowed-tools value))

(defun parse-allowed-models (value)
  "Parse allowed models list."
  (parse-allowed-tools value))

(defun parse-blocked-models (value)
  "Parse blocked models list."
  (parse-allowed-tools value))

;;; ============================================================================
;;; Markdown Generators
;;; ============================================================================

(defun generate-agents-md (agents)
  "Generate AGENTS.md content.

  Args:
    AGENTS: List of agent definitions

  Returns:
    AGENTS.md content string"
  (with-output-to-string (s)
    (format s "# Agent Definitions~%~%")
    (format s "This file defines the agents available in this workspace.~%~%")
    (format s "---~%~%")

    (dolist (agent agents)
      (format s "## ~A~%~%" (getf agent :name))
      (format s "**ID**: ~A~%~%" (getf agent :id))
      (format s "**Model**: ~A~%~%" (getf agent :model))

      (when (getf agent :role)
        (format s "~%### Role~%~%~A~%~%" (getf agent :role)))

      (when (getf agent :system-prompt)
        (format s "~%### System Prompt~%~%~A~%~%" (getf agent :system-prompt)))

      (when (getf agent :capabilities)
        (format s "~%### Capabilities~%~%~{~A~^, ~}~%~%" (getf agent :capabilities)))

      (format s "~%---~%~%"))))

(defun generate-soul-md (soul)
  "Generate SOUL.md content.

  Args:
    SOUL: Soul configuration plist

  Returns:
    SOUL.md content string"
  (with-output-to-string (s)
    (format s "---~%")
    (format s "identity: ~A~%" (getf soul :identity))
    (format s "personality: ~A~%" (getf soul :personality))
    (format s "tone: ~A~%" (getf soul :tone))
    (format s "style: ~A~%" (getf soul :style))
    (format s "greeting: ~A~%" (getf soul :greeting))
    (format s "---~%~%")

    (format s "# Agent Identity~%~%")
    (format s "~A~%" (getf soul :body))))

(defun generate-user-md (user)
  "Generate USER.md content.

  Args:
    USER: User preferences plist

  Returns:
    USER.md content string"
  (with-output-to-string (s)
    (format s "---~%")
    (format s "name: ~A~%" (getf user :name))
    (format s "timezone: ~A~%" (getf user :timezone))
    (format s "language: ~A~%" (getf user :language))
    (format s "---~%~%")

    (format s "# User Preferences~%~%")
    (format s "~A~%" (getf user :context))))

(defun generate-policy-md (policy)
  "Generate POLICY.md content.

  Args:
    POLICY: Policy configuration plist

  Returns:
    POLICY.md content string"
  (with-output-to-string (s)
    (format s "---~%")
    (format s "allowed_tools: ~{~A~^, ~}~%" (getf policy :allowed-tools))
    (format s "blocked_tools: ~{~A~^, ~}~%" (getf policy :blocked-tools))
    (format s "max_tokens: ~A~%" (getf policy :max-tokens))
    (format s "require_confirmation: ~A~%" (getf policy :require-confirmation))
    (format s "---~%~%")

    (format s "# Security Policy~%~%")
    (format s "~A~%" (getf policy :body))))

;;; ============================================================================
;;; Templates
;;; ============================================================================

(defun get-agents-template ()
  "Get AGENTS.md template.

  Returns:
    Template string"
  "# Agent Definitions

This file defines the agents available in this workspace.

---

## Default Agent

**ID**: default
**Model**: claude-sonnet-4-6

### Role

General purpose assistant for coding, writing, and analysis.

### Capabilities

chat, tools, memory, file-operations

### Routing Rules

- Default agent for all queries
- Escalate complex coding tasks to coding-specialist

---

## Coding Specialist

**ID**: coding-specialist
**Model**: claude-opus-4-6

### Role

Expert software engineer for complex coding tasks.

### System Prompt

You are an expert software engineer with deep knowledge of:
- Software architecture and design patterns
- Multiple programming languages
- Testing and debugging
- Code review and refactoring

### Capabilities

coding, debugging, code-review, architecture, testing

### Routing Rules

- Handle complex coding tasks
- Review pull requests
- Debug difficult issues

---
")

(defun get-soul-template ()
  "Get SOUL.md template.

  Returns:
    Template string"
  "---
identity: Lisp-Claw Assistant
personality: Helpful, precise, thoughtful
tone: Professional yet friendly
style: Concise and clear
greeting: Hello! I'm Lisp-Claw, your AI assistant. How can I help you today?
---

# Agent Identity

## Core Values

1. **Helpfulness**: Always strive to provide genuinely useful assistance
2. **Accuracy**: Prioritize correctness over speed
3. **Clarity**: Communicate in clear, accessible language
4. **Safety**: Never assist with harmful or malicious activities

## Personality Traits

- Thoughtful and considered in responses
- Adapts communication style to the user's needs
- Admits uncertainty when appropriate
- Asks clarifying questions when needed

## Expertise Areas

- Common Lisp programming
- AI assistant systems
- Software architecture
- Code review and debugging

---
")

(defun get-user-template ()
  "Get USER.md template.

  Returns:
    Template string"
  "---
name: User
timezone: UTC
language: en
---

# User Preferences

## Communication Style

- Prefer concise responses
- Use code examples when helpful
- Explain reasoning for complex decisions

## Working Context

Add any relevant context about your projects, goals, or preferences here.

## Tool Preferences

- Preferred text editor:
- Shell environment:
- Programming languages:

---
")

(defun get-policy-template ()
  "Get POLICY.md template.

  Returns:
    Template string"
  "---
allowed_tools: shell, file-read, file-write, browser
blocked_tools: shell-sudo, system-exec
max_tokens: 4096
require_confirmation: true
---

# Security Policy

## Allowed Tools

The following tools are allowed without confirmation:

- `shell` - Basic shell commands
- `file-read` - Reading files
- `file-write` - Writing files
- `browser` - Web browsing

## Blocked Tools

The following tools are blocked:

- `shell-sudo` - Sudo commands
- `system-exec` - Direct system execution

## Confirmation Required

The following actions require user confirmation:

- Installing new packages
- Modifying system files
- Executing external scripts
- Network operations

## Token Limits

- Maximum tokens per response: 4096
- Maximum tokens per conversation: 100000

## Model Restrictions

- Allowed models: claude-sonnet-4-6, claude-opus-4-6
- Blocked models: none

---
")

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-workspace-system ()
  "Initialize the workspace system.

  Returns:
    T"
  (let ((workspace (initialize-workspace)))
    (log-info "Workspace system initialized"))
  t)
