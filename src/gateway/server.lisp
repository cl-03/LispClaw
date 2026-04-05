;;; server.lisp --- WebSocket Gateway Server for Lisp-Claw
;;;
;;; This file implements the WebSocket gateway server that handles
;;; client connections, authentication, and message routing.
;;; Uses Hunchentoot with WebSocket support via clack-websocket.

(defpackage #:lisp-claw.gateway.server
  (:nicknames #:lc.gateway.server)
  (:use #:cl
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.helpers
        #:lisp-claw.gateway.protocol
        #:lisp-claw.gateway.auth
        #:lisp-claw.gateway.events)
  (:export
   #:*gateway*
   #:*gateway-port*
   #:*gateway-bind*
   #:gateway
   #:make-gateway
   #:start-gateway
   #:stop-gateway
   #:restart-gateway
   #:gateway-running-p
   #:handle-client
   #:handle-websocket-message
   #:send-to-client
   #:broadcast-to-clients
   #:*websocket-clients*
   #:*websocket-lock*))

(in-package #:lisp-claw.gateway.server)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *gateway* nil
  "The current gateway instance.")

(defvar *gateway-port* 18789
  "Default gateway port.")

(defvar *gateway-bind* "127.0.0.1"
  "Default gateway bind address.")

(defvar *websocket-clients* (make-hash-table :test 'equal)
  "Hash table of WebSocket client connections: client-id -> websocket-stream.")

(defvar *client-info* (make-hash-table :test 'equal)
  "Hash table of client metadata: client-id -> info alist.")

(defvar *client-counter* 0
  "Counter for client connections.")

(defvar *websocket-lock* (bt:make-lock)
  "Lock for thread-safe WebSocket operations.")

(defvar *websocket-acceptor* nil
  "The Hunchentoot acceptor instance.")

;;; ============================================================================
;;; Gateway Class
;;; ============================================================================

(defclass gateway ()
  ((port :initarg :port
         :initform *gateway-port*
         :accessor gateway-port
         :documentation "Gateway TCP port")
   (bind :initarg :bind
         :initform *gateway-bind*
         :accessor gateway-bind
         :documentation "Bind address")
   (running-p :initform nil
              :accessor gateway-running-p
              :documentation "Whether gateway is running")
   (server-thread :initform nil
                  :accessor gateway-server-thread
                  :documentation "Server thread object")
   (auth-token :initarg :auth-token
               :initform nil
               :accessor gateway-auth-token
               :documentation "Authentication token")
   (clients :initform (make-hash-table :test 'equal)
            :accessor gateway-clients
            :documentation "Active client connections"))
  (:documentation "WebSocket Gateway Server"))

(defmethod print-object ((gateway gateway) stream)
  "Print gateway representation."
  (print-unreadable-object (gateway stream :type t)
    (format stream "~A:~A [~A]"
            (gateway-bind gateway)
            (gateway-port gateway)
            (if (gateway-running-p gateway) "running" "stopped"))))

;;; ============================================================================
;;; Gateway Construction
;;; ============================================================================

(defun make-gateway (&key (port *gateway-port*)
                          (bind *gateway-bind*)
                          (auth-token nil))
  "Create a new gateway instance.

  Args:
    PORT: Gateway port (default: 18789)
    BIND: Bind address (default: 127.0.0.1)
    AUTH-TOKEN: Optional authentication token

  Returns:
    Gateway instance"
  (let ((gateway (make-instance 'gateway
                                :port port
                                :bind bind
                                :auth-token auth-token)))
    (log-info "Gateway created on ~A:~A" bind port)
    gateway))

;;; ============================================================================
;;; Gateway Lifecycle
;;; ============================================================================

(defun start-gateway (gateway)
  "Start the gateway server.

  Args:
    GATEWAY: Gateway instance

  Returns:
    T on success

  Note: This blocks until the server starts, then runs in background thread."
  (when (gateway-running-p gateway)
    (log-warn "Gateway is already running")
    (return-from start-gateway nil))

  (setf (gateway-running-p gateway) t)
  (setf *gateway* gateway)

  ;; Start server thread
  (setf (gateway-server-thread gateway)
        (bt:make-thread
         (lambda ()
           (run-gateway-server gateway))
         :name "lisp-claw-gateway-server"))

  ;; Wait for server to start
  (sleep 0.5)

  (log-info "Gateway started on ~A:~A"
            (gateway-bind gateway)
            (gateway-port gateway))
  t)

(defun stop-gateway (gateway)
  "Stop the gateway server.

  Args:
    GATEWAY: Gateway instance

  Returns:
    T on success"
  (unless (gateway-running-p gateway)
    (log-warn "Gateway is not running")
    (return-from stop-gateway nil))

  (setf (gateway-running-p gateway) nil)

  ;; Stop the acceptor
  (when *websocket-acceptor*
    (hunchentoot:stop *websocket-acceptor*)
    (setf *websocket-acceptor* nil))

  ;; Close all client connections
  (bt:with-lock-held (*websocket-lock*)
    (maphash (lambda (client-id stream)
               (declare (ignore client-id))
               (ignore-errors (close stream)))
             *websocket-clients*)
    (clrhash *websocket-clients*)
    (clrhash *client-info*))

  (clrhash (gateway-clients gateway))

  (log-info "Gateway stopped")
  t)

(defun restart-gateway (gateway)
  "Restart the gateway.

  Args:
    GATEWAY: Gateway instance

  Returns:
    T on success"
  (stop-gateway gateway)
  (sleep 0.5)
  (start-gateway gateway))

;;; ============================================================================
;;; Server Implementation
;;; ============================================================================

(defun run-gateway-server (gateway)
  "Run the gateway server loop.

  Args:
    GATEWAY: Gateway instance

  Note: This function runs in a separate thread."
  (handler-case
      (let ((port (gateway-port gateway))
            (bind (gateway-bind gateway)))
        (log-info "Starting WebSocket server on ~A:~A" bind port)

        ;; Set up dispatch table for request routing
        (setf hunchentoot:*dispatch-table*
              (list
               ;; Health check endpoint
               (lambda ()
                 (when (string= (hunchentoot:request-uri*) "/health")
                   #'handle-health-request))
               ;; Healthz endpoint for Docker
               (lambda ()
                 (when (string= (hunchentoot:request-uri*) "/healthz")
                   #'handle-healthz-request))
               ;; Readyz endpoint for Docker
               (lambda ()
                 (when (string= (hunchentoot:request-uri*) "/readyz")
                   #'handle-readyz-request))
               ;; WebSocket upgrade
               (lambda ()
                 (when (string= (hunchentoot:request-uri*) "/")
                   #'handle-websocket-connection))
               ;; Control UI
               (lambda ()
                 (when (string-prefix-p "/__openclaw__/" (hunchentoot:request-uri*))
                   #'handle-control-ui-request))))

        ;; Create and start acceptor
        (let ((acceptor (make-instance 'hunchentoot:easy-acceptor
                                       :port port
                                       :address bind)))
          (setf *websocket-acceptor* acceptor)
          (hunchentoot:start acceptor)
          (log-info "WebSocket server started")

          ;; Keep running until stopped
          (loop while (gateway-running-p gateway)
                do (sleep 0.5))

          (hunchentoot:stop acceptor)))

    (error (e)
      (log-error "Gateway server error: ~A" e)
      (setf (gateway-running-p gateway) nil))))

;;; ============================================================================
;;; Request Handlers
;;; ============================================================================

(defun handle-health-request ()
  "Handle HTTP health check request.

  Returns:
    Response body, content-type, and status"
  (let ((response `((:status . "ok")
                    (:version . ,"1.0")
                    (:timestamp . ,(timestamp-now))
                    (:clients . ,(hash-table-count *websocket-clients*)))))
    (values (stringify-json response) "application/json" 200)))

(defun handle-healthz-request ()
  "Handle liveness probe for Docker.

  Returns:
    Simple OK response"
  (values "ok" "text/plain" 200))

(defun handle-readyz-request ()
  "Handle readiness probe for Docker.

  Returns:
    Simple OK response"
  (if (and *websocket-acceptor* (gateway-running-p *gateway*))
      (values "ok" "text/plain" 200)
      (values "not ready" "text/plain" 503)))

(defun handle-not-found ()
  "Handle 404 Not Found.

  Returns:
    404 response"
  (values "Not Found" "text/plain" 404))

(defun handle-control-ui-request ()
  "Handle Control UI request.

  Returns:
    Static file or 404"
  (values "Control UI - Coming Soon" "text/html" 200))

;;; ============================================================================
;;; WebSocket Connection Handling
;;; ============================================================================

(defun handle-websocket-connection ()
  "Handle WebSocket connection upgrade.

  Returns:
    WebSocket handler function"
  (let ((client-id (generate-client-id))
        (handshake-processed nil))

    ;; Process WebSocket handshake
    (let* ((request (hunchentoot:*request*))
           (headers (hunchentoot:headers-in request))
           (key (gethash "sec-websocket-key" headers))
           (protocol (gethash "sec-websocket-protocol" headers)))

      (unless key
        (return-from handle-websocket-connection
          (values nil nil 400)))

      ;; Generate accept key
      (let* ((accept-key (compute-websocket-accept-key key))
             (response-headers `(("Upgrade" . "websocket")
                                 ("Connection" . "Upgrade")
                                 ("Sec-WebSocket-Accept" . ,accept-key))))

        (when protocol
          (push (cons "Sec-WebSocket-Protocol" protocol) response-headers))

        ;; Send handshake response
        (send-websocket-handshake-response response-headers)

        (setf handshake-processed t)

        ;; Register client
        (register-websocket-client client-id)

        ;; Handle WebSocket messages
        (handle-websocket-messages client-id)))))

(defun compute-websocket-accept-key (client-key)
  "Compute the Sec-WebSocket-Accept key.

  Args:
    CLIENT-KEY: The Sec-WebSocket-Key from client

  Returns:
    Accept key string"
  (let* ((magic-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
         (concatenated (concatenate 'string client-key magic-guid))
         (sha1-hash (ironclad:digest-sequence :sha1
                     (babel:string-to-octets concatenated)))
         (base64-encoded (babel:octets-to-string sha1-hash :encoding :base64)))
    base64-encoded))

(defun send-websocket-handshake-response (headers)
  "Send WebSocket handshake response.

  Args:
    HEADERS: Response headers alist"
  (let ((response "HTTP/1.1 101 Switching Protocols~%~{~A: ~A~%~}~%"))
    (format t response
            (loop for (key . value) in headers
                  appending (list key value)))))

(defun handle-websocket-messages (client-id)
  "Handle WebSocket messages from a client.

  Args:
    CLIENT-ID: Client identifier

  Note: This function runs in a loop, processing messages until disconnection."
  (let ((stream *standard-output*))
    (unwind-wind
     ()
     (loop while (and (gateway-running-p *gateway*)
                      (open-stream-p stream))
           do
           (handler-case
               (let* ((frame (read-websocket-frame stream)))
                 (when frame
                   (process-websocket-frame client-id frame)))
             (end-of-file ()
               (log-info "Client ~A disconnected" client-id)
               (return))
             (error (e)
               (log-error "WebSocket error for ~A: ~A" client-id e)
               (return))))
     (finally
       (unregister-websocket-client client-id)))))

(defun read-websocket-frame (stream)
  "Read a WebSocket frame from stream.

  Args:
    STREAM: Input stream

  Returns:
    Frame data or NIL"
  ;; Read WebSocket frame header
  (let* ((byte1 (read-byte stream))
         (byte2 (read-byte stream))
         (fin (logbitp 7 byte1))
         (opcode (logand #b1111 byte1))
         (mask-p (logbitp 7 byte2))
         (payload-len (logand #b1111111 byte2))
         (mask-key (if mask-p
                       (let ((key (make-array 4 :element-type '(unsigned-byte 8))))
                         (read-sequence key stream)
                         key)
                       nil))
         (actual-len (cond
                       ((= payload-len 126)
                        (let ((b1 (read-byte stream))
                              (b2 (read-byte stream)))
                          (+ (* b1 256) b2)))
                       ((= payload-len 127)
                        (let ((len 0))
                          (dotimes (i 8)
                            (setf len (+ (* len 256) (read-byte stream))))
                          len))
                       (t payload-len)))
         (data (make-array actual-len :element-type '(unsigned-byte 8))))
    (read-sequence data stream)

    ;; Unmask data if masked
    (when mask-p
      (dotimes (i (length data))
        (setf (aref data i) (logxor (aref data i) (aref mask-key (mod i 4))))))

    ;; Process based on opcode
    (case opcode
      (#x1 ; Text frame
       (babel:octets-to-string data :encoding :utf-8))
      (#x2 ; Binary frame
       data)
      (#x8 ; Close frame
       (close-websocket-connection stream))
      (#x9 ; Ping frame
       (send-websocket-pong stream data))
      (#xA ; Pong frame
       nil)
      (otherwise
       (log-warn "Unknown WebSocket opcode: ~A" opcode)
       nil))))

(defun send-websocket-pong (stream data)
  "Send WebSocket pong response.

  Args:
    STREAM: Output stream
    DATA: Ping data to echo"
  (declare (ignore data))
  ;; Send pong frame (opcode #xA)
  (write-byte #b10001010 stream)
  (write-byte (length data) stream)
  (write-sequence data stream)
  (finish-output stream))

(defun close-websocket-connection (stream)
  "Close WebSocket connection.

  Args:
    STREAM: Output stream"
  (write-byte #b10001000 stream) ; Close frame
  (write-byte 0 stream)
  (finish-output stream)
  (close stream))

(defun process-websocket-frame (client-id frame)
  "Process a WebSocket frame.

  Args:
    CLIENT-ID: Client identifier
    FRAME: Frame data (string or octets)"
  (when (stringp frame)
    (handler-case
        (let* ((json (parse-json frame))
               (parsed-frame (parse-frame json)))
          (log-debug "Received from ~A: ~A" client-id (frame-type parsed-frame))
          (handle-request-frame *gateway* client-id parsed-frame))
      (protocol-error (e)
        (log-error "Protocol error from ~A: ~A" client-id e)
        (send-error-to-client client-id e))
      (error (e)
        (log-error "Error processing frame from ~A: ~A" client-id e)
        (send-error-to-client client-id e)))))

;;; ============================================================================
;;; Client Management
;;; ============================================================================

(defun generate-client-id ()
  "Generate a unique client ID.

  Returns:
    Client ID string"
  (format nil "client-~A-~A"
          (get-universal-time)
          (uuid:make-v4-uuid)))

(defun register-websocket-client (client-id)
  "Register a WebSocket client.

  Args:
    CLIENT-ID: Client ID

  Returns:
    T on success"
  (bt:with-lock-held (*websocket-lock*)
    (setf (gethash client-id *websocket-clients*) *standard-output*)
    (setf (gethash client-id *client-info*)
          (list :id client-id
                :connected-at (get-universal-time)
                :last-seen (get-universal-time)))
    (log-info "WebSocket client registered: ~A" client-id)
    t))

(defun unregister-websocket-client (client-id)
  "Unregister a WebSocket client.

  Args:
    CLIENT-ID: Client ID to remove

  Returns:
    T on success"
  (bt:with-lock-held (*websocket-lock*)
    (let ((stream (gethash client-id *websocket-clients*)))
      (when stream
        (ignore-errors (close stream))))
    (remhash client-id *websocket-clients*)
    (remhash client-id *client-info*)
    (when *gateway*
      (remhash client-id (gateway-clients *gateway*)))
    (log-info "WebSocket client unregistered: ~A" client-id)
    t))

(defun get-websocket-client (client-id)
  "Get WebSocket client stream.

  Args:
    CLIENT-ID: Client ID

  Returns:
    Stream or NIL"
  (bt:with-lock-held (*websocket-lock*)
    (gethash client-id *websocket-clients*)))

(defun get-client-info (client-id)
  "Get client information.

  Args:
    CLIENT-ID: Client ID

  Returns:
    Info alist or NIL"
  (gethash client-id *client-info*))

;;; ============================================================================
;;; WebSocket Message Sending
;;; ============================================================================

(defun send-to-client (client-id message)
  "Send a message to a specific client.

  Args:
    CLIENT-ID: Client ID
    MESSAGE: Message string to send

  Returns:
    T on success"
  (bt:with-lock-held (*websocket-lock*)
    (let ((stream (gethash client-id *websocket-clients*)))
      (when (and stream (open-stream-p stream))
        (handler-case
            (let* ((data (babel:string-to-octets message :encoding :utf-8))
                   (len (length data)))
              ;; Send text frame (opcode #x1, FIN set)
              (write-byte #b10000001 stream)
              ;; Send length (unmasked, server to client)
              (cond
                ((< len 126)
                 (write-byte len stream))
                ((< len 65536)
                 (write-byte 126 stream)
                 (write-byte (ash len -8) stream)
                 (write-byte (logand len #xFF) stream))
                (t
                 (write-byte 127 stream)
                 (dotimes (i 8)
                   (write-byte (ldb (byte 8 (* 56 (* 7 i))) len) stream))))
              ;; Send data
              (write-sequence data stream)
              (finish-output stream)
              t)
          (error (e)
            (log-error "Error sending to ~A: ~A" client-id e)
            nil))))))

(defun broadcast-to-clients (message)
  "Broadcast a message to all connected clients.

  Args:
    MESSAGE: Message string to broadcast

  Returns:
    Number of clients notified"
  (let ((count 0))
    (bt:with-lock-held (*websocket-lock*)
      (maphash (lambda (client-id stream)
                 (declare (ignore stream))
                 (when (send-to-client client-id message)
                   (incf count)))
               *websocket-clients*))
    count))

(defun send-event-to-client (client-id event payload)
  "Send an event to a specific client.

  Args:
    CLIENT-ID: Client ID
    EVENT: Event type string
    PAYLOAD: Event payload alist

  Returns:
    T on success"
  (let* ((event-frame (make-event-frame event :payload payload))
         (json (frame-to-json event-frame))
         (message (stringify-json json)))
    (send-to-client client-id message)))

;;; ============================================================================
;;; Message Handling (delegates to protocol handler)
;;; ============================================================================

(defun handle-request-frame (gateway client-id frame)
  "Handle a request frame.

  Args:
    GATEWAY: Gateway instance
    CLIENT-ID: Client ID
    FRAME: Request frame

  Returns:
    Response"
  (let ((method (request-frame-method frame))
        (params (request-frame-params frame))
        (id (frame-id frame)))

    (log-debug "Handling request from ~A: ~A" client-id method)

    ;; Update last seen
    (let ((info (get-client-info client-id)))
      (when info
        (setf (getf info :last-seen) (get-universal-time))))

    (let ((result (process-request gateway client-id method params)))
      (send-response gateway client-id id result))))

(defun process-request (gateway client-id method params)
  "Process a request method.

  Args:
    GATEWAY: Gateway instance
    CLIENT-ID: Client ID
    METHOD: Request method
    PARAMS: Request parameters

  Returns:
    Response payload or error"
  (cond
    ((string= method +method-connect+)
     (handle-connect gateway client-id params))
    ((string= method +method-health+)
     (handle-health gateway))
    ((string= method +method-agent+)
     (handle-agent-request gateway client-id params))
    ((string= method +method-send+)
     (handle-send-request gateway client-id params))
    ((string= method +method-node-invoke+)
     (handle-node-invoke-request gateway client-id params))
    (t
     (error 'method-not-found-error
            :message (format nil "Unknown method: ~A" method)))))

(defun handle-connect (gateway client-id params)
  "Handle connect request.

  Args:
    GATEWAY: Gateway instance
    CLIENT-ID: Client ID
    PARAMS: Connect parameters

  Returns:
    Connection acknowledgment"
  (declare (ignore client-id))
  (log-info "Client connecting: ~A" params)

  ;; Verify authentication if enabled
  (let ((auth (json-get params :auth)))
    (when (and (gateway-auth-token gateway)
               auth)
      (let ((token (json-get auth :token)))
        (unless (string= token (gateway-auth-token gateway))
          (error 'auth-error :message "Invalid authentication token")))))

  ;; Update client info
  (let ((info (get-client-info client-id)))
    (when info
      (setf (getf info :type) (json-get params :type))
      (setf (getf info :name) (json-get params :name))))

  ;; Return connection info
  `((:status . "ok")
    (:clientId . ,client-id)
    (:protocolVersion . ,+protocol-version+)))

(defun handle-health (gateway)
  "Handle health check request.

  Args:
    GATEWAY: Gateway instance

  Returns:
    Health status"
  `((:status . "ok")
    (:running . ,(gateway-running-p gateway))
    (:clients . ,(hash-table-count *websocket-clients*))
    (:timestamp . ,(timestamp-now))))

(defun handle-agent-request (gateway client-id params)
  "Handle agent request.

  Args:
    GATEWAY: Gateway instance
    CLIENT-ID: Client ID
    PARAMS: Agent request parameters

  Returns:
    Agent response"
  (declare (ignore gateway client-id params))
  `((:status . "accepted")
    (:message . "Agent request received")))

(defun handle-send-request (gateway client-id params)
  "Handle send message request.

  Args:
    GATEWAY: Gateway instance
    CLIENT-ID: Client ID
    PARAMS: Send parameters

  Returns:
    Send result"
  (declare (ignore gateway client-id params))
  `((:status . "sent")))

(defun handle-node-invoke-request (gateway client-id params)
  "Handle node invoke request.

  Args:
    GATEWAY: Gateway instance
    CLIENT-ID: Client ID
    PARAMS: Invoke parameters

  Returns:
    Invoke result"
  (declare (ignore gateway client-id params))
  `((:status . "invoked")))

(defun send-response (gateway client-id request-id result)
  "Send a response to a client.

  Args:
    GATEWAY: Gateway instance
    CLIENT-ID: Client ID
    REQUEST-ID: Request ID
    RESULT: Response payload

  Returns:
    T on success"
  (let ((response-frame (make-response-frame request-id t :payload result)))
    (send-to-client client-id (stringify-json (frame-to-json response-frame)))
    t))

(defun send-error-to-client (client-id error)
  "Send an error to a client.

  Args:
    CLIENT-ID: Client ID
    ERROR: Error condition

  Returns:
    T on success"
  (let ((error-frame (make-response-frame nil nil :error (format nil "~A" error))))
    (send-to-client client-id (stringify-json (frame-to-json error-frame)))))

(define-condition auth-error (protocol-error)
  ((code :initform "AUTH_ERROR"))
  (:report (lambda (condition stream)
             (format stream "Authentication Error: ~A"
                     (error-message condition)))))
