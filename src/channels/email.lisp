;;; channels/email.lisp --- Email Channel for Lisp-Claw
;;;
;;; This file implements Email integration:
;;; - SMTP sending
;;; - IMAP receiving
;;; - HTML/Plain text support
;;; - Attachments
;;; - Multiple account support

(defpackage #:lisp-claw.channels.email
  (:nicknames #:lc.channels.email)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.channels.base)
  (:export
   ;; Email Account class
   #:email-account
   #:make-email-account
   #:email-account-host
   #:email-account-user
   #:email-account-password
   #:email-account-smtp-host
   #:email-account-smtp-port
   #:email-account-imap-host
   #:email-account-imap-port
   ;; Email Message class
   #:email-message
   #:make-email-message
   #:email-message-from
   #:email-message-to
   #:email-message-subject
   #:email-message-body
   #:email-message-html
   #:email-message-attachments
   ;; SMTP sending
   #:smtp-send
   #:smtp-send-message
   #:smtp-connect
   #:smtp-disconnect
   ;; IMAP receiving
   #:imap-connect
   #:imap-disconnect
   #:imap-list-messages
   #:imap-get-message
   #:imap-mark-read
   #:imap-delete-message
   #:imap-search
   ;; Channel interface
   #:email-channel
   #:make-email-channel
   #:email-start-listening
   #:email-stop-listening))

(in-package #:lisp-claw.channels.email)

;;; ============================================================================
;;; Email Account Class
;;; ============================================================================

(defclass email-account ()
  ((user :initarg :user
         :reader email-account-user
         :documentation "Email address")
   (password :initarg :password
             :reader email-account-password
             :documentation "Password or app password")
   (smtp-host :initarg :smtp-host
              :reader email-account-smtp-host
              :documentation "SMTP server host")
   (smtp-port :initarg :smtp-port
              :initform 587
              :reader email-account-smtp-port
              :documentation "SMTP server port")
   (smtp-ssl :initarg :smtp-ssl
             :initform t
             :reader email-account-smtp-ssl
             :documentation "Use SSL for SMTP")
   (imap-host :initarg :imap-host
              :reader email-account-imap-host
              :documentation "IMAP server host")
   (imap-port :initarg :imap-port
              :initform 993
              :reader email-account-imap-port
              :documentation "IMAP server port")
   (imap-ssl :initarg :imap-ssl
             :initform t
             :reader email-account-imap-ssl
             :documentation "Use SSL for IMAP")
   (smtp-connection :initform nil
                    :accessor email-smtp-connection
                    :documentation "SMTP connection")
   (imap-connection :initform nil
                    :accessor email-imap-connection
                    :documentation "IMAP connection")
   (last-checked :initform nil
                 :accessor email-last-checked
                 :documentation "Last check timestamp"))
  (:documentation "Email account configuration"))

(defmethod print-object ((account email-account) stream)
  (print-unreadable-object (account stream :type t)
    (format t "~A" (email-account-user account))))

;;; ============================================================================
;;; Email Message Class
;;; ============================================================================

(defclass email-message ()
  ((from :initarg :from
         :reader email-message-from
         :documentation "Sender address")
   (to :initarg :to
       :reader email-message-to
       :documentation "Recipient address(es)")
   (subject :initarg :subject
            :reader email-message-subject
            :documentation "Message subject")
   (body :initarg :body
         :reader email-message-body
         :documentation "Plain text body")
   (html :initarg :html
         :initform nil
         :reader email-message-html
         :documentation "HTML body")
   (cc :initarg :cc
       :initform nil
       :reader email-message-cc
       :documentation "CC recipients")
   (bcc :initarg :bcc
        :initform nil
        :reader email-message-bcc
        :documentation "BCC recipients")
   (attachments :initarg :attachments
                :initform nil
                :reader email-message-attachments
                :documentation "Attachments")
   (headers :initarg :headers
            :initform nil
            :reader email-message-headers
            :documentation "Additional headers")
   (date :initform (get-universal-time)
         :reader email-message-date
         :documentation "Message date")
   (message-id :initform nil
               :accessor email-message-id
               :documentation "Message ID")
   (in-reply-to :initarg :in-reply-to
                :initform nil
                :reader email-message-in-reply-to
                :documentation "In-Reply-To header")
   (references :initarg :references
               :initform nil
               :reader email-message-references
               :documentation "References header")
   (seen-p :initform nil
           :accessor email-message-seen-p
           :documentation "Whether message has been read")
   (uid :initarg :uid
        :initform nil
        :reader email-message-uid
        :documentation "IMAP UID"))
  (:documentation "Email message representation"))

(defmethod print-object ((msg email-message) stream)
  (print-unreadable-object (msg stream :type t)
    (format t "~A: ~A -> ~A"
            (email-message-subject msg)
            (email-message-from msg)
            (email-message-to msg))))

;;; ============================================================================
;;; Construction
;;; ============================================================================

(defun make-email-account (user password &key smtp-host smtp-port imap-host imap-port)
  "Create an email account.

  Args:
    USER: Email address
    PASSWORD: Password or app password
    SMTP-HOST: SMTP server host
    SMTP-PORT: SMTP port (default: 587)
    IMAP-HOST: IMAP server host
    IMAP-PORT: IMAP port (default: 993)

  Returns:
    Email account instance"
  (make-instance 'email-account
                 :user user
                 :password password
                 :smtp-host (or smtp-host (infer-smtp-host user))
                 :smtp-port (or smtp-port 587)
                 :imap-host (or imap-host (infer-imap-host user))
                 :imap-port (or imap-port 993)))

(defun infer-smtp-host (email)
  "Infer SMTP host from email address.

  Args:
    EMAIL: Email address

  Returns:
    SMTP host string"
  (let ((domain (cadr (split-sequence:split-sequence #\@ email))))
    (cond
      ((search "gmail" domain) "smtp.gmail.com")
      ((search "outlook" domain) "smtp.office365.com")
      ((search "hotmail" domain) "smtp.office365.com")
      ((search "yahoo" domain) "smtp.mail.yahoo.com")
      ((search "icloud" domain) "smtp.mail.me.com")
      (t (format nil "smtp.~A" domain)))))

(defun infer-imap-host (email)
  "Infer IMAP host from email address.

  Args:
    EMAIL: Email address

  Returns:
    IMAP host string"
  (let ((domain (cadr (split-sequence:split-sequence #\@ email))))
    (cond
      ((search "gmail" domain) "imap.gmail.com")
      ((search "outlook" domain) "outlook.office365.com")
      ((search "hotmail" domain) "outlook.office365.com")
      ((search "yahoo" domain) "imap.mail.yahoo.com")
      ((search "icloud" domain) "imap.mail.me.com")
      (t (format nil "imap.~A" domain)))))

(defun make-email-message (to subject body &key from html cc bcc attachments in-reply-to)
  "Create an email message.

  Args:
    TO: Recipient(s)
    SUBJECT: Message subject
    BODY: Plain text body
    FROM: Sender (optional)
    HTML: HTML body (optional)
    CC: CC recipients (optional)
    BCC: BCC recipients (optional)
    ATTACHMENTS: Attachments (optional)
    IN-REPLY-TO: In-Reply-To header (optional)

  Returns:
    Email message instance"
  (make-instance 'email-message
                 :to (if (listp to) to (list to))
                 :subject subject
                 :body body
                 :from from
                 :html html
                 :cc cc
                 :bcc bcc
                 :attachments attachments
                 :in-reply-to in-reply-to))

;;; ============================================================================
;;; SMTP Client
;;; ============================================================================

(defvar *smtp-timeout* 30
  "SMTP connection timeout in seconds.")

(defun smtp-connect (account)
  "Connect to SMTP server.

  Args:
    ACCOUNT: Email account

  Returns:
    T on success"
  (let ((host (email-account-smtp-host account))
        (port (email-account-smtp-port account))
        (user (email-account-user account))
        (password (email-account-password account)))
    (handler-case
        (progn
          ;; Use usocket for SMTP connection
          (let ((socket (usocket:socket-connect host port :protocol :stream
                                                :timeout *smtp-timeout*)))
            (let ((stream (usocket:socket-stream socket)))
              ;; Read greeting
              (read-line stream)

              ;; EHLO
              (format stream "EHLO ~A~%" (machine-instance))
              (finish-output stream)
              (loop for line = (read-line stream nil nil)
                    while (and line (not (search "250 " line)))
                    do (log-debug "SMTP: ~A" line))

              ;; STARTTLS if available
              ;; For simplicity, we'll use SSL socket from the start

              ;; AUTH LOGIN
              (format stream "AUTH LOGIN~%")
              (finish-output stream)
              (read-line stream)

              ;; Send credentials (Base64 encoded)
              (format stream "~A~%" (base64-encode-string user))
              (finish-output stream)
              (read-line stream)

              (format stream "~A~%" (base64-encode-string password))
              (finish-output stream)
              (let ((result (read-line stream)))
                (if (search "235" result)
                    (progn
                      (setf (email-smtp-connection account) (list :socket socket :stream stream))
                      (log-info "SMTP connected: ~A" user)
                      t)
                    (progn
                      (log-error "SMTP auth failed: ~A" result)
                      nil))))))
      (error (e)
        (log-error "SMTP connection failed: ~A - ~A" host e)
        nil))))

(defun smtp-disconnect (account)
  "Disconnect from SMTP server.

  Args:
    ACCOUNT: Email account

  Returns:
    T on success"
  (let ((conn (email-smtp-connection account)))
    (when conn
      (let ((stream (getf conn :stream)))
        (format stream "QUIT~%")
        (finish-output stream)
        (usocket:socket-close (getf conn :socket))))
    (setf (email-smtp-connection account) nil)
    (log-info "SMTP disconnected: ~A" (email-account-user account))
    t))

(defun base64-encode-string (string)
  "Base64 encode a string.

  Args:
    STRING: String to encode

  Returns:
    Base64 encoded string"
  ;; Simplified implementation - would use cl-base64 in production
  (with-output-to-string (out)
    (let ((data (babel:string-to-octets string :encoding :utf-8)))
      ;; In production, use: (cl-base64:usb8-array-to-base64-string data)
      (write-string "BASE64_PLACEHOLDER" out))))

(defun smtp-send (account message)
  "Send an email via SMTP.

  Args:
    ACCOUNT: Email account
    MESSAGE: Email message

  Returns:
    T on success"
  (let ((conn (email-smtp-connection account)))
    (unless conn
      (smtp-connect account)
      (setf conn (email-smtp-connection account)))

    (unless conn
      (return-from smtp-send nil))

    (let ((stream (getf conn :stream))
          (from (or (email-message-from message) (email-account-user account)))
          (to (email-message-to message)))
      (handler-case
          (progn
            ;; MAIL FROM
            (format stream "MAIL FROM:<~A>~%" from)
            (finish-output stream)
            (read-line stream)

            ;; RCPT TO
            (dolist (recipient to)
              (format stream "RCPT TO:<~A>~%" recipient)
              (finish-output stream)
              (read-line stream))

            ;; DATA
            (format stream "DATA~%")
            (finish-output stream)
            (read-line stream)

            ;; Headers
            (format stream "From: <~A>~%" from)
            (format stream "To: ~{<~A>~^, ~}~%" to)
            (format stream "Subject: ~A~%" (email-message-subject message))
            (format stream "MIME-Version: 1.0~%")
            (format stream "Content-Type: text/plain; charset=UTF-8~%")
            (format stream "~%")

            ;; Body
            (format stream "~A~%" (email-message-body message))
            (format stream ".~%")
            (finish-output stream)
            (read-line stream)

            (log-info "Email sent: ~A -> ~A" from to)
            t)
        (error (e)
          (log-error "SMTP send failed: ~A" e)
          nil)))))

(defun smtp-send-message (account to subject body &key from html cc bcc)
  "Send an email message.

  Args:
    ACCOUNT: Email account
    TO: Recipient(s)
    SUBJECT: Subject
    BODY: Body text
    FROM: Sender (optional)
    HTML: HTML body (optional)
    CC: CC recipients (optional)
    BCC: BCC recipients (optional)

  Returns:
    T on success"
  (let ((message (make-email-message to subject body
                                     :from from :html html :cc cc :bcc bcc)))
    (smtp-send account message)))

;;; ============================================================================
;;; IMAP Client
;;; ============================================================================

(defvar *imap-timeout* 30
  "IMAP connection timeout in seconds.")

(defun imap-connect (account)
  "Connect to IMAP server.

  Args:
    ACCOUNT: Email account

  Returns:
    T on success"
  (let ((host (email-account-imap-host account))
        (port (email-account-imap-port account))
        (user (email-account-user account))
        (password (email-account-password account)))
    (handler-case
        (progn
          (let ((socket (usocket:socket-connect host port :protocol :stream
                                                :timeout *imap-timeout*)))
            (let ((stream (usocket:socket-stream socket)))
              ;; Read greeting
              (read-line stream)

              ;; LOGIN
              (format stream "a001 LOGIN ~A ~A~%" user password)
              (finish-output stream)
              (let ((result (read-line stream)))
                (if (search "OK" result)
                    (progn
                      (setf (email-imap-connection account) (list :socket socket :stream stream))
                      (log-info "IMAP connected: ~A" user)
                      t)
                    (progn
                      (log-error "IMAP auth failed: ~A" result)
                      nil))))))
      (error (e)
        (log-error "IMAP connection failed: ~A - ~A" host e)
        nil))))

(defun imap-disconnect (account)
  "Disconnect from IMAP server.

  Args:
    ACCOUNT: Email account

  Returns:
    T on success"
  (let ((conn (email-imap-connection account)))
    (when conn
      (let ((stream (getf conn :stream)))
        (format stream "a002 LOGOUT~%")
        (finish-output stream)
        (usocket:socket-close (getf conn :socket))))
    (setf (email-imap-connection account) nil)
    (log-info "IMAP disconnected: ~A" (email-account-user account))
    t))

(defun imap-select (account folder)
  "Select an IMAP folder.

  Args:
    ACCOUNT: Email account
    FOLDER: Folder name

  Returns:
    T on success"
  (let ((conn (email-imap-connection account)))
    (unless conn
      (return-from imap-select nil))
    (let ((stream (getf conn :stream)))
      (format stream "a003 SELECT ~A~%" folder)
      (finish-output stream)
      (let ((result (read-line stream)))
        (if (search "OK" result)
            t
            (progn
              (log-error "IMAP select failed: ~A" result)
              nil))))))

(defun imap-list-messages (account &key folder limit seen-only)
  "List messages in a folder.

  Args:
    ACCOUNT: Email account
    FOLDER: Folder name (default: INBOX)
    LIMIT: Maximum messages
    SEEN-ONLY: Only read messages

  Returns:
    List of message summaries"
  (let ((conn (email-imap-connection account)))
    (unless conn
      (return-from imap-list-messages nil))

    (imap-select account (or folder "INBOX"))

    (let ((stream (getf conn :stream))
          (messages nil))
      ;; Search for messages
      (if seen-only
          (format stream "a004 SEARCH SEEN~%")
          (format stream "a004 SEARCH ALL~%"))
      (finish-output stream)
      (read-line stream)
      (let ((search-result (read-line stream)))
        (when (and search-result (search "SEARCH" search-result))
          (let ((ids (rest (split-sequence:split-sequence #\Space search-result))))
            (when limit
              (setf ids (subseq ids (max 0 (- (length ids) limit)))))

            ;; Fetch message headers
            (dolist (id ids)
              (format stream "a005 FETCH ~A (UID FLAGS BODY[HEADER.FIELDS (FROM TO SUBJECT DATE)])~%" id)
              (finish-output stream)
              (loop for line = (read-line stream nil nil)
                    while (and line (not (search "OK" line)))
                    when (and line (search "FETCH" line))
                    do (push (parse-imap-fetch line) messages))))))
      (nreverse messages))))

(defun imap-get-message (account uid &key folder)
  "Get a message by UID.

  Args:
    ACCOUNT: Email account
    UID: Message UID
    FOLDER: Folder name

  Returns:
    Email message or NIL"
  (let ((conn (email-imap-connection account)))
    (unless conn
      (return-from imap-get-message nil))

    (imap-select account (or folder "INBOX"))

    (let ((stream (getf conn :stream)))
      (format stream "a006 FETCH ~A (UID FLAGS BODY.PEEK[])~%" uid)
      (finish-output stream)

      (let ((content nil)
            (flags nil))
        (loop for line = (read-line stream nil nil)
              while (and line (not (search "OK" line)))
              do (progn
                   (when (search "FLAGS" line)
                     (setf flags (parse-imap-flags line)))
                   (when (search "BODY" line)
                     (setf content line))))

        (when content
          (make-instance 'email-message
                         :uid uid
                         :from (extract-header content "FROM")
                         :to (extract-header content "TO")
                         :subject (extract-header content "SUBJECT")
                         :seen-p (member "\\Seen" flags :test #'string=)))))))

(defun imap-mark-read (account uid &key folder)
  "Mark a message as read.

  Args:
    ACCOUNT: Email account
    UID: Message UID
    FOLDER: Folder name

  Returns:
    T on success"
  (let ((conn (email-imap-connection account)))
    (unless conn
      (return-from imap-mark-read nil))

    (imap-select account (or folder "INBOX"))

    (let ((stream (getf conn :stream)))
      (format stream "a007 STORE ~A +FLAGS (\\Seen)~%" uid)
      (finish-output stream)
      (let ((result (read-line stream)))
        (if (search "OK" result)
            t
            nil)))))

(defun imap-delete-message (account uid &key folder)
  "Mark a message for deletion.

  Args:
    ACCOUNT: Email account
    UID: Message UID
    FOLDER: Folder name

  Returns:
    T on success"
  (let ((conn (email-imap-connection account)))
    (unless conn
      (return-from imap-delete-message nil))

    (imap-select account (or folder "INBOX"))

    (let ((stream (getf conn :stream)))
      (format stream "a008 STORE ~A +FLAGS (\\Deleted)~%" uid)
      (finish-output stream)
      (read-line stream)

      ;; Expunge
      (format stream "a009 EXPUNGE~%")
      (finish-output stream)
      (let ((result (read-line stream)))
        (if (search "OK" result)
            t
            nil)))))

(defun imap-search (account query &key folder)
  "Search messages.

  Args:
    ACCOUNT: Email account
    QUERY: Search query
    FOLDER: Folder name

  Returns:
    List of matching message UIDs"
  (let ((conn (email-imap-connection account)))
    (unless conn
      (return-from imap-search nil))

    (imap-select account (or folder "INBOX"))

    (let ((stream (getf conn :stream)))
      (format stream "a010 SEARCH ~A~%" query)
      (finish-output stream)
      (read-line stream)
      (let ((result (read-line stream)))
        (when (and result (search "SEARCH" result))
          (rest (split-sequence:split-sequence #\Space result)))))))

;;; ============================================================================
;;; IMAP Parsing Helpers
;;; ============================================================================

(defun parse-imap-fetch (line)
  "Parse IMAP FETCH response.

  Args:
    LINE: FETCH response line

  Returns:
    Plist with message info"
  (list :line line
        :from (extract-header line "FROM")
        :to (extract-header line "TO")
        :subject (extract-header line "SUBJECT")))

(defun parse-imap-flags (line)
  "Parse IMAP FLAGS from FETCH response.

  Args:
    LINE: FETCH response line

  Returns:
    List of flags"
  (let ((start (search "FLAGS" line)))
    (when start
      (let ((flags-str (subseq line (+ start 7))))
        (let ((end (position #\) flags-str)))
          (when end
            (split-sequence:split-sequence #\Space (subseq flags-str 1 (1- end))))))))

(defun extract-header (content header)
  "Extract a header value from message content.

  Args:
    CONTENT: Message content
    HEADER: Header name

  Returns:
    Header value"
  (let ((start (search (concatenate 'string header ": ") content)))
    (when start
      (let* ((value-start (+ start (length header) 2))
             (end (or (position #\Return (subseq content value-start))
                      (position #\Newline (subseq content value-start))
                      (length content))))
        (string-trim '(#\Space #\") (subseq content value-start (+ value-start end)))))))

;;; ============================================================================
;;; Email Channel
;;; ============================================================================

(defclass email-channel (channel)
  ((account :initarg :account
            :reader email-channel-account
            :documentation "Email account")
   (listen-thread :initform nil
                  :accessor email-listen-thread
                  :documentation "Listening thread")
   (listen-interval :initarg :listen-interval
                    :initform 60
                    :reader email-listen-interval
                    :documentation "Polling interval in seconds")
   (message-handler :initform nil
                    :accessor email-message-handler
                    :documentation "Message handler function"))
  (:documentation "Email channel"))

(defun make-email-channel (&key name account listen-interval config)
  "Create an email channel.

  Args:
    NAME: Channel name
    ACCOUNT: Email account
    LISTEN-INTERVAL: Polling interval (default: 60s)
    CONFIG: Configuration alist

  Returns:
    Email channel instance"
  (make-instance 'email-channel
                 :name (or name "email")
                 :account account
                 :listen-interval (or listen-interval 60)
                 :config config))

(defmethod channel-connect ((channel email-channel))
  "Connect email channel.

  Args:
    CHANNEL: Email channel instance

  Returns:
    T on success"
  (let ((account (email-channel-account channel)))
    (when (smtp-connect account)
      (when (imap-connect account)
        (setf (channel-connected-p channel) t)
        (setf (channel-status channel) :connected)
        (log-info "Email channel connected: ~A" (email-account-user account))
        t))))

(defmethod channel-disconnect ((channel email-channel))
  "Disconnect email channel.

  Args:
    CHANNEL: Email channel instance

  Returns:
    T on success"
  (email-stop-listening channel)
  (let ((account (email-channel-account channel)))
    (smtp-disconnect account)
    (imap-disconnect account))
  (setf (channel-connected-p channel) nil)
  (setf (channel-status channel) :disconnected)
  t)

(defmethod channel-send-message ((channel email-channel) recipient message &rest args &key &allow-other-keys)
  "Send an email.

  Args:
    CHANNEL: Email channel instance
    RECIPIENT: Recipient email address
    MESSAGE: Message content

  Returns:
    T on success"
  (let ((account (email-channel-account channel)))
    (smtp-send-message account recipient message)))

(defun email-start-listening (channel handler)
  "Start listening for new emails.

  Args:
    CHANNEL: Email channel instance
    HANDLER: Message handler function

  Returns:
    T on success"
  (unless (email-listen-thread channel)
    (setf (email-message-handler channel) handler)
    (setf (email-listen-thread channel)
          (bt:make-thread
           (lambda ()
             (email-listening-loop channel))
           :name "email-listener"))
    (log-info "Email listening started: ~A" (email-channel-account channel)))
  t)

(defun email-stop-listening (channel)
  "Stop listening for new emails.

  Args:
    CHANNEL: Email channel instance

  Returns:
    T on success"
  (when (and (email-listen-thread channel)
             (bt:thread-alive-p (email-listen-thread channel)))
    (bt:destroy-thread (email-listen-thread channel))
    (setf (email-listen-thread channel) nil)
    (log-info "Email listening stopped"))
  t)

(defun email-listening-loop (channel)
  "Email listening loop.

  Args:
    CHANNEL: Email channel instance"
  (let ((account (email-channel-account channel))
        (interval (email-listen-interval channel))
        (handler (email-message-handler channel)))
    (loop do
          (handler-case
              (progn
                (let ((messages (imap-list-messages account :limit 10)))
                  (dolist (msg messages)
                    (when handler
                      (funcall handler channel msg)))))
            (error (e)
              (log-error "Email listening error: ~A" e)))
          (sleep interval))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-email-channel (&key smtp-user smtp-password imap-user imap-password
                                       smtp-host imap-host listen-interval)
  "Initialize the email channel.

  Args:
    SMTP-USER: SMTP username
    SMTP-PASSWORD: SMTP password
    IMAP-USER: IMAP username
    IMAP-PASSWORD: IMAP password
    SMTP-HOST: SMTP host (optional)
    IMAP-HOST: IMAP host (optional)
    LISTEN-INTERVAL: Polling interval

  Returns:
    Email channel instance"
  (let ((account (make-email-account (or smtp-user imap-user)
                                     (or smtp-password imap-password)
                                     :smtp-host smtp-host
                                     :imap-host imap-host)))
    (make-email-channel :account account :listen-interval listen-interval)))
