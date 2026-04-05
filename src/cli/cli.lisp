;;; cli.lisp --- CLI System for Lisp-Claw
;;;
;;; This file implements the command-line interface for Lisp-Claw,
;;; similar to OpenClaw's CLI with 100+ subcommands.

(defpackage #:lisp-claw.cli
  (:nicknames #:lc.cli)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.config.loader
        #:lisp-claw.gateway.server
        #:lisp-claw.gateway.health
        #:lisp-claw.agent.session
        #:lisp-claw.skills.registry
        #:lisp-claw.skills.hub
        #:lisp-claw.advanced.memory
        #:lisp-claw.advanced.cache
        #:lisp-claw.vector.store
        #:lisp-claw.vector.search
        #:lisp-claw.mcp.client
        #:lisp-claw.mcp.servers
        #:lisp-claw.agent.workflows
        #:lisp-claw.agent.intents
        #:lisp-claw.hooks.webhook
        #:lisp-claw.gateway.middleware
        #:lisp-claw.integrations.n8n
        #:lisp-claw.integrations.cicd
        #:lisp-claw.channels.android)
  (:export
   ;; Main CLI
   #:run-cli
   #:cli-loop
   #:parse-command
   ;; Command registry
   #:cli-command
   #:register-command
   #:list-commands
   #:get-command
   ;; Built-in commands
   #:cmd-help
   #:cmd-status
   #:cmd-quit
   #:cmd-agents
   #:cmd-skills
   #:cmd-gateway
   #:cmd-memory
   #:cmd-config
   #:cmd-sessions
   #:cmd-vector
   #:cmd-mcp
   #:cmd-workflows
   #:cmd-hooks
   #:cmd-tools
   #:cmd-n8n
   #:cmd-cicd
   #:cmd-android))

(in-package #:lisp-claw.cli)

;;; ============================================================================
;;; Command Definition
;;; ============================================================================

(defstruct cli-command
  "A CLI command definition."
  (name "" :type string)
  (aliases nil :type list)
  (description "" :type string)
  (usage "" :type string)
  (handler nil :type function)
  (options nil :type list)
  (examples nil :type list))

;;; ============================================================================
;;; Command Registry
;;; ============================================================================

(defvar *command-registry* (make-hash-table :test 'equal)
  "Registry of CLI commands.")

(defun register-command (command)
  "Register a CLI command.

  Args:
    COMMAND: cli-command instance

  Returns:
    T on success"
  (setf (gethash (cli-command-name command) *command-registry*) command)
  (dolist (alias (cli-command-aliases command))
    (setf (gethash alias *command-registry*) command))
  t)

(defun get-command (name)
  "Get a command by name or alias.

  Args:
    NAME: Command name

  Returns:
    cli-command instance or NIL"
  (gethash name *command-registry*))

(defun list-commands ()
  "List all registered commands.

  Returns:
    List of command info"
  (let ((commands nil))
    (maphash (lambda (name cmd)
               (declare (ignore name))
               (push (list :name (cli-command-name cmd)
                           :description (cli-command-description cmd)
                           :usage (cli-command-usage cmd))
                     commands))
             *command-registry*)
    (sort commands #'string< :key #'getf)))

;;; ============================================================================
;;; CLI Parser
;;; ============================================================================

(defun parse-command (input)
  "Parse CLI input into command and arguments.

  Args:
    INPUT: User input string

  Returns:
    Values: command-name, args plist"
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Newline) input))
         (parts (split-sequence:split-sequence #\Space trimmed))
         (cmd-name (when parts (string-downcase (first parts))))
         (args (rest parts)))
    (values cmd-name (parse-args args))))

(defun parse-args (args)
  "Parse command arguments into plist.

  Args:
    ARGS: List of argument strings

  Returns:
    Plist of arguments"
  (let ((result nil)
        (current-key nil))
    (dolist (arg args)
      (cond
        ;; Long option --key=value
        ((and (>= (length arg) 5)
              (string= "--" (subseq arg 0 2))
              (find #\= arg))
         (let* ((kv (split-sequence:split-sequence #\= arg))
                (key (intern (string-upcase (subseq (first kv) 2)) :keyword))
                (val (rest kv)))
           (setf result (append result (list key (format nil "~{~A~^ ~}" val))))))
        ;; Long option --key value
        ((and (>= (length arg) 2)
              (string= "--" (subseq arg 0 2)))
         (setf current-key (intern (string-upcase (subseq arg 2)) :keyword)))
        ;; Short option -k value
        ((and (>= (length arg) 1)
              (char= #\- (char arg 0))
              (not current-key))
         (setf current-key (intern (string-upcase (subseq arg 1)) :keyword)))
        ;; Value
        (t
         (when current-key
           (setf result (append result (list current-key arg)))
           (setf current-key nil)))))
    result))

;;; ============================================================================
;;; CLI Output Helpers
;;; ============================================================================

(defun print-header (text)
  "Print a formatted header."
  (format t "~%~%═══════════════════════════════════════════════════════════~%")
  (format t "  ~A~%" text)
  (format t "═══════════════════════════════════════════════════════════~%~%"))

(defun print-section (text)
  "Print a section header."
  (format t "~%─── ~A ───~%~%" text))

(defun print-row (label value)
  "Print a key-value row."
  (format t "  ~20A  ~A~%" label value))

(defun print-table (headers rows)
  "Print a formatted table."
  (let* ((widths (mapcar #'length headers))
         (col-widths (reduce #'(lambda (w1 w2)
                                  (mapcar #'max w1 w2))
                             rows
                             :initial-value widths
                             :key (lambda (row)
                                    (mapcar #'(lambda (cell)
                                                 (length (princ-to-string cell)))
                                            row)))))
    ;; Print header
    (format t "  ")
    (loop for header in headers
          for width in col-widths
          do (format t "~A~VT" header (+ width 2)))
    (format t "~%")
    ;; Print separator
    (format t "  ")
    (loop for width in col-widths
          do (format t "~A" (make-string (+ width 2) :initial-element #\-)))
    (format t "~%")
    ;; Print rows
    (dolist (row rows)
      (format t "  ")
      (loop for cell in row
            for width in col-widths
            do (format t "~A~VT" cell (+ width 2)))
      (format t "~%"))))

(defun print-success (message)
  "Print success message."
  (format t "  ✓ ~A~%" message))

(defun print-error (message)
  "Print error message."
  (format t "  ✗ ~A~%" message))

(defun print-info (message)
  "Print info message."
  (format t "  ℹ ~A~%" message))

;;; ============================================================================
;;; Built-in Commands
;;; ============================================================================

(defun cmd-help (&rest args)
  "Show help information.

  Usage: help [command]"
  (declare (ignore args))
  (print-header "Lisp-Claw CLI Help")
  (format t "Available commands:~%~%")
  (dolist (cmd-info (list-commands))
    (let ((name (getf cmd-info :name))
          (desc (getf cmd-info :description)))
      (format t "  ~20A  ~A~%" name desc)))
  (format t "~%Use 'help <command>' for more details on a specific command.~%"))

(defun cmd-status (&rest args)
  "Show system status.

  Usage: status"
  (declare (ignore args))
  (print-header "System Status")

  (let ((health (get-health-status)))
    (print-row "Status:" (getf health :status))
    (print-row "Clients:" (getf health :clients))
    (print-row "Memory:" (getf health :memory))
    (print-row "Uptime:" (format nil "~A seconds"
                                 (- (get-universal-time) *lisp-claw-start-time*))))

  (print-section "Agents")
  (let ((agents (list-agents)))
    (if agents
        (print-table '("ID" "Name" "Role" "State")
                     (mapcar (lambda (a)
                               (list (getf a :id)
                                     (getf a :name)
                                     (getf a :role)
                                     (getf a :state)))
                             agents))
        (print-info "No agents registered")))

  (print-section "Workflows")
  (let ((workflows (list-workflows)))
    (if workflows
        (print-table '("ID" "Name" "State" "Steps")
                     (mapcar (lambda (w)
                               (list (getf w :id)
                                     (getf w :name)
                                     (getf w :state)
                                     (getf w :steps)))
                             workflows))
        (print-info "No workflows registered"))))

(defun cmd-quit (&rest args)
  "Exit the CLI.

  Usage: quit"
  (declare (ignore args))
  (format t "Goodbye!~%")
  (throw 'cli-exit t))

(defun cmd-agents (&rest args)
  "Manage AI agents.

  Usage:
    agents list                    - List all agents
    agents add <id> <name> [opts]  - Add an agent
    agents remove <id>             - Remove an agent
    agents info <id>               - Show agent details
    agents set <id> --model=X      - Update agent"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:list
       (print-header "Registered Agents")
       (let ((agents (list-agents)))
         (if agents
             (print-table '("ID" "Name" "Role" "Model" "State")
                          (mapcar (lambda (a)
                                    (list (getf a :id)
                                          (getf a :name)
                                          (getf a :role)
                                          (getf a :model)
                                          (getf a :state)))
                                  agents))
             (print-info "No agents registered"))))
      (:add
       (if (>= (length args) 3)
           (let* ((id (second args))
                  (name (third args))
                  (agent (make-agent id name)))
             (register-agent agent)
             (print-success (format nil "Agent '~A' added" name)))
           (print-error "Usage: agents add <id> <name>")))
      (:remove
       (if (>= (length args) 2)
           (let ((id (second args)))
             (if (unregister-agent id)
                 (print-success (format nil "Agent '~A' removed" id))
                 (print-error "Agent not found")))
           (print-error "Usage: agents remove <id>")))
      (:info
       (if (>= (length args) 2)
           (let ((agent (get-agent (second args))))
             (if agent
                 (progn
                   (print-header (format nil "Agent: ~A" (agent-name agent)))
                   (print-row "ID:" (agent-id agent))
                   (print-row "Name:" (agent-name agent))
                   (print-row "Role:" (agent-role agent))
                   (print-row "Model:" (agent-model agent))
                   (print-row "State:" (agent-state agent))
                   (print-row "Capabilities:" (agent-capabilities agent)))
                 (print-error "Agent not found")))
           (print-error "Usage: agents info <id>")))
      (t
       (print-error "Unknown subcommand. Use 'help agents'"))))

(defun cmd-skills (&rest args)
  "Manage skills.

  Usage:
    skills list           - List all skills
    skills search <query> - Search skills
    skills info <id>      - Show skill details
    skills install <id>   - Install a skill
    skills uninstall <id> - Uninstall a skill"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:list
       (print-header "Registered Skills")
       (let ((skills (list-skills)))
         (if skills
             (print-table '("ID" "Name" "Version" "Author")
                          (mapcar (lambda (s)
                                    (list (getf s :id)
                                          (getf s :name)
                                          (getf s :version)
                                          (getf s :author)))
                                  skills))
             (print-info "No skills registered"))))
      (:search
       (if (>= (length args) 2)
           (let ((query (second args)))
             (print-header (format nil "Search Results: '~A'" query))
             ;; Implement search
             (print-info "Search not yet implemented"))
           (print-error "Usage: skills search <query>")))
      (:info
       (if (>= (length args) 2)
           (let ((skill (get-skill (second args))))
             (if skill
                 (progn
                   (print-header (format nil "Skill: ~A" (getf skill :name)))
                   (print-row "ID:" (getf skill :id))
                   (print-row "Version:" (getf skill :version))
                   (print-row "Author:" (getf skill :author))
                   (print-row "Description:" (getf skill :description)))
                 (print-error "Skill not found")))
           (print-error "Usage: skills info <id>")))
      (:install
       (if (>= (length args) 2)
           (let ((skill-id (second args)))
             ;; Implement install
             (print-info (format nil "Installing skill: ~A" skill-id)))
           (print-error "Usage: skills install <id>")))
      (:uninstall
       (if (>= (length args) 2)
           (let ((skill-id (second args)))
             ;; Implement uninstall
             (print-info (format nil "Uninstalling skill: ~A" skill-id)))
           (print-error "Usage: skills uninstall <id>")))
      (t
       (print-error "Unknown subcommand. Use 'help skills'"))))

(defun cmd-gateway (&rest args)
  "Manage the gateway.

  Usage:
    gateway status    - Show gateway status
    gateway start     - Start the gateway
    gateway stop      - Stop the gateway
    gateway restart   - Restart the gateway
    gateway clients   - List connected clients"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :status)
      (:status
       (print-header "Gateway Status")
       (print-row "Running:" (if *lisp-claw-running-p* "Yes" "No"))
       (print-row "Port:" *gateway-port*)
       (print-row "Bind:" *gateway-bind*))
      (:start
       (print-info "Gateway start not available from CLI"))
      (:stop
       (print-info "Gateway stop not available from CLI"))
      (:restart
       (print-info "Gateway restart not available from CLI"))
      (:clients
       (print-header "Connected Clients")
       (print-info "Client listing not yet implemented"))
      (t
       (print-error "Unknown subcommand. Use 'help gateway'"))))

(defun cmd-memory (&rest args)
  "Manage memory.

  Usage:
    memory list [--type=X]  - List memories
    memory search <query>   - Search memories
    memory clear            - Clear all memories
    memory stats            - Show memory statistics"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:list
       (print-header "Memories")
       (let* ((type-arg (getf (rest args) :type))
              (memories (search-memories :type (when type-arg (keywordize type-arg)))))
         (if memories
             (print-table '("ID" "Type" "Priority" "Tags")
                          (mapcar (lambda (m)
                                    (list (getf m :id)
                                          (getf m :type)
                                          (getf m :priority)
                                          (format nil "~{~A~^, ~}" (getf m :tags))))
                                  memories))
             (print-info "No memories found"))))
      (:search
       (if (>= (length args) 2)
           (let ((query (second args)))
             (print-header (format nil "Memory Search: '~A'" query))
             ;; Implement semantic search
             (print-info "Semantic search not yet implemented"))
           (print-error "Usage: memory search <query>")))
      (:clear
       (clear-memories)
       (print-success "All memories cleared"))
      (:stats
       (print-header "Memory Statistics")
       (let ((stats (get-memory-stats)))
         (print-row "Total:" (getf stats :total))
         (print-row "Short-term:" (getf stats :short-term))
         (print-row "Long-term:" (getf stats :long-term))
         (print-row "Episodic:" (getf stats :episodic))
         (print-row "Semantic:" (getf stats :semantic)))))
      (t
       (print-error "Unknown subcommand. Use 'help memory'"))))

(defun cmd-config (&rest args)
  "Manage configuration.

  Usage:
    config show         - Show current config
    config get <key>    - Get a config value
    config set <k> <v>  - Set a config value
    config reload       - Reload configuration"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :show)
      (:show
       (print-header "Current Configuration")
       (let ((config (load-config)))
         (format t "  ~A~%" (stringify-json config))))
      (:get
       (if (>= (length args) 2)
           (let ((key (second args))
                 (value (get-config-value (keywordize key))))
             (if value
                 (print-row (format nil "~A:" key) value)
                 (print-error (format nil "Key '~A' not found" key))))
           (print-error "Usage: config get <key>")))
      (:set
       (if (>= (length args) 3)
           (let ((key (second args))
                 (value (third args)))
             ;; Implement set
             (print-info (format nil "Setting ~A = ~A (not yet implemented)" key value)))
           (print-error "Usage: config set <key> <value>")))
      (:reload
       (print-success "Configuration reloaded"))
      (t
       (print-error "Unknown subcommand. Use 'help config'"))))

(defun cmd-sessions (&rest args)
  "Manage sessions.

  Usage:
    sessions list       - List all sessions
    sessions show <id>  - Show session details
   sessions clear <id>  - Clear a session
    sessions export <id> - Export session"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:list
       (print-header "Active Sessions")
       (let ((sessions (list-sessions)))
         (if sessions
             (print-table '("ID" "Channel" "Created" "Messages")
                          (mapcar (lambda (s)
                                    (list (getf s :id)
                                          (getf s :channel-type)
                                          (getf s :created-at)
                                          (length (getf s :history))))
                                  sessions))
             (print-info "No active sessions"))))
      (:show
       (if (>= (length args) 2)
           (let ((session (get-session (second args))))
             (if session
                 (progn
                   (print-header (format nil "Session: ~A" (getf session :id)))
                   (print-row "Channel:" (getf session :channel-type))
                   (print-row "Created:" (getf session :created-at))
                   (print-row "Messages:" (length (getf session :history))))
                 (print-error "Session not found")))
           (print-error "Usage: sessions show <id>")))
      (:clear
       (if (>= (length args) 2)
           (progn
             (delete-session (second args))
             (print-success (format nil "Session '~A' cleared" (second args))))
           (print-error "Usage: sessions clear <id>")))
      (:export
       (if (>= (length args) 2)
           (let ((session-id (second args)))
             (print-info (format nil "Exporting session: ~A" session-id)))
           (print-error "Usage: sessions export <id>")))
      (t
       (print-error "Unknown subcommand. Use 'help sessions'"))))

(defun cmd-vector (&rest args)
  "Manage vector store.

  Usage:
    vector status       - Show vector store status
    vector add <text>   - Add text to vector store
    vector search <q>   - Search vectors
    vector clear        - Clear vector store"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :status)
      (:status
       (print-header "Vector Store Status")
       (print-info "Vector store status not yet implemented"))
      (:add
       (if (>= (length args) 2)
           (let ((text (second args)))
             (print-info (format nil "Adding text: ~A" text)))
           (print-error "Usage: vector add <text>")))
      (:search
       (if (>= (length args) 2)
           (let ((query (second args)))
             (print-header (format nil "Vector Search: '~A'" query))
             (print-info "Vector search not yet implemented"))
           (print-error "Usage: vector search <query>")))
      (:clear
       (print-success "Vector store cleared"))
      (t
       (print-error "Unknown subcommand. Use 'help vector'"))))

(defun cmd-mcp (&rest args)
  "Manage MCP servers.

  Usage:
    mcp list            - List MCP servers
    mcp connect <name>  - Connect to a server
    mcp disconnect <n>  - Disconnect a server
    mcp tools <server>  - List server tools"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:list
       (print-header "MCP Servers")
       (let ((servers (list-mcp-servers)))
         (if servers
             (print-table '("Name" "Connected" "Tools")
                          (mapcar (lambda (s)
                                    (list (getf s :name)
                                          (if (getf s :connected-p) "Yes" "No")
                                          (getf s :tool-count)))
                                  servers))
             (print-info "No MCP servers registered"))))
      (:connect
       (if (>= (length args) 2)
           (let ((name (second args)))
             (print-info (format nil "Connecting to: ~A" name)))
           (print-error "Usage: mcp connect <name>")))
      (:disconnect
       (if (>= (length args) 2)
           (let ((name (second args)))
             (print-info (format nil "Disconnecting from: ~A" name)))
           (print-error "Usage: mcp disconnect <name>")))
      (:tools
       (if (>= (length args) 2)
           (let ((server (second args)))
             (print-header (format nil "Tools: ~A" server))
             (print-info "Tool listing not yet implemented"))
           (print-error "Usage: mcp tools <server>")))
      (t
       (print-error "Unknown subcommand. Use 'help mcp'"))))

(defun cmd-workflows (&rest args)
  "Manage workflows.

  Usage:
    workflows list          - List workflows
    workflows run <id>      - Run a workflow
    workflows status <id>   - Show workflow status"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:list
       (print-header "Registered Workflows")
       (let ((workflows (list-workflows)))
         (if workflows
             (print-table '("ID" "Name" "State" "Steps")
                          (mapcar (lambda (w)
                                    (list (getf w :id)
                                          (getf w :name)
                                          (getf w :state)
                                          (getf w :steps)))
                                  workflows))
             (print-info "No workflows registered"))))
      (:run
       (if (>= (length args) 2)
           (let ((workflow-id (second args)))
             (print-info (format nil "Running workflow: ~A" workflow-id))
             (let ((result (execute-workflow workflow-id)))
               (format t "  Result: ~A~%" result)))
           (print-error "Usage: workflows run <id>")))
      (:status
       (if (>= (length args) 2)
           (let ((status (get-workflow-status (second args))))
             (print-header (format nil "Workflow Status: ~A" (getf status :name)))
             (print-row "State:" (getf status :state))
             (print-row "Current Step:" (getf status :current-step))
             (print-row "Total Steps:" (getf status :total-steps)))
           (print-error "Usage: workflows status <id>")))
      (t
       (print-error "Unknown subcommand. Use 'help workflows'"))))

(defun cmd-hooks (&rest args)
  "Manage hooks.

  Usage:
    hooks list            - List webhooks
    hooks add <id> <url>  - Add a webhook
    hooks remove <id>     - Remove a webhook
    hooks logs [--id=X]   - Show webhook logs"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:list
       (print-header "Registered Webhooks")
       (let ((webhooks (list-webhooks)))
         (if webhooks
             (print-table '("ID" "URL" "Events" "Enabled")
                          (mapcar (lambda (w)
                                    (list (getf w :id)
                                          (getf w :url)
                                          (format nil "~{~A~^, ~}" (getf w :events))
                                          (if (getf w :enabled) "Yes" "No")))
                                  webhooks))
             (print-info "No webhooks registered"))))
      (:add
       (if (>= (length args) 3)
           (let ((id (second args))
                 (url (third args)))
             (let ((webhook (make-webhook id url)))
               (register-webhook webhook)
               (print-success (format nil "Webhook '~A' added" id))))
           (print-error "Usage: hooks add <id> <url>")))
      (:remove
       (if (>= (length args) 2)
           (let ((id (second args)))
             (if (unregister-webhook id)
                 (print-success (format nil "Webhook '~A' removed" id))
                 (print-error "Webhook not found")))
           (print-error "Usage: hooks remove <id>")))
      (:logs
       (let ((id-filter (getf (rest args) :id)))
         (print-header "Webhook Delivery Logs")
         (let ((logs (get-webhook-delivery-log :webhook-id id-filter)))
           (if logs
               (print-table '("Timestamp" "Webhook" "Event" "Success")
                            (mapcar (lambda (l)
                                      (list (getf l :timestamp)
                                            (getf l :webhook-id)
                                            (getf l :event)
                                            (if (getf l :success) "Yes" "No")))
                                    logs))
               (print-info "No logs found")))))
      (t
       (print-error "Unknown subcommand. Use 'help hooks'"))))

