;;; tui/main.lisp --- Terminal User Interface for Lisp-Claw
;;;
;;; This file implements a terminal user interface (TUI) for Lisp-Claw,
;;; similar to OpenClaw's TUI for local interaction.

(defpackage #:lisp-claw.tui
  (:nicknames #:lc.tui)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.gateway.server
        #:lisp-claw.gateway.health
        #:lisp-claw.agent.session
        #:lisp-claw.advanced.memory
        #:lisp-claw.cli)
  (:export
   ;; TUI application
   #:tui-app
   #:make-tui-app
   #:app-running-p
   #:app-current-view
   ;; Views
   #:tui-view
   #:make-view
   #:view-name
   #:view-render
   #:view-handle-input
   ;; Built-in views
   #:chat-view
   #:status-view
   #:agents-view
   #:skills-view
   #:settings-view
   ;; TUI functions
   #:run-tui
   #:stop-tui
   #:refresh-display
   #:clear-screen
   ;; Input handling
   #:read-key
   #:handle-keypress
   ;; Output formatting
   #:print-box
   #:print-header
   #:print-divider
   #:colorize))

(in-package #:lisp-claw.tui)

;;; ============================================================================
;;; TUI Application
;;; ============================================================================

(defclass tui-app ()
  ((running-p :initform nil
              :accessor app-running-p
              :documentation "Whether TUI is running")
   (current-view :initform nil
                 :accessor app-current-view
                 :documentation "Current active view")
   (views :initform (make-hash-table :test 'equal)
          :accessor app-views
          :documentation "Registered views")
   (status-bar :initform ""
               :accessor app-status-bar
               :documentation "Status bar message")
   (title :initform "Lisp-Claw TUI"
          :accessor app-title
          :documentation "Application title")
   (lock :initform (bt:make-lock)
         :reader app-lock
         :documentation "Lock for thread safety"))
  (:documentation "TUI application"))

(defmethod print-object ((app tui-app) stream)
  (print-unreadable-object (app stream :type t)
    (format stream "~A [~:*~A]"
            (app-title app)
            (if (app-running-p app) "running" "stopped"))))

(defun make-tui-app (&key title)
  "Create a TUI application.

  Args:
    TITLE: Application title

  Returns:
    TUI app instance"
  (make-instance 'tui-app :title (or title "Lisp-Claw TUI")))

;;; ============================================================================
;;; TUI View
;;; ============================================================================

(defclass tui-view ()
  ((name :initarg :name
         :reader view-name
         :documentation "View name")
   (title :initarg :title
          :initform ""
          :reader view-title
          :documentation "View title")
   (content :initform ""
            :accessor view-content
            :documentation "View content")
   (scroll-offset :initform 0
                 :accessor view-scroll-offset
                 :documentation "Scroll offset")
   (data :initform nil
         :accessor view-data
         :documentation "View-specific data"))
  (:documentation "TUI view"))

(defmethod print-object ((view tui-view) stream)
  (print-unreadable-object (view stream :type t)
    (format stream "~A" (view-name view))))

(defun make-view (name title)
  "Create a TUI view.

  Args:
    NAME: View name
    TITLE: View title

  Returns:
    TUI view instance"
  (make-instance 'tui-view :name name :title title))

(defgeneric view-render (view width height)
  (:documentation "Render view to string"))

(defgeneric view-handle-input (view key)
  (:documentation "Handle keyboard input"))

;;; ============================================================================
;;; Built-in Views
;;; ============================================================================

;; Chat View
(defclass chat-view (tui-view)
  ((messages :initform nil
             :accessor chat-view-messages
             :documentation "Chat messages")
   (input-buffer :initform ""
                 :accessor chat-view-input-buffer
                 :documentation "Current input")
   (session-id :initarg :session-id
               :reader chat-view-session-id
               :documentation "Current session ID"))
  (:documentation "Chat view"))

(defun make-chat-view (&key session-id)
  "Create a chat view.

  Args:
    SESSION-ID: Session ID

  Returns:
    Chat view instance"
  (make-instance 'chat-view
                 :name "chat"
                 :title "Chat"
                 :session-id (or session-id "main")))

(defmethod view-render ((view chat-view) width height)
  "Render chat view."
  (with-output-to-string (s)
    ;; Title bar
    (format s "~A~%" (make-string width :initial-element #\=))
    (format s " ~A~%" (view-title view))
    (format s "~A~%" (make-string width :initial-element #\=))

    ;; Messages area
    (let ((msg-height (- height 5)))
      (format s "~%")
      (dolist (msg (subseq (chat-view-messages view)
                           0
                           (min msg-height (length (chat-view-messages view)))))
        (let ((role (getf msg :role))
              (content (getf msg :content)))
          (cond
            ((string= role "user")
             (format s "  You: ~A~%" content))
            ((string= role "assistant")
             (format s "  Agent: ~A~%" content))
            (t
             (format s "  ~A~%" content))))))

    ;; Input area
    (format s "~%~A~%" (make-string width :initial-element #\-))
    (format s "> ~A~%" (chat-view-input-buffer view))))

(defmethod view-handle-input ((view chat-view) key)
  "Handle chat view input."
  (cond
    ((char= key #\Newline)
     ;; Send message
     (let ((input (chat-view-input-buffer view)))
       (when (string/= input "")
         ;; Add to messages
         (push (list :role "user" :content input)
               (chat-view-messages view))
         ;; Clear buffer
         (setf (chat-view-input-buffer view) "")
         ;; Process response (simplified)
         (push (list :role "assistant" :content "Response placeholder")
               (chat-view-messages view)))))
    ((char= key #\Backspace)
     ;; Delete last character
     (when (> (length (chat-view-input-buffer view)) 0)
       (setf (chat-view-input-buffer view)
             (subseq (chat-view-input-buffer view) 0 (1- (length (chat-view-input-buffer view)))))))
    ((and (characterp key)
          (char>= key #\Space)
          (char<= key #\~))
     ;; Add character to input
     (setf (chat-view-input-buffer view)
           (concatenate 'string (chat-view-input-buffer view) (string key)))))
  view)

;; Status View
(defclass status-view (tui-view)
  ()
  (:documentation "Status view"))

(defun make-status-view ()
  "Create a status view."
  (make-instance 'status-view :name "status" :title "System Status"))

(defmethod view-render ((view status-view) width height)
  "Render status view."
  (with-output-to-string (s)
    ;; Title bar
    (format s "~A~%" (make-string width :initial-element #\=))
    (format s " ~A~%" (view-title view))
    (format s "~A~%" (make-string width :initial-element #\=))

    ;; Get system status
    (let ((health (get-health-status)))
      (format s "~%")
      (format s "  Status:   ~A~%" (getf health :status))
      (format s "  Clients:  ~A~%" (getf health :clients))
      (format s "  Memory:   ~A~%" (getf health :memory))
      (format s "  Uptime:   ~A seconds~%" (- (get-universal-time) *lisp-claw-start-time*)))

    ;; Agents status
    (format s "~%  Agents:~%")
    (let ((agents (list-agents)))
      (if agents
          (dolist (agent agents)
            (format s "    ~A (~A): ~A~%"
                    (getf agent :name)
                    (getf agent :role)
                    (getf agent :state)))
          (format s "    No agents registered~%")))

    ;; Workflows status
    (format s "~%  Workflows:~%")
    (let ((workflows (list-workflows)))
      (if workflows
          (dolist (wf workflows)
            (format s "    ~A: ~A~%"
                    (getf wf :name)
                    (getf wf :state)))
          (format s "    No workflows registered~%")))))

(defmethod view-handle-input ((view status-view) key)
  "Handle status view input."
  ;; Refresh on any key
  view)

;; Agents View
(defclass agents-view (tui-view)
  ((selected-agent :initform nil
                   :accessor agents-view-selected
                   :documentation "Selected agent"))
  (:documentation "Agents view"))

(defun make-agents-view ()
  "Create an agents view."
  (make-instance 'agents-view :name "agents" :title "Agent Management"))

(defmethod view-render ((view agents-view) width height)
  "Render agents view."
  (with-output-to-string (s)
    ;; Title bar
    (format s "~A~%" (make-string width :initial-element #\=))
    (format s " ~A~%" (view-title view))
    (format s "~A~%" (make-string width :initial-element #\=))

    ;; Agents list
    (format s "~%  Registered Agents:~%~%")
    (let ((agents (list-agents)))
      (if agents
          (let ((idx 0))
            (dolist (agent agents)
              (let ((selected (eq agent (agents-view-selected view))))
                (format s "  ~A ~A (~A) - ~A~%"
                        (if selected ">" " ")
                        (getf agent :name)
                        (getf agent :id)
                        (getf agent :state))
                (incf idx))))
          (format s "    No agents registered~%")))

    ;; Help
    (format s "~%~%  [n]ew agent  [d]elete  [r]efresh  [q]uit~%")))

(defmethod view-handle-input ((view agents-view) key)
  "Handle agents view input."
  (cond
    ((char= key #\q)
     ;; Quit view
     )
    ((char= key #\r)
     ;; Refresh
     )
    ((char= key #\n)
     ;; New agent (placeholder)
     ))
  view)

;; Skills View
(defclass skills-view (tui-view)
  ()
  (:documentation "Skills view"))

(defun make-skills-view ()
  "Create a skills view."
  (make-instance 'skills-view :name "skills" :title "Skills Management"))

(defmethod view-render ((view skills-view) width height)
  "Render skills view."
  (with-output-to-string (s)
    ;; Title bar
    (format s "~A~%" (make-string width :initial-element #\=))
    (format s " ~A~%" (view-title view))
    (format s "~A~%" (make-string width :initial-element #\=))

    ;; Skills list
    (format s "~%  Installed Skills:~%~%")
    (let ((skills (list-skills)))
      (if skills
          (dolist (skill skills)
            (format s "  ~A v~A by ~A~%"
                    (getf skill :name)
                    (getf skill :version)
                    (getf skill :author)))
          (format s "    No skills installed~%")))

    ;; Help
    (format s "~%~%  [i]nstall  [u]ninstall  [r]efresh  [q]uit~%")))

(defmethod view-handle-input ((view skills-view) key)
  "Handle skills view input."
  (cond
    ((char= key #\q)
     ;; Quit view
     )
    ((char= key #\r)
     ;; Refresh
     )
    ((char= key #\i)
     ;; Install (placeholder)
     ))
  view)

;; Settings View
(defclass settings-view (tui-view)
  ()
  (:documentation "Settings view"))

(defun make-settings-view ()
  "Create a settings view."
  (make-instance 'settings-view :name "settings" :title "Settings"))

(defmethod view-render ((view settings-view) width height)
  "Render settings view."
  (with-output-to-string (s)
    ;; Title bar
    (format s "~A~%" (make-string width :initial-element #\=))
    (format s " ~A~%" (view-title view))
    (format s "~A~%" (make-string width :initial-element #\=))

    ;; Settings
    (format s "~%  Configuration:~%~%")
    (format s "  Gateway Port:    ~A~%" *gateway-port*)
    (format s "  Gateway Bind:    ~A~%" *gateway-bind*)
    (format s "  CLI Prompt:      ~A~%" *cli-prompt*)

    ;; Help
    (format s "~%~%  [e]dit  [s]ave  [q]uit~%")))

(defmethod view-handle-input ((view settings-view) key)
  "Handle settings view input."
  (cond
    ((char= key #\q)
     ;; Quit view
     )
    ((char= key #\e)
     ;; Edit (placeholder)
     ))
  view)

;;; ============================================================================
;;; TUI Functions
;;; ============================================================================

(defvar *tui-app* nil
  "Default TUI application instance.")

(defun run-tui ()
  "Run the TUI application.

  Returns:
    NIL"
  (setf *tui-app* (make-tui-app))

  ;; Register views
  (let ((app *tui-app*))
    (setf (gethash "chat" (app-views app)) (make-chat-view))
    (setf (gethash "status" (app-views app)) (make-status-view))
    (setf (gethash "agents" (app-views app)) (make-agents-view))
    (setf (gethash "skills" (app-views app)) (make-skills-view))
    (setf (gethash "settings" (app-views app)) (make-settings-view))

    ;; Set default view
    (setf (app-current-view app) (gethash "status" (app-views app))))

  (setf (app-running-p *tui-app*) t)

  (format t "~%")
  (format t "╔═══════════════════════════════════════════╗~%")
  (format t "║        Lisp-Claw TUI Interface            ║~%")
  (format t "║  Views: status, chat, agents, skills      ║~%")
  (format t "║  Press 'q' to quit, 'h' for help          ║~%")
  (format t "╚═══════════════════════════════════════════╝~%")
  (format t "~%")

  ;; Main loop
  (catch 'tui-exit
    (loop while (app-running-p *tui-app*)
          do (progn
               (refresh-display)
               (let ((key (read-key)))
                 (handle-keypress key)))))

  (format t "~%Goodbye!~%")
  nil)

(defun stop-tui ()
  "Stop the TUI application.

  Returns:
    T"
  (when *tui-app*
    (setf (app-running-p *tui-app*) nil))
  t)

(defun refresh-display ()
  "Refresh the display.

  Returns:
    T"
  (clear-screen)

  (when *tui-app*
    (let* ((app *tui-app*)
           (view (app-current-view app))
           (width 80)
           (height 24))

      (when view
        (format t "~A" (view-render view width height)))

      ;; Status bar
      (format t "~%~A~%" (make-string width :initial-element #\=))
      (format t " ~A | View: ~A | Press 'h' for help"
              (app-title app)
              (if view (view-name view) "none"))))

  (finish-output)
  t)

(defun clear-screen ()
  "Clear the screen.

  Returns:
    T"
  ;; ANSI escape codes for clearing screen
  (format t "~C[2J~C[H" #\Esc #\Esc)
  t)

;;; ============================================================================
;;; Input Handling
;;; ============================================================================

(defun read-key ()
  "Read a single keypress.

  Returns:
    Character or string"
  ;; Simple implementation - in production use curses library
  (let ((key (read-char *standard-input* nil nil)))
    (if key
        (string key)
        "")))

(defun handle-keypress (key)
  "Handle a keypress.

  Args:
    KEY: Key pressed

  Returns:
    T"
  (when (and *tui-app* (app-current-view *tui-app*))
    (let ((view (app-current-view *tui-app*)))
      (cond
        ;; Global shortcuts
        ((char= key "q")
         ;; Check if in main view
         (when (string= (view-name view) "status")
           (stop-tui)
           (throw 'tui-exit t)))

        ((char= key "h")
         ;; Show help
         (show-help))

        ((char= key "1")
         ;; Switch to status view
         (setf (app-current-view *tui-app*) (gethash "status" (app-views *tui-app*))))

        ((char= key "2")
         ;; Switch to chat view
         (setf (app-current-view *tui-app*) (gethash "chat" (app-views *tui-app*))))

        ((char= key "3")
         ;; Switch to agents view
         (setf (app-current-view *tui-app*) (gethash "agents" (app-views *tui-app*))))

        ((char= key "4")
         ;; Switch to skills view
         (setf (app-current-view *tui-app*) (gethash "skills" (app-views *tui-app*))))

        ((char= key "5")
         ;; Switch to settings view
         (setf (app-current-view *tui-app*) (gethash "settings" (app-views *tui-app*))))

        (t
         ;; Pass to view
         (view-handle-input view key))))))

(defun show-help ()
  "Show help dialog.

  Returns:
    T"
  (format t "~%")
  (format t "╔═══════════════════════════════════════════╗~%")
  (format t "║              Keyboard Shortcuts           ║~%")
  (format t "╠═══════════════════════════════════════════╣~%")
  (format t "║  1 - Status View                          ║~%")
  (format t "║  2 - Chat View                            ║~%")
  (format t "║  3 - Agents View                          ║~%")
  (format t "║  4 - Skills View                          ║~%")
  (format t "║  5 - Settings View                        ║~%")
  (format t "║  h - Show Help                            ║~%")
  (format t "║  q - Quit (from status view)              ║~%")
  (format t "╚═══════════════════════════════════════════╝~%")
  (format t "~%Press any key to continue...")
  (read-key)
  t)

;;; ============================================================================
;;; Output Formatting
;;; ============================================================================

(defun print-box (content &key title width border-style)
  "Print content in a box.

  Args:
    CONTENT: Content string
    TITLE: Optional title
    WIDTH: Box width
    BORDER-STYLE: Border style

  Returns:
    Formatted string"
  (let ((w (or width 60))
        (lines (split-sequence:split-sequence #\Newline content)))
    (with-output-to-string (s)
      ;; Top border
      (format s "+")
      (dotimes (i (- w 2)) (format s "-"))
      (format s "+~%")

      ;; Title
      (when title
        (format s "| ~A" title)
        (dotimes (i (- w 3 (length title))) (format s " "))
        (format s "|~%")
        (format s "+")
        (dotimes (i (- w 2)) (format s "-"))
        (format s "+~%"))

      ;; Content
      (dolist (line lines)
        (format s "| ~A" line)
        (dotimes (i (- w 3 (length line))) (format s " "))
        (format s "|~%"))

      ;; Bottom border
      (format s "+")
      (dotimes (i (- w 2)) (format s "-"))
      (format s "+~%"))))

(defun print-header (text)
  "Print a header.

  Args:
    TEXT: Header text

  Returns:
    T"
  (format t "~%~A~%" (make-string 60 :initial-element #\=))
  (format t "  ~A~%" text)
  (format t "~A~%" (make-string 60 :initial-element #\=))
  t)

(defun print-divider ()
  "Print a divider.

  Returns:
    T"
  (format t "~%~A~%" (make-string 60 :initial-element #\-))
  t)

(defun colorize (text color)
  "Colorize text using ANSI codes.

  Args:
    TEXT: Text to colorize
    COLOR: Color name (red, green, yellow, blue, cyan, white)

  Returns:
    Colorized text"
  (let ((codes (case (if (keywordp color) color (intern (string-upcase color) :keyword))
                 (:red "31")
                 (:green "32")
                 (:yellow "33")
                 (:blue "34")
                 (:cyan "36")
                 (:white "37")
                 (otherwise "0"))))
    (format nil "~C[~Am~A~C[0m" #\Esc codes text #\Esc)))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-tui-system ()
  "Initialize the TUI system.

  Returns:
    T"
  (log-info "TUI system initialized")
  t)
