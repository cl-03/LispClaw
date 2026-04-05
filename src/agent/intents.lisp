;;; agent/intents.lisp --- Intents Recognition and Routing for Lisp-Claw
;;;
;;; This file implements intent recognition and routing system,
;;; similar to OpenClaw's intents system.

(defpackage #:lisp-claw.agent.intents
  (:nicknames #:lc.agent.intents)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.helpers)
  (:export
   ;; Intent class
   #:intent
   #:make-intent
   #:intent-name
   #:intent-patterns
   #:intent-handler
   #:intent-priority
   #:intent-enabled-p
   ;; Intent registry
   #:*intent-registry*
   #:register-intent
   #:unregister-intent
   #:get-intent
   #:list-intents
   ;; Intent recognition
   #:recognize-intent
   #:extract-entities
   #:match-intent
   ;; Intent routing
   #:route-message
   #:handle-intent
   ;; Built-in intents
   #:register-built-in-intents
   ;; Entity extraction
   #:entity
   #:make-entity
   #:entity-name
   #:entity-type
   #:entity-value
   #:entity-confidence))

(in-package #:lisp-claw.agent.intents)

;;; ============================================================================
;;; Entity Class
;;; ============================================================================

(defstruct entity
  "Represents an extracted entity from text."
  (name "" :type string)
  (type "" :type string)
  (value nil)
  (confidence 1.0 :type float)
  (start-position 0 :type integer)
  (end-position 0 :type integer))

(defmethod print-object ((entity entity) stream)
  (print-unreadable-object (entity stream :type t)
    (format stream "~A:~A = ~A (~,2f)"
            (entity-name entity)
            (entity-type entity)
            (entity-value entity)
            (entity-confidence entity))))

(defun make-entity (name type value &key confidence start end)
  "Create an entity.

  Args:
    NAME: Entity name
    TYPE: Entity type
    VALUE: Entity value
    CONFIDENCE: Confidence score (0-1)
    START: Start position in text
    END: End position in text

  Returns:
    Entity instance"
  (make-entity-struct
   :name name
   :type type
   :value value
   :confidence (or confidence 1.0)
   :start-position (or start 0)
   :end-position (or end 0)))

;;; ============================================================================
;;; Intent Class
;;; ============================================================================

(defclass intent ()
  ((name :initarg :name
         :reader intent-name
         :documentation "Unique intent identifier")
   (patterns :initarg :patterns
             :initform nil
             :reader intent-patterns
             :documentation "List of patterns that match this intent")
   (handler :initarg :handler
            :reader intent-handler
            :documentation "Handler function for this intent")
   (priority :initarg :priority
             :initform 0
             :reader intent-priority
             :documentation "Priority (higher = matched first)")
   (entities :initarg :entities
             :initform nil
             :reader intent-entities
             :documentation "Expected entities for this intent")
   (enabled-p :initform t
              :accessor intent-enabled-p
              :documentation "Whether intent is enabled")
   (description :initarg :description
                :initform ""
                :reader intent-description
                :documentation "Intent description")
   (examples :initarg :examples
             :initform nil
             :reader intent-examples
             :documentation "Example utterances"))
  (:documentation "Intent for message classification"))

(defmethod print-object ((intent intent) stream)
  (print-unreadable-object (intent stream :type t)
    (format stream "~A [~:*~A]" (intent-name intent)
            (if (intent-enabled-p intent) "enabled" "disabled"))))

(defun make-intent (name handler &key patterns priority entities description examples)
  "Create an intent.

  Args:
    NAME: Intent name
    HANDLER: Handler function
    PATTERNS: List of patterns (strings or regex)
    PRIORITY: Matching priority
    ENTITIES: Expected entities
    DESCRIPTION: Intent description
    EXAMPLES: Example utterances

  Returns:
    Intent instance"
  (make-instance 'intent
                 :name name
                 :handler handler
                 :patterns (or patterns nil)
                 :priority (or priority 0)
                 :entities (or entities nil)
                 :description (or description "")
                 :examples (or examples nil)))

;;; ============================================================================
;;; Intent Registry
;;; ============================================================================

(defvar *intent-registry* (make-hash-table :test 'equal)
  "Registry of configured intents.")

(defvar *intent-lock* (bt:make-lock)
  "Lock for intent registry access.")

(defun register-intent (intent)
  "Register an intent.

  Args:
    INTENT: Intent instance

  Returns:
    T on success"
  (bt:with-lock-held (*intent-lock*)
    (setf (gethash (intent-name intent) *intent-registry*) intent)
    (log-info "Registered intent: ~A" (intent-name intent))
    t))

(defun unregister-intent (name)
  "Unregister an intent.

  Args:
    NAME: Intent name

  Returns:
    T on success"
  (bt:with-lock-held (*intent-lock*)
    (when (gethash name *intent-registry*)
      (remhash name *intent-registry*)
      (log-info "Unregistered intent: ~A" name)
      t)))

(defun get-intent (name)
  "Get an intent by name.

  Args:
    NAME: Intent name

  Returns:
    Intent instance or NIL"
  (gethash name *intent-registry*))

(defun list-intents ()
  "List all registered intents.

  Returns:
    List of intent info"
  (let ((intents nil))
    (bt:with-lock-held (*intent-lock*)
      (maphash (lambda (name intent)
                 (push (list :name name
                             :priority (intent-priority intent)
                             :enabled (intent-enabled-p intent)
                             :patterns (intent-patterns intent)
                             :description (intent-description intent))
                       intents))
               *intent-registry*))
    (sort intents #'> :key #'getf)))

;;; ============================================================================
;;; Intent Recognition
;;; ============================================================================

(defun match-pattern (text pattern)
  "Match text against a pattern.

  Args:
    TEXT: Input text
    PATTERN: Pattern string or regex

  Returns:
    Match result plist or NIL"
  (handler-case
      (cond
        ;; String pattern (simple contains)
        ((stringp pattern)
         (when (search pattern text :test #'char-equal)
           (list :matched t :pattern pattern :confidence 0.7)))
        ;; Regex pattern
        ((typep pattern 'cl-ppcre:regex)
         (let ((matches (cl-ppcre:scan-to-strings pattern text)))
           (when matches
             (list :matched t
                   :pattern pattern
                   :confidence 0.9
                   :groups (multiple-value-list matches)))))
        ;; List pattern (keywords to match)
        ((listp pattern)
         (let ((matched (find-if (lambda (kw)
                                   (search (string kw) text :test #'char-equal))
                                 pattern)))
           (when matched
             (list :matched t :pattern matched :confidence 0.8))))
        (t nil))
    (error (e)
      (log-warn "Pattern match error: ~A" e)
      nil)))

(defun recognize-intent (text &key context)
  "Recognize intent from text.

  Args:
    TEXT: Input text
    CONTEXT: Optional context plist

  Returns:
    Intent match result or NIL"
  (declare (ignore context))
  (let ((best-match nil)
        (best-confidence 0.0)
        (best-intent nil)
        (entities nil))

    ;; Get sorted intents by priority
    (let ((sorted-intents
           (sort (copy-list (list-intents)) #'> :key #'getf)))
      (dolist (intent-info sorted-intents)
        (let* ((name (getf intent-info :name))
               (intent (get-intent name)))
          (when (and intent (intent-enabled-p intent))
            (dolist (pattern (intent-patterns intent))
              (let ((match (match-pattern text pattern)))
                (when (and match (getf match :matched))
                  (let ((confidence (getf match :confidence)))
                    (when (> confidence best-confidence)
                      (setf best-confidence confidence
                            best-match match
                            best-intent intent))))))))))

    ;; Extract entities if intent found
    (when best-intent
      (setf entities (extract-entities text best-intent)))

    (when best-intent
      (list :intent best-intent
            :confidence best-confidence
            :match best-match
            :entities entities))))

(defun extract-entities (text intent)
  "Extract entities from text for an intent.

  Args:
    TEXT: Input text
    INTENT: Intent instance

  Returns:
    List of entities"
  (let ((entities nil)
        (expected (intent-entities intent)))

    ;; Extract common entity types
    ;; Dates
    (let ((date-pattern "\\d{4}-\\d{2}-\\d{2}|\\d{2}/\\d{2}/\\d{4}"))
      (when (cl-ppcre:scan date-pattern text)
        (let ((start (cl-ppcre:scan date-pattern text)))
          (when start
            (push (make-entity "date" "date"
                               (cl-ppcre:register-groups-bind (match)
                                   (date-pattern text)
                                 match)
                               :confidence 0.9
                               :start start
                               :end (+ start (length match)))
                  entities)))))

    ;; Numbers
    (let ((number-pattern "\\d+"))
      (dotimes (i (length text))
        (when (cl-ppcre:scan number-pattern (subseq text i))
          (let* ((start i)
                 (match (cl-ppcre:register-groups-bind (n) (number-pattern (subseq text i)) n))
                 (end (+ start (length match))))
            (push (make-entity "number" "number"
                               (parse-integer match)
                               :confidence 0.95
                               :start start
                               :end end)
                  entities)
            (return))))

    ;; Email addresses
    (let ((email-pattern "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"))
      (when (cl-ppcre:scan email-pattern text)
        (let ((start (cl-ppcre:scan email-pattern text)))
          (when start
            (let ((match (cl-ppcre:register-groups-bind (m) (email-pattern text) m)))
              (push (make-entity "email" "contact"
                                 match
                                 :confidence 0.95
                                 :start start
                                 :end (+ start (length match)))
                    entities))))))

    ;; Phone numbers (simple)
    (let ((phone-pattern "\\d{3}[-.]?\\d{3}[-.]?\\d{4}"))
      (when (cl-ppcre:scan phone-pattern text)
        (let ((start (cl-ppcre:scan phone-pattern text)))
          (when start
            (let ((match (cl-ppcre:register-groups-bind (p) (phone-pattern text) p)))
              (push (make-entity "phone" "contact"
                                 match
                                 :confidence 0.9
                                 :start start
                                 :end (+ start (length match)))
                    entities))))))

    (nreverse entities)))

(defun match-intent (text intent-name)
  "Check if text matches a specific intent.

  Args:
    TEXT: Input text
    INTENT-NAME: Intent name to check

  Returns:
    T if matches, NIL otherwise"
  (let ((intent (get-intent intent-name)))
    (unless intent
      (return-from match-intent nil))

    (dolist (pattern (intent-patterns intent))
      (when (match-pattern text pattern)
        (return-from match-intent t)))
    nil))

;;; ============================================================================
;;; Intent Routing
;;; ============================================================================

(defvar *intent-handlers* (make-hash-table :test 'equal)
  "Additional intent handlers.")

(defun route-message (message &key session context)
  "Route a message to the appropriate intent handler.

  Args:
    MESSAGE: Message plist
    SESSION: Session info
    CONTEXT: Context plist

  Returns:
    Handler result"
  (let* ((text (getf message :text))
         (result (recognize-intent text :context context)))

    (if result
        (let* ((intent (getf result :intent))
               (entities (getf result :entities))
               (handler (intent-handler intent)))
          (log-info "Routed to intent: ~A (confidence: ~,2f)"
                    (intent-name intent)
                    (getf result :confidence))

          ;; Call handler
          (handler-case
              (funcall handler message :entities entities :session session :context context)
            (error (e)
              (log-error "Intent handler error: ~A" e)
              (list :status :error :message (format nil "~A" e)))))

        ;; No intent matched - return as unknown
        (progn
          (log-debug "No intent matched for: ~A" text)
          (list :status :unknown :text text)))))

(defun handle-intent (intent-name message &key entities session context)
  "Handle a specific intent.

  Args:
    INTENT-NAME: Intent name
    MESSAGE: Message plist
    ENTITIES: Extracted entities
    SESSION: Session info
    CONTEXT: Context plist

  Returns:
    Handler result"
  (let ((intent (get-intent intent-name)))
    (unless intent
      (return-from handle-intent
        (list :status :error :message "Intent not found")))

    (let ((handler (intent-handler intent)))
      (handler-case
          (funcall handler message
                   :entities (or entities nil)
                   :session session
                   :context context)
        (error (e)
          (log-error "Intent handler error: ~A" e)
          (list :status :error :message (format nil "~A" e)))))))

;;; ============================================================================
;;; Built-in Intents
;;; ============================================================================

(defun register-greeting-intent ()
  "Register greeting intent.

  Returns:
    T"
  (register-intent
   (make-intent
    "greeting"
    (lambda (message &key entities session context)
      (declare (ignore entities session context))
      (list :status :success
            :response "Hello! How can I help you today?"))
    :patterns '("hello" "hi" "hey" "good morning" "good afternoon"
                "good evening" "greetings" "yo")
    :priority 10
    :description "Greeting messages"
    :examples '("Hello there!" "Hi, how are you?"))))

(defun register-goodbye-intent ()
  "Register goodbye intent.

  Returns:
    T"
  (register-intent
   (make-intent
    "goodbye"
    (lambda (message &key entities session context)
      (declare (ignore entities session context))
      (list :status :success
            :response "Goodbye! Have a great day!"))
    :patterns '("goodbye" "bye" "see you" "later" "quit" "exit"
                "good night" "take care")
    :priority 10
    :description "Goodbye messages"
    :examples '("Bye!" "See you later!"))))

(defun register-thanks-intent ()
  "Register thanks intent.

  Returns:
    T"
  (register-intent
   (make-intent
    "thanks"
    (lambda (message &key entities session context)
      (declare (ignore entities session context))
      (list :status :success
            :response "You're welcome!"))
    :patterns '("thank" "thanks" "thank you" "thx" "appreciate")
    :priority 10
    :description "Thank you messages"
    :examples '("Thanks!" "Thank you very much!"))))

(defun register-help-intent ()
  "Register help intent.

  Returns:
    T"
  (register-intent
   (make-intent
    "help"
    (lambda (message &key entities session context)
      (declare (ignore entities session context))
      (list :status :success
            :response "I'm here to help! What do you need assistance with?"
            :suggestions '("Show commands" "List features" "Get status")))
    :patterns '("help" "assist" "support" "what can you do" "how to")
    :priority 9
    :description "Help requests"
    :examples '("Help me" "I need assistance"))))

(defun register-status-intent ()
  "Register status intent.

  Returns:
    T"
  (register-intent
   (make-intent
    "status"
    (lambda (message &key entities session context)
      (declare (ignore entities session context))
      (list :status :success
            :response "All systems operational."
            :system-status :ok))
    :patterns '("status" "how are you" "are you ok" "working")
    :priority 8
    :description "Status inquiries"
    :examples '("What's your status?" "Are you working?"))))

(defun register-weather-intent ()
  "Register weather intent.

  Returns:
    T"
  (register-intent
   (make-intent
    "weather"
    (lambda (message &key entities session context)
      (let ((location (find-if (lambda (e)
                                 (string= (entity-type e) "location"))
                               entities)))
        (list :status :success
              :response (if location
                            (format nil "Weather in ~A: [would fetch real data]"
                                    (entity-value location))
                            "Which location would you like weather for?")
              :location (when location (entity-value location)))))
    :patterns '("weather" "temperature" "forecast" "rain" "sunny")
    :entities '(("location" :type "location"))
    :priority 5
    :description "Weather inquiries"
    :examples '("What's the weather?" "Weather in Tokyo"))))

(defun register-time-intent ()
  "Register time intent.

  Returns:
    T"
  (register-intent
   (make-intent
    "time"
    (lambda (message &key entities session context)
      (declare (ignore entities session context))
      (list :status :success
            :response (format nil "Current time: ~A"
                              (format nil "~2,'0d:~2,'0d"
                                      (multiple-value-bind (s m h) (get-decoded-time)
                                        (declare (ignore s m))
                                        h))
                              (multiple-value-bind (s m h) (get-decoded-time)
                                (declare (ignore h s))
                                m)))))
    :patterns '("time" "what time" "clock" "hour")
    :priority 8
    :description "Time inquiries"
    :examples '("What time is it?" "Current time"))))

(defun register-date-intent ()
  "Register date intent.

  Returns:
    T"
  (register-intent
   (make-intent
    "date"
    (lambda (message &key entities session context)
      (declare (ignore entities session context))
      (multiple-value-bind (s m h d mo y) (get-decoded-time)
        (declare (ignore s m h))
        (list :status :success
              :response (format nil "Today's date: ~A/~A/~A" mo d y)))))
    :patterns '("date" "what day" "today" "tomorrow")
    :priority 8
    :description "Date inquiries"
    :examples '("What's the date?" "What day is it?"))))

(defun register-joke-intent ()
  "Register joke intent.

  Returns:
    T"
  (register-intent
   (make-intent
    "joke"
    (lambda (message &key entities session context)
      (declare (ignore entities session context))
      (let ((jokes '("Why did the Lisp programmer quit? Because he didn't get enough CONS-olation!"
                     "What do you call a Lisp programmer who doesn't recycle? Garbage collection!"
                     "Why don't Lisp programmers like golf? Too many hazards in the S-expressions!")))
        (list :status :success
              :response (nth (random (length jokes)) jokes)))))
    :patterns '("joke" "funny" "laugh" "humor" "make me laugh")
    :priority 5
    :description "Joke requests"
    :examples '("Tell me a joke" "Something funny"))))

(defun register-whoami-intent ()
  "Register whoami intent.

  Returns:
    T"
  (register-intent
   (make-intent
    "whoami"
    (lambda (message &key entities session context)
      (declare (ignore entities session context))
      (list :status :success
            :response "I am Lisp-Claw, an AI assistant built in Common Lisp."
            :capabilities '("natural language processing" "tool execution" "multi-channel support"))))
    :patterns '("who are you" "whoami" "what are you" "your name")
    :priority 9
    :description "Identity inquiries"
    :examples '("Who are you?" "What is your name?"))))

(defun register-built-in-intents ()
  "Register all built-in intents.

  Returns:
    T"
  (register-greeting-intent)
  (register-goodbye-intent)
  (register-thanks-intent)
  (register-help-intent)
  (register-status-intent)
  (register-weather-intent)
  (register-time-intent)
  (register-date-intent)
  (register-joke-intent)
  (register-whoami-intent)
  (log-info "Built-in intents registered")
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-intents-system ()
  "Initialize the intents system.

  Returns:
    T"
  (register-built-in-intents)
  (log-info "Intents system initialized")
  t)
