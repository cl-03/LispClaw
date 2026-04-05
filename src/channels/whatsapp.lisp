;;; channels/whatsapp.lisp --- WhatsApp Channel for Lisp-Claw
;;;
;;; This file implements WhatsApp Business API integration:
;;; - Send/receive messages
;;; - Media support (images, documents, audio, video)
;;; - Template messages
;;; - Interactive messages (buttons, lists)
;;; - Status updates (sent, delivered, read)

(defpackage #:lisp-claw.channels.whatsapp
  (:nicknames #:lc.channels.whatsapp)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.channels.base)
  (:export
   ;; WhatsApp Channel class
   #:whatsapp-channel
   #:make-whatsapp-channel
   #:whatsapp-phone-id
   #:whatsapp-access-token
   #:whatsapp-business-account-id
   ;; Message sending
   #:whatsapp-send-text
   #:whatsapp-send-image
   #:whatsapp-send-document
   #:whatsapp-send-audio
   #:whatsapp-send-video
   #:whatsapp-send-location
   #:whatsapp-send-contact
   #:whatsapp-send-template
   #:whatsapp-send-interactive
   ;; Message receiving
   #:whatsapp-poll-messages
   #:whatsapp-webhook-handler
   ;; Status
   #:whatsapp-get-profile
   #:whatsapp-get-message-status
   ;; Media
   #:whatsapp-upload-media
   #:whatsapp-download-media
   ;; Business API
   #:whatsapp-send-bulk
   #:whatsapp-get-template-list))

(in-package #:lisp-claw.channels.whatsapp)

;;; ============================================================================
;;; WhatsApp Channel Class
;;; ============================================================================

(defclass whatsapp-channel (channel)
  ((phone-id :initarg :phone-id
             :reader whatsapp-phone-id
             :documentation "WhatsApp phone number ID")
   (access-token :initarg :access-token
                 :reader whatsapp-access-token
                 :documentation "WhatsApp API access token")
   (business-account-id :initarg :business-account-id
                        :reader whatsapp-business-account-id
                        :documentation "Business account ID")
   (api-version :initarg :api-version
                :initform "v18.0"
                :reader whatsapp-api-version
                :documentation "WhatsApp API version")
   (base-url :initform "https://graph.facebook.com"
             :accessor whatsapp-base-url
             :documentation "WhatsApp API base URL")
   (webhook-verify-token :initarg :webhook-verify-token
                         :initform nil
                         :reader whatsapp-webhook-verify-token
                         :documentation "Webhook verification token")
   (message-queue :initform (make-instance 'bt:condition-variable)
                  :accessor whatsapp-message-queue
                  :documentation "Message queue for polling")
   (last-cursor :initform nil
                :accessor whatsapp-last-cursor
                :documentation "Last message cursor for pagination")))

(defmethod print-object ((channel whatsapp-channel) stream)
  (print-unreadable-object (channel stream :type t)
    (format t "~A [~A]"
            (or (whatsapp-phone-id channel) "WhatsApp")
            (if (channel-connected-p channel) "connected" "disconnected"))))

;;; ============================================================================
;;; Construction
;;; ============================================================================

(defun make-whatsapp-channel (&key name phone-id access-token business-account-id
                                    webhook-verify-token config)
  "Create a new WhatsApp channel instance.

  Args:
    NAME: Channel name
    PHONE-ID: WhatsApp phone number ID
    ACCESS-TOKEN: API access token
    BUSINESS-ACCOUNT-ID: Business account ID
    WEBHOOK-VERIFY-TOKEN: Webhook verification token
    CONFIG: Configuration alist

  Returns:
    WhatsApp channel instance"
  (let ((channel (make-instance 'whatsapp-channel
                                :name (or name "whatsapp")
                                :phone-id (or phone-id (getf config :phone-id))
                                :access-token (or access-token (getf config :access-token))
                                :business-account-id (or business-account-id
                                                         (getf config :business-account-id))
                                :webhook-verify-token (or webhook-verify-token
                                                          (getf config :webhook-verify-token))
                                :config config)))
    (log-info "WhatsApp channel created: ~A" (whatsapp-phone-id channel))
    channel))

;;; ============================================================================
;;; Channel Lifecycle
;;; ============================================================================

(defmethod channel-connect ((channel whatsapp-channel))
  "Connect to WhatsApp Business API.

  Args:
    CHANNEL: WhatsApp channel instance

  Returns:
    T on success"
  (handler-case
      (progn
        ;; Verify connection by getting profile
        (let ((profile (whatsapp-get-profile channel)))
          (when profile
            (log-info "WhatsApp connected: ~A" (getf profile :display-phone-number))))

        (setf (channel-connected-p channel) t)
        (setf (channel-status channel) :connected)
        (setf (channel-connect-time channel) (get-universal-time))

        (log-info "WhatsApp channel connected: ~A" (whatsapp-phone-id channel))
        t)
    (error (e)
      (log-error "Failed to connect WhatsApp: ~A" e)
      (setf (channel-last-error channel) e)
      (incf (channel-error-count channel))
      nil)))

(defmethod channel-disconnect ((channel whatsapp-channel))
  "Disconnect from WhatsApp.

  Args:
    CHANNEL: WhatsApp channel instance

  Returns:
    T on success"
  (setf (channel-connected-p channel) nil)
  (setf (channel-status channel) :disconnected)
  (log-info "WhatsApp channel disconnected")
  t)

;;; ============================================================================
;;; API Client
;;; ============================================================================

(defun whatsapp-api-request (channel endpoint &key method body)
  "Make a request to WhatsApp Business API.

  Args:
    CHANNEL: WhatsApp channel instance
    ENDPOINT: API endpoint
    METHOD: HTTP method
    BODY: Request body

  Returns:
    Response alist or NIL"
  (let* ((url (format nil "~A/~A/~A"
                      (whatsapp-base-url channel)
                      (whatsapp-api-version channel)
                      endpoint))
         (headers (list (cons "Authorization" (format nil "Bearer ~A" (whatsapp-access-token channel)))
                        (cons "Content-Type" "application/json")))
         (method (or method :get)))
    (handler-case
        (let ((response (ecase method
                          (:get (dex:get url :headers headers))
                          (:post (dex:post url :headers headers
                                           :content (when body (stringify-json body))))
                          (:put (dex:put url :headers headers
                                         :content (when body (stringify-json body)))))))
          (log-debug "WhatsApp API ~A ~A -> ~A" method endpoint response)
          (parse-json response))
      (error (e)
        (log-error "WhatsApp API request failed: ~A - ~A" endpoint e)
        (incf (channel-error-count channel))
        nil))))

;;; ============================================================================
;;; Message Sending
;;; ============================================================================

(defun whatsapp-send-text (channel recipient message &key preview-url)
  "Send a text message.

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENT: Recipient phone number
    MESSAGE: Message text
    PREVIEW-URL: Enable link preview

  Returns:
    Message ID or NIL"
  (let ((body (list :messaging_product "whatsapp"
                    :to recipient
                    :type "text"
                    :text (list :body message
                                :preview_url (if preview-url "true" "false")))))
    (let ((endpoint (format nil "~A/messages" (whatsapp-business-account-id channel))))
      (let ((result (whatsapp-api-request channel endpoint :method :post :body body)))
        (when result
          (let ((id (json-get result :messages 0 :id)))
            (log-info "WhatsApp text sent to ~A: ~A" recipient id)
            id)))))

(defun whatsapp-send-image (channel recipient image-url &key caption)
  "Send an image message.

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENT: Recipient phone number
    IMAGE-URL: Image URL or media ID
    CAPTION: Optional caption

  Returns:
    Message ID or NIL"
  (let ((body (list :messaging_product "whatsapp"
                    :to recipient
                    :type "image"
                    :image (append (list :link image-url)
                                   (when caption (list :caption caption))))))
    (let ((endpoint (format nil "~A/messages" (whatsapp-business-account-id channel))))
      (let ((result (whatsapp-api-request channel endpoint :method :post :body body)))
        (when result
          (json-get result :messages 0 :id)))))

(defun whatsapp-send-document (channel recipient document-url &key filename caption)
  "Send a document message.

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENT: Recipient phone number
    DOCUMENT-URL: Document URL or media ID
    FILENAME: Optional filename
    CAPTION: Optional caption

  Returns:
    Message ID or NIL"
  (let ((body (list :messaging-product "whatsapp"
                    :to recipient
                    :type "document"
                    :document (append (list :link document-url)
                                      (when filename (list :filename filename))
                                      (when caption (list :caption caption))))))
    (let ((endpoint (format nil "~A/messages" (whatsapp-business-account-id channel))))
      (let ((result (whatsapp-api-request channel endpoint :method :post :body body)))
        (when result
          (json-get result :messages 0 :id)))))

(defun whatsapp-send-audio (channel recipient audio-url)
  "Send an audio message.

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENT: Recipient phone number
    AUDIO-URL: Audio URL or media ID

  Returns:
    Message ID or NIL"
  (let ((body (list :messaging-product "whatsapp"
                    :to recipient
                    :type "audio"
                    :audio (list :link audio-url))))
    (let ((endpoint (format nil "~A/messages" (whatsapp-business-account-id channel))))
      (let ((result (whatsapp-api-request channel endpoint :method :post :body body)))
        (when result
          (json-get result :messages 0 :id)))))

(defun whatsapp-send-video (channel recipient video-url &key caption)
  "Send a video message.

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENT: Recipient phone number
    VIDEO-URL: Video URL or media ID
    CAPTION: Optional caption

  Returns:
    Message ID or NIL"
  (let ((body (list :messaging-product "whatsapp"
                    :to recipient
                    :type "video"
                    :video (append (list :link video-url)
                                   (when caption (list :caption caption))))))
    (let ((endpoint (format nil "~A/messages" (whatsapp-business-account-id channel))))
      (let ((result (whatsapp-api-request channel endpoint :method :post :body body)))
        (when result
          (json-get result :messages 0 :id)))))

(defun whatsapp-send-location (channel recipient latitude longitude &key name address)
  "Send a location message.

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENT: Recipient phone number
    LATITUDE: Latitude
    LONGITUDE: Longitude
    NAME: Location name
    ADDRESS: Location address

  Returns:
    Message ID or NIL"
  (let ((body (list :messaging-product "whatsapp"
                    :to recipient
                    :type "location"
                    :location (append (list :latitude (format nil "~A" latitude)
                                            :longitude (format nil "~A" longitude))
                                      (when name (list :name name))
                                      (when address (list :address address))))))
    (let ((endpoint (format nil "~A/messages" (whatsapp-business-account-id channel))))
      (let ((result (whatsapp-api-request channel endpoint :method :post :body body)))
        (when result
          (json-get result :messages 0 :id)))))

(defun whatsapp-send-contact (channel recipient contact)
  "Send a contact message.

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENT: Recipient phone number
    CONTACT: Contact plist (:name, :phone, :email, :org)

  Returns:
    Message ID or NIL"
  (let ((body (list :messaging_product "whatsapp"
                    :to recipient
                    :type "contacts"
                    :contacts (vector (list :name (list :formatted_name (getf contact :name))
                                            :phones (vector (list :phone (getf contact :phone)))
                                            :emails (when (getf contact :email)
                                                      (vector (list :email (getf contact :email))))
                                            :org (when (getf contact :org)
                                                   (list :company (getf contact :org))))))))
    (let ((endpoint (format nil "~A/messages" (whatsapp-business-account-id channel))))
      (let ((result (whatsapp-api-request channel endpoint :method :post :body body)))
        (when result
          (json-get result :messages 0 :id)))))

(defun whatsapp-send-template (channel recipient template-name language &key components)
  "Send a template message.

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENT: Recipient phone number
    TEMPLATE-NAME: Template name
    LANGUAGE: Language code (e.g., \"en_US\")
    COMPONENTS: Template components (vector)

  Returns:
    Message ID or NIL"
  (let ((body (list :messaging_product "whatsapp"
                    :to recipient
                    :type "template"
                    :template (list :name template-name
                                    :language (list :code language)
                                    :components components))))
    (let ((endpoint (format nil "~A/messages" (whatsapp-business-account-id channel))))
      (let ((result (whatsapp-api-request channel endpoint :method :post :body body)))
        (when result
          (json-get result :messages 0 :id)))))

(defun whatsapp-send-interactive (channel recipient interactive-type &key header body footer action)
  "Send an interactive message (buttons or list).

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENT: Recipient phone number
    INTERACTIVE-TYPE: Type (:button, :list)
    HEADER: Optional header
    BODY: Message body
    FOOTER: Optional footer
    ACTION: Action object

  Returns:
    Message ID or NIL"
  (let ((interactive (list :type (ecase interactive-type
                                 (:button "button")
                                 (:list "list"))
                           :body (list :text body)
                           :header (when header header)
                           :footer (when footer (list :text footer))
                           :action action)))
    (let ((msg-body (list :messaging_product "whatsapp"
                          :to recipient
                          :type "interactive"
                          :interactive interactive)))
      (let ((endpoint (format nil "~A/messages" (whatsapp-business-account-id channel))))
        (let ((result (whatsapp-api-request channel endpoint :method :post :body msg-body)))
          (when result
            (json-get result :messages 0 :id)))))))

;;; ============================================================================
;;; Message Receiving
;;; ============================================================================

(defun whatsapp-poll-messages (channel &key since)
  "Poll for new messages.

  Args:
    CHANNEL: WhatsApp channel instance
    SINCE: Optional message ID to poll since

  Returns:
    List of messages"
  (let* ((endpoint (format nil "~A/messages" (whatsapp-business-account-id channel)))
         (params (list (cons :limit "100")))
         (url (format nil "~A/~A/~A?~{~A=~A~^&~}"
                      (whatsapp-base-url channel)
                      (whatsapp-api-version channel)
                      endpoint
                      params)))
    (let ((headers (list (cons "Authorization" (format nil "Bearer ~A" (whatsapp-access-token channel)))))
          (result (dex:get url :headers headers)))
      (when result
        (let ((messages (json-get result :data)))
          (when messages
            (setf (whatsapp-last-cursor channel) (json-get result :paging :cursors :after))
            (loop for msg across messages
                  collect (list :from (json-get msg :from)
                                :id (json-get msg :id)
                                :timestamp (json-get msg :timestamp)
                                :type (json-get msg :type)
                                :text (json-get msg :text :body)
                                :image (json-get msg :image)
                                :document (json-get msg :document)))))))))

(defun whatsapp-webhook-handler (request)
  "Handle incoming webhook from WhatsApp.

  Args:
    REQUEST: Request plist

  Returns:
    Response plist"
  (let* ((body (getf request :body))
         (data (if (stringp body) (parse-json body) body))
         (object (json-get data :object)))

    (when (string= object "whatsapp_business_account")
      (let ((changes (json-get data :entry 0 :changes)))
        (when changes
          (loop for change across changes
                do (let ((value (json-get change :value)))
                     (when (json-get value :messages)
                       (loop for msg across (json-get value :messages)
                             do (log-info "WhatsApp message from ~A: ~A"
                                          (json-get msg :from)
                                          (json-get msg :text :body)))))))))

    '(:status 200 :body "OK")))

;;; ============================================================================
;;; Status and Profile
;;; ============================================================================

(defun whatsapp-get-profile (channel)
  "Get WhatsApp Business profile.

  Args:
    CHANNEL: WhatsApp channel instance

  Returns:
    Profile plist or NIL"
  (let ((endpoint (format nil "~A" (whatsapp-phone-id channel))))
    (let ((result (whatsapp-api-request channel endpoint)))
      (when result
        (list :id (json-get result :id)
              :display-phone-number (json-get result :display_phone_number)
              :verified-name (json-get result :verified_name)
              :quality-rating (json-get result :quality_rating))))))

(defun whatsapp-get-message-status (channel message-id)
  "Get message delivery status.

  Args:
    CHANNEL: WhatsApp channel instance
    MESSAGE-ID: Message ID

  Returns:
    Status plist or NIL"
  (let ((endpoint (format nil "~A/messages?ids=~A" (whatsapp-phone-id channel) message-id)))
    (let ((result (whatsapp-api-request channel endpoint)))
      (when result
        (let ((msg (json-get result :messages 0)))
          (list :id (json-get msg :id)
                :recipient-id (json-get msg :recipient_id)
                :message-status (json-get msg :message_status)))))))

;;; ============================================================================
;;; Media Management
;;; ============================================================================

(defun whatsapp-upload-media (channel media-type file-path &key caption)
  "Upload media to WhatsApp.

  Args:
    CHANNEL: WhatsApp channel instance
    MEDIA-TYPE: Media type (image, document, audio, video)
    FILE-PATH: File path
    CAPTION: Optional caption

  Returns:
    Media ID or NIL"
  (let ((endpoint (format nil "~A/media" (whatsapp-business-account-id channel)))
        (type-map '((:image . "image/jpeg")
                    (:document . "application/pdf")
                    (:audio . "audio/mpeg")
                    (:video . "video/mp4"))))
    ;; Implementation would use multipart upload
    (log-info "WhatsApp media upload: ~A - ~A" media-type file-path)
    nil))

(defun whatsapp-download-media (channel media-id)
  "Download media from WhatsApp.

  Args:
    CHANNEL: WhatsApp channel instance
    MEDIA-ID: Media ID

  Returns:
    Media URL or NIL"
  (let ((endpoint (format nil "~A" media-id)))
    (let ((result (whatsapp-api-request channel endpoint)))
      (when result
        (json-get result :url)))))

;;; ============================================================================
;;; Bulk Messaging
;;; ============================================================================

(defun whatsapp-send-bulk (channel recipients message &key delay)
  "Send bulk messages.

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENTS: List of recipient numbers
    MESSAGE: Message text
    DELAY: Delay between messages (seconds)

  Returns:
    List of message IDs"
  (let ((results nil))
    (dolist (recipient recipients)
      (let ((id (whatsapp-send-text channel recipient message)))
        (when id
          (push id results))
        (when delay
          (sleep delay))))
    (nreverse results)))

(defun whatsapp-get-template-list (channel)
  "Get list of message templates.

  Args:
    CHANNEL: WhatsApp channel instance

  Returns:
    List of templates"
  (let ((endpoint (format nil "~A/message_templates" (whatsapp-business-account-id channel))))
    (let ((result (whatsapp-api-request channel endpoint)))
      (when result
        (let ((templates (json-get result :data)))
          (when templates
            (loop for tmpl across templates
                  collect (list :name (json-get tmpl :name)
                                :language (json-get tmpl :language)
                                :status (json-get tmpl :status)
                                :category (json-get tmpl :category)))))))))

;;; ============================================================================
;;; Channel Interface Implementation
;;; ============================================================================

(defmethod channel-send-message ((channel whatsapp-channel) recipient message &rest args &key &allow-other-keys)
  "Send a WhatsApp message.

  Args:
    CHANNEL: WhatsApp channel instance
    RECIPIENT: Recipient phone number
    MESSAGE: Message content

  Returns:
    Message ID or NIL"
  (whatsapp-send-text channel recipient message))

(defmethod channel-receive-message ((channel whatsapp-channel) &key timeout)
  "Receive WhatsApp messages.

  Args:
    CHANNEL: WhatsApp channel instance
    TIMEOUT: Timeout in seconds

  Returns:
    Message or NIL"
  (let ((messages (whatsapp-poll-messages channel)))
    (when messages
      (first messages))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-whatsapp-channel (&key phone-id access-token business-account-id
                                          webhook-verify-token config)
  "Initialize the WhatsApp channel.

  Args:
    PHONE-ID: Phone number ID
    ACCESS-TOKEN: API access token
    BUSINESS-ACCOUNT-ID: Business account ID
    WEBHOOK-VERIFY-TOKEN: Webhook verification token
    CONFIG: Additional configuration

  Returns:
    WhatsApp channel instance"
  (let ((channel (make-whatsapp-channel
                  :phone-id phone-id
                  :access-token access-token
                  :business-account-id business-account-id
                  :webhook-verify-token webhook-verify-token
                  :config config)))
    (channel-connect channel)
    channel))
