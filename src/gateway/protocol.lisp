;;; protocol.lisp --- Gateway Protocol Definition for Lisp-Claw
;;;
;;; This file defines the WebSocket protocol used by Lisp-Claw gateway.
;;; Based on the OpenClaw protocol specification.

(defpackage #:lisp-claw.gateway.protocol
  (:nicknames #:lc.gateway.protocol)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.json
        #:lisp-claw.utils.logging)
  (:export
   ;; Protocol version
   #:*protocol-version*

   ;; Frame types
   #:frame-type-request
   #:frame-type-response
   #:frame-type-event
   #:frame-type-connect

   ;; Request methods
   #:method-connect
   #:method-health
   #:method-agent
   #:method-send
   #:method-node-invoke
   #:method-sessions-list
   #:method-sessions-send
   #:method-devices-list

   ;; Events
   #:event-agent
   #:event-chat
   #:event-presence
   #:event-health
   #:event-heartbeat
   #:event-cron
   #:event-node

   ;; Frame creation
   #:make-request-frame
   #:make-response-frame
   #:make-event-frame
   #:make-connect-frame

   ;; Frame parsing
   #:parse-frame
   #:validate-frame
   #:frame-p

   ;; Protocol errors
   #:protocol-error
   #:invalid-frame-error
   #:method-not-found-error))

(in-package #:lisp-claw.gateway.protocol)

;;; ============================================================================
;;; Protocol Constants
;;; ============================================================================

(defconstant +protocol-version+ "1.0"
  "Protocol version string.")

(defvar *protocol-version* +protocol-version+
  "Current protocol version.")

;;; Frame type keywords
(defconstant +frame-type-request+ :req
  "Request frame type.")

(defconstant +frame-type-response+ :res
  "Response frame type.")

(defconstant +frame-type-event+ :event
  "Event frame type.")

(defconstant +frame-type-connect+ :connect
  "Connect frame (special request).")

;;; ============================================================================
;;; Request Methods
;;; ============================================================================

(defconstant +method-connect+ "connect"
  "Initial connection handshake method.")

(defconstant +method-health+ "health"
  "Health check method.")

(defconstant +method-agent+ "agent"
  "Agent invocation method.")

(defconstant +method-send+ "send"
  "Message send method.")

(defconstant +method-node-invoke+ "node.invoke"
  "Node command invocation method.")

(defconstant +method-sessions-list+ "sessions_list"
  "List sessions method.")

(defconstant +method-sessions-send+ "sessions_send"
  "Send to session method.")

(defconstant +method-devices-list+ "devices_list"
  "List devices method.")

;;; ============================================================================
;;; Events
;;; ============================================================================

(defconstant +event-agent+ "agent"
  "Agent event (streaming responses).")

(defconstant +event-chat+ "chat"
  "Chat message event.")

(defconstant +event-presence+ "presence"
  "Presence update event.")

(defconstant +event-health+ "health"
  "Health status event.")

(defconstant +event-heartbeat+ "heartbeat"
  "Heartbeat event.")

(defconstant +event-cron+ "cron"
  "Cron trigger event.")

(defconstant +event-node+ "node"
  "Node event.")

;;; ============================================================================
;;; Frame Types
;;; ============================================================================

(defstruct frame
  "Base frame structure for protocol messages."
  (type nil :type keyword)
  (id nil :type (or string null))
  (timestamp nil :type (or string null)))

(defstruct (request-frame (:include frame))
  "Request frame structure."
  (method nil :type string)
  (params nil :type (or alist null)))

(defstruct (response-frame (:include frame))
  "Response frame structure."
  (ok nil :type boolean)
  (payload nil :type (or alist null))
  (error nil :type (or string null)))

(defstruct (event-frame (:include frame))
  "Event frame structure."
  (event nil :type string)
  (payload nil :type (or alist null))
  (seq nil :type (or integer null))
  (state-version nil :type (or integer null)))

;;; ============================================================================
;;; Frame Creation
;;; ============================================================================

(defun make-request-frame (method &key id params)
  "Create a request frame.

  Args:
    METHOD: Request method string
    ID: Optional request ID (generated if NIL)
    PARAMS: Optional request parameters

  Returns:
    Request frame structure"
  (make-request-frame
   :type :req
   :id (or id (generate-frame-id))
   :timestamp (get-universal-time)
   :method method
   :params params))

(defun make-response-frame (request-id ok &key payload error)
  "Create a response frame.

  Args:
    REQUEST-ID: ID of the request being responded to
    OK: Boolean indicating success
    PAYLOAD: Response payload (if successful)
    ERROR: Error message (if failed)

  Returns:
    Response frame structure"
  (make-response-frame
   :type :res
   :id request-id
   :timestamp (get-universal-time)
   :ok ok
   :payload payload
   :error error))

(defun make-event-frame (event &key payload seq state-version)
  "Create an event frame.

  Args:
    EVENT: Event type string
    PAYLOAD: Event payload
    SEQ: Optional sequence number
    STATE-VERSION: Optional state version

  Returns:
    Event frame structure"
  (make-event-frame
   :type :event
   :id nil
   :timestamp (get-universal-time)
   :event event
   :payload payload
   :seq seq
   :state-version state-version))

(defun make-connect-frame (client-info &key auth)
  "Create a connect frame.

  Args:
    CLIENT-INFO: Client information alist
    AUTH: Optional authentication info

  Returns:
    Connect request frame"
  (make-request-frame
   +method-connect+
   :params (append '((:type . "client")
                     (:version . "1.0"))
                   client-info
                   (when auth `((:auth . ,auth))))))

;;; ============================================================================
;;; Frame Parsing
;;; ============================================================================

(defun parse-frame (json-object)
  "Parse a JSON object into a frame structure.

  Args:
    JSON-OBJECT: Parsed JSON object (alist)

  Returns:
    Frame structure or signals PROTOCOL-ERROR

  Signals:
    PROTOCOL-ERROR: If frame is invalid"
  (let* ((type (json-get json-object :type))
         (id (json-get json-object :id))
         (method (json-get json-object :method))
         (event (json-get json-object :event))
         (payload (json-get json-object :payload)))

    (cond
      ;; Request frame
      ((and (equal type "req") method)
       (make-request-frame
        :method method
        :id id
        :params (json-get json-object :params)))

      ;; Response frame
      ((equal type "res")
       (make-response-frame
        :request-id id
        :ok (json-get json-object :ok)
        :payload (or payload (json-get json-object :result))
        :error (json-get json-object :error)))

      ;; Event frame
      ((and (equal type "event") event)
       (make-event-frame
        :event event
        :payload payload
        :seq (json-get json-object :seq)
        :state-version (json-get json-object :stateVersion)))

      ;; Invalid frame
      (t
       (error 'invalid-frame-error
              :message (format nil "Invalid frame type: ~A" type))))))

(defun validate-frame (frame)
  "Validate a frame structure.

  Args:
    FRAME: Frame structure to validate

  Returns:
    T if valid, signals error otherwise

  Signals:
    PROTOCOL-ERROR: If frame is invalid"
  (check-type frame frame)

  (typecase frame
    (request-frame
     (unless (and (request-frame-method frame)
                  (stringp (request-frame-method frame)))
       (error 'protocol-error :message "Request frame missing method")))
    (response-frame
     (unless (and (response-frame-id frame)
                  (typep (response-frame-ok frame) 'boolean))
       (error 'protocol-error :message "Response frame invalid")))
    (event-frame
     (unless (and (event-frame-event frame)
                  (stringp (event-frame-event frame)))
       (error 'protocol-error :message "Event frame missing event type"))))

  t)

(defun frame-p (object)
  "Check if OBJECT is a frame structure.

  Args:
    OBJECT: Any object

  Returns:
    T if object is a frame, NIL otherwise"
  (typep object 'frame))

;;; ============================================================================
;;; Frame Serialization
;;; ============================================================================

(defun frame-to-json (frame)
  "Convert a frame to a JSON-serializable alist.

  Args:
    FRAME: Frame structure

  Returns:
    Alist suitable for JSON serialization"
  (let ((base `((:type . ,(string (frame-type frame)))
                ,@(when (frame-id frame)
                    `((:id . ,(frame-id frame)))))))
    (typecase frame
      (request-frame
       (append base
               `((:method . ,(request-frame-method frame))
                 ,@(when (request-frame-params frame)
                     `((:params . ,(request-frame-params frame)))))))
      (response-frame
       (append base
               `((:ok . ,(response-frame-ok frame))
                 ,@(if (response-frame-ok frame)
                       (when (response-frame-payload frame)
                         `((:payload . ,(response-frame-payload frame))))
                       (when (response-frame-error frame)
                         `((:error . ,(response-frame-error frame))))))))
      (event-frame
       (append base
               `((:event . ,(event-frame-event frame))
                 ,@(when (event-frame-payload frame)
                     `((:payload . ,(event-frame-payload frame))))
                 ,@(when (event-frame-seq frame)
                     `((:seq . ,(event-frame-seq frame))))
                 ,@(when (event-frame-state-version frame)
                     `((:stateVersion . ,(event-frame-state-version frame))))))))))

(defun serialize-frame (frame)
  "Serialize a frame to a JSON string.

  Args:
    FRAME: Frame structure

  Returns:
    JSON string"
  (stringify-json (frame-to-json frame)))

;;; ============================================================================
;;; Utilities
;;; ============================================================================

(defun generate-frame-id ()
  "Generate a unique frame ID.

  Returns:
    UUID string"
  (format nil "~8,'0x-~4,'0x-~4,'0x-~4,'0x-~12,'0x"
          (random (expt 2 32))
          (random (expt 2 16))
          (random (expt 2 16))
          (random (expt 2 16))
          (random (expt 2 48))))

(defun timestamp-now ()
  "Get current ISO 8601 timestamp.

  Returns:
    Timestamp string"
  (multiple-value-bind (second minute hour day month year)
      (get-decoded-time)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour minute second)))

;;; ============================================================================
;;; Protocol Errors
;;; ============================================================================

(define-condition protocol-error (error)
  ((message :initarg :message :reader error-message)
   (code :initarg :code :initform "PROTOCOL_ERROR" :reader error-code))
  (:report (lambda (condition stream)
             (format stream "Protocol Error (~A): ~A"
                     (error-code condition)
                     (error-message condition)))))

(define-condition invalid-frame-error (protocol-error)
  ((code :initform "INVALID_FRAME"))
  (:report (lambda (condition stream)
             (format stream "Invalid Frame: ~A"
                     (error-message condition)))))

(define-condition method-not-found-error (protocol-error)
  ((code :initform "METHOD_NOT_FOUND"))
  (:report (lambda (condition stream)
             (format stream "Method Not Found: ~A"
                     (error-message condition)))))