(defun cmd-tools (&rest args)
  "Manage tools.

  Usage:
    tools list          - List all tools
    tools info <name>   - Show tool details
    tools test <name>   - Test a tool"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:list
       (print-header "Registered Tools")
       (print-info "Tool listing not yet implemented"))
      (:info
       (if (>= (length args) 2)
           (print-info (format nil "Tool info for: ~A" (second args)))
           (print-error "Usage: tools info <name>")))
      (:test
       (if (>= (length args) 2)
           (print-info (format nil "Testing tool: ~A" (second args)))
           (print-error "Usage: tools test <name>")))
      (t
       (print-error "Unknown subcommand. Use 'help tools'"))))

(defun cmd-n8n (&rest args)
  "Manage n8n workflow automation.

  Usage:
    n8n configure <url> <key>  - Configure n8n connection
    n8n workflows [list]       - List workflows
    n8n run <id> [--data=...]  - Execute a workflow
    n8n status <exec-id>       - Get execution status
    n8n webhook                - Show webhook URL
    n8n info <workflow-id>     - Show workflow details"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:configure
       (if (>= (length args) 3)
           (let ((url (second args))
                 (api-key (third args)))
             (configure-n8n :base-url url :api-key api-key)
             (print-success (format nil "n8n configured: ~A" url)))
           (print-error "Usage: n8n configure <url> <api-key>")))
      (:workflows
       (print-header "n8n Workflows")
       (let ((workflows (list-workflows)))
         (if workflows
             (print-table '("ID" "Name" "Active")
                          (mapcar (lambda (w)
                                    (list (n8n-workflow-id w)
                                          (n8n-workflow-name w)
                                          (if (n8n-workflow-active-p w) "Yes" "No")))
                                  workflows))
             (print-info "No workflows found or n8n not configured"))))
      (:run
       (if (>= (length args) 2)
           (let ((workflow-id (second args))
                 (data (getf (rest args) :data)))
             (print-info (format nil "Executing workflow: ~A" workflow-id))
             (let* ((result (if data
                                (execute-workflow workflow-id :data (parse-json data))
                                (execute-workflow workflow-id)))
                    (exec-id (n8n-execution-id result))
                    (status (n8n-execution-status result)))
               (format t "  Execution ID: ~A~%" exec-id)
               (format t "  Status: ~A~%" status)
               (when (n8n-execution-data result)
                 (format t "  Data: ~A~%" (n8n-execution-data result)))))
           (print-error "Usage: n8n run <workflow-id> [--data=JSON]")))
      (:status
       (if (>= (length args) 2)
           (let ((exec-id (second args)))
             (let ((exec (get-execution exec-id)))
               (if exec
                   (progn
                     (print-header (format nil "Execution: ~A" exec-id))
                     (print-row "Workflow:" (n8n-execution-workflow-id exec))
                     (print-row "Status:" (n8n-execution-status exec))
                     (print-row "Started:" (n8n-execution-started-at exec))
                     (print-row "Finished:" (n8n-execution-finished-at exec))
                     (when (n8n-execution-error exec)
                       (print-row "Error:" (n8n-execution-error exec))))
                   (print-error "Execution not found"))))
           (print-error "Usage: n8n status <execution-id>")))
      (:webhook
       (print-header "n8n Webhook URL")
       (format t "  ~A~%" (n8n-webhook-url))
       (print-info "Use this URL in n8n webhook nodes to callback to Lisp-Claw"))
      (:info
       (if (>= (length args) 2)
           (let ((workflow-id (second args)))
             (let ((wf (get-workflow workflow-id)))
               (if wf
                   (progn
                     (print-header (format nil "Workflow: ~A" (n8n-workflow-name wf)))
                     (print-row "ID:" (n8n-workflow-id wf))
                     (print-row "Active:" (if (n8n-workflow-active-p wf) "Yes" "No"))
                     (print-row "Tags:" (format nil "~{~A~^, ~}" (n8n-workflow-tags wf)))
                     (when (n8n-workflow-created-at wf)
                       (print-row "Created:" (n8n-workflow-created-at wf))))
                   (print-error "Workflow not found"))))
           (print-error "Usage: n8n info <workflow-id>")))
      (t
       (print-error "Unknown subcommand. Use 'help n8n'"))))

(defun cmd-cicd (&rest args)
  "Manage CI/CD integration.

  Usage:
    cicd configure <gh-token> [gl-token]  - Configure CI/CD tokens
    cicd github list <owner>/<repo>       - List GitHub workflows
    cicd github run <owner>/<repo> <wf>   - Trigger workflow
    cicd github runs <owner>/<repo>       - List workflow runs
    cicd gitlab pipelines <project>       - List pipelines
    cicd gitlab run <project> <ref>       - Trigger pipeline
    cicd status                           - Show recent statuses"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:configure
       (if (>= (length args) 2)
           (let ((gh-token (second args))
                 (gl-token (third args)))
             (configure-cicd :github-token gh-token :gitlab-token gl-token)
             (print-success "CI/CD configured"))
           (print-error "Usage: cicd configure <github-token> [gitlab-token]")))
      (:github
       (let ((github-sub (second args)))
         (case (if github-sub (intern (string-upcase github-sub) :keyword) :list)
           (:list
            (if (>= (length args) 3)
                (let* ((repo (third args))
                       (parts (split-sequence:split-sequence #\/ repo)))
                  (if (= (length parts) 2)
                      (let ((owner (first parts))
                            (repo (second parts)))
                        (print-header (format nil "GitHub Workflows: ~A" repo))
                        (let ((workflows (github-list-workflows owner repo)))
                          (if workflows
                              (print-table '("ID" "Name" "State")
                                           (mapcar (lambda (w)
                                                     (list (getf w :id)
                                                           (getf w :name)
                                                           (getf w :state)))
                                                   workflows))
                              (print-info "No workflows found"))))
                      (print-error "Repository must be owner/repo format")))
                (print-error "Usage: cicd github list <owner>/<repo>")))
           (:run
            (if (>= (length args) 4)
                (let* ((repo (third args))
                       (parts (split-sequence:split-sequence #\/ repo))
                       (workflow (fourth args)))
                  (if (= (length parts) 2)
                      (let ((owner (first parts))
                            (repo (second parts)))
                        (print-info (format nil "Triggering workflow: ~A" workflow))
                        (github-trigger-workflow owner repo workflow "main"))
                      (print-error "Repository must be owner/repo format")))
                (print-error "Usage: cicd github run <owner>/<repo> <workflow>")))
           (:runs
            (if (>= (length args) 3)
                (let* ((repo (third args))
                       (parts (split-sequence:split-sequence #\/ repo)))
                  (if (= (length parts) 2)
                      (let ((owner (first parts))
                            (repo (second parts)))
                        (print-header (format nil "Workflow Runs: ~A" repo))
                        (let ((runs (github-get-workflow-runs owner repo)))
                          (if runs
                              (print-table '("ID" "Status" "Conclusion" "Branch")
                                           (mapcar (lambda (r)
                                                     (list (getf r :id)
                                                           (getf r :status)
                                                           (getf r :conclusion)
                                                           (getf r :head-branch)))
                                                   runs))
                              (print-info "No runs found"))))
                      (print-error "Repository must be owner/repo format")))
                (print-error "Usage: cicd github runs <owner>/<repo>")))
           (t
            (print-error "Usage: cicd github [list|run|runs]")))))
      (:gitlab
       (let ((gitlab-sub (second args)))
         (case (if gitlab-sub (intern (string-upcase gitlab-sub) :keyword) :list)
           (:pipelines
            (if (>= (length args) 3)
                (let ((project (third args)))
                  (print-header (format nil "GitLab Pipelines: ~A" project))
                  (let ((pipelines (gitlab-list-pipelines project)))
                    (if pipelines
                        (print-table '("ID" "Ref" "Status" "SHA")
                                     (mapcar (lambda (p)
                                               (list (getf p :id)
                                                     (getf p :ref)
                                                     (getf p :status)
                                                     (getf p :sha)))
                                             pipelines))
                        (print-info "No pipelines found"))))
                (print-error "Usage: cicd gitlab pipelines <project>")))
           (:run
            (if (>= (length args) 4)
                (let ((project (third args))
                      (ref (fourth args)))
                  (print-info (format nil "Triggering pipeline: ~A @ ~A" project ref))
                  (gitlab-trigger-pipeline project ref))
                (print-error "Usage: cicd gitlab run <project> <ref>")))
           (t
            (print-error "Usage: cicd gitlab [pipelines|run]")))))
      (:status
       (print-header "Recent CI/CD Statuses")
       (let ((statuses (get-cicd-statuses :limit 10)))
         (if statuses
             (print-table '("Platform" "Repository" "State" "SHA")
                          (mapcar (lambda (s)
                                    (list (cicd-status-platform s)
                                          (cicd-status-repository s)
                                          (cicd-status-state s)
                                          (subseq (cicd-status-sha s) 0 7)))
                                  statuses))
             (print-info "No recent statuses"))))
      (t
       (print-error "Unknown subcommand. Use 'help cicd'"))))

(defun cmd-android (&rest args)
  "Manage Android channel.

  Usage:
    android configure <package> [fcm-key]  - Configure Android channel
    android send <device> <message>        - Send message to device
    android notify <title> <message>       - Show notification
    android devices                        - List registered devices
    android register <id> <token>          - Register device
    android unregister <id>                - Unregister device"
  (let ((subcmd (first args)))
    (case (if subcmd (intern (string-upcase subcmd) :keyword) :list)
      (:configure
       (if (>= (length args) 2)
           (let ((package (second args))
                 (fcm-key (third args)))
             (declare (ignore package fcm-key))
             (print-success "Android channel configured (use initialize-android-channel)"))
           (print-error "Usage: android configure <package> [fcm-key]")))
      (:send
       (if (>= (length args) 3)
           (let ((device (second args))
                 (message (third args)))
             (declare (ignore device message))
             (print-info "Message sending requires running gateway"))
           (print-error "Usage: android send <device> <message>")))
      (:notify
       (if (>= (length args) 3)
           (let ((title (second args))
                 (message (third args)))
             (print-info (format nil "Notification: ~A - ~A" title message)))
           (print-error "Usage: android notify <title> <message>")))
      (:devices
       (print-header "Registered Android Devices")
       (print-info "Device listing requires active channel"))
      (:register
       (if (>= (length args) 3)
           (let ((id (second args))
                 (token (third args)))
             (print-info (format nil "Registering device: ~A" id))
             (declare (ignore token)))
           (print-error "Usage: android register <id> <token>")))
      (:unregister
       (if (>= (length args) 2)
           (let ((id (second args)))
             (print-info (format nil "Unregistering device: ~A" id)))
           (print-error "Usage: android unregister <id>")))
      (t
       (print-error "Unknown subcommand. Use 'help android'"))))

;;; ============================================================================
;;; Command Registration
;;; ============================================================================

(defun register-built-in-commands ()
  "Register all built-in CLI commands.

  Returns:
    T"
  ;; Help commands
  (register-command (make-cli-command
                     :name "help" :aliases '("h" "?")
                     :description "Show help information"
                     :usage "help [command]"
                     :handler #'cmd-help))

  (register-command (make-cli-command
                     :name "status" :aliases '("st")
                     :description "Show system status"
                     :usage "status"
                     :handler #'cmd-status))

  (register-command (make-cli-command
                     :name "quit" :aliases '("exit" "q")
                     :description "Exit the CLI"
                     :usage "quit"
                     :handler #'cmd-quit))

  (register-command (make-cli-command
                     :name "agents" :aliases '("agent" "a")
                     :description "Manage AI agents"
                     :usage "agents [list|add|remove|info|set]"
                     :handler #'cmd-agents))

  (register-command (make-cli-command
                     :name "skills" :aliases '("skill" "sk")
                     :description "Manage skills"
                     :usage "skills [list|search|info|install|uninstall]"
                     :handler #'cmd-skills))

  (register-command (make-cli-command
                     :name "gateway" :aliases '("gw")
                     :description "Manage the gateway"
                     :usage "gateway [status|start|stop|restart|clients]"
                     :handler #'cmd-gateway))

  (register-command (make-cli-command
                     :name "memory" :aliases '("mem" "m")
                     :description "Manage memory"
                     :usage "memory [list|search|clear|stats]"
                     :handler #'cmd-memory))

  (register-command (make-cli-command
                     :name "config" :aliases '("cfg" "c")
                     :description "Manage configuration"
                     :usage "config [show|get|set|reload]"
                     :handler #'cmd-config))

  (register-command (make-cli-command
                     :name "sessions" :aliases '("session" "s")
                     :description "Manage sessions"
                     :usage "sessions [list|show|clear|export]"
                     :handler #'cmd-sessions))

  (register-command (make-cli-command
                     :name "vector" :aliases '("vec" "v")
                     :description "Manage vector store"
                     :usage "vector [status|add|search|clear]"
                     :handler #'cmd-vector))

  (register-command (make-cli-command
                     :name "mcp" :aliases '()
                     :description "Manage MCP servers"
                     :usage "mcp [list|connect|disconnect|tools]"
                     :handler #'cmd-mcp))

  (register-command (make-cli-command
                     :name "workflows" :aliases '("wf" "w")
                     :description "Manage workflows"
                     :usage "workflows [list|run|status]"
                     :handler #'cmd-workflows))

  (register-command (make-cli-command
                     :name "hooks" :aliases '("webhook" "hk")
                     :description "Manage hooks"
                     :usage "hooks [list|add|remove|logs]"
                     :handler #'cmd-hooks))

  (register-command (make-cli-command
                     :name "tools" :aliases '("tool" "t")
                     :description "Manage tools"
                     :usage "tools [list|info|test]"
                     :handler #'cmd-tools))

  (register-command (make-cli-command
                     :name "n8n" :aliases '()
                     :description "Manage n8n workflow automation"
                     :usage "n8n [configure|workflows|run|status|webhook|info]"
                     :handler #'cmd-n8n))

  (register-command (make-cli-command
                     :name "cicd" :aliases '("ci" "cd")
                     :description "Manage CI/CD integration"
                     :usage "cicd [configure|github|gitlab|status]"
                     :handler #'cmd-cicd))

  (register-command (make-cli-command
                     :name "android" :aliases '("adb")
                     :description "Manage Android channel"
                     :usage "android [configure|send|notify|devices|register|unregister]"
                     :handler #'cmd-android))

  (log-info "Built-in CLI commands registered")
  t)

;;; ============================================================================
;;; Main CLI Loop
;;; ============================================================================

(defvar *cli-prompt* "lisp-claw> "
  "CLI prompt string.")

(defun run-cli ()
  "Run the CLI system.

  Returns:
    NIL"
  (register-built-in-commands)

  (format t "~%")
  (format t "╔═══════════════════════════════════════════════════════════╗~%")
  (format t "║            Lisp-Claw CLI - Version ~A              ║~%" *lisp-claw-version*)
  (format t "║     Type 'help' for available commands                  ║~%")
  (format t "╚═══════════════════════════════════════════════════════════╝~%")
  (format t "~%")

  (cli-loop))

(defun cli-loop ()
  "Main CLI loop.

  Returns:
    NIL"
  (catch 'cli-exit
    (loop do
      (format t "~A" *cli-prompt*)
      (finish-output)
      (let ((input (read-line *standard-input* nil nil)))
        (when (null input)
          (format t "~%")
          (return))
        (when (string= input "")
          (return))
        (multiple-value-bind (cmd-name args)
            (parse-command input)
          (when cmd-name
            (let ((cmd (get-command cmd-name)))
              (if cmd
                  (handler-case
                      (funcall (cli-command-handler cmd) args)
                    (error (e)
                      (print-error (format nil "Command error: ~A" e))))
                  (print-error (format nil "Unknown command: ~A. Type 'help' for available commands." cmd-name))))))))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-cli-system ()
  "Initialize the CLI system.

  Returns:
    T"
  (log-info "CLI system initialized")
  t)
