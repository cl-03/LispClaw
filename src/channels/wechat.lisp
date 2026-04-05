;;; channels/wechat.lisp --- WeChat Channel for Lisp-Claw
;;;
;;; This file implements WeChat (Weixin) integration using WeChat Official Account API.
;;; Supports text, image, voice, video, and template messages.

(defpackage #:lisp-claw.channels.wechat
  (:nicknames #:lc.channels.wechat)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.channels.base)
  (:export
   ;; WeChat channel class
   #:wechat-channel
   #:make-wechat-channel
   #:wechat-app-id
   #:wechat-app-secret
   #:wechat-token
   #:wechat-aes-key
   #:wechat-access-token
   ;; Message types
   #:wechat-message-text
   #:wechat-message-image
   #:wechat-message-voice
   #:wechat-message-video
   #:wechat-message-location
   #:wechat-message-link
   #:wechat-message-event
   ;; Sending messages
   #:wechat-send-text
   #:wechat-send-image
   #:wechat-send-voice
   #:wechat-send-video
   #:wechat-send-music
   #:wechat-send-news
   #:wechat-send-template
   #:wechat-send-customer-service
   ;; Webhook handling
   #:wechat-verify-server
   #:wechat-handle-message
   #:wechat-parse-incoming-message
   ;; Access token management
   #:wechat-refresh-access-token
   #:wechat-get-access-token
   ;; User management
   #:wechat-get-user-info
   #:wechat-get-user-list
   #:wechat-send-customer-service-message
   ;; Menu management
   #:wechat-create-menu
   #:wechat-delete-menu
   #:wechat-get-menu))

(in-package #:lisp-claw.channels.wechat)

;;; ============================================================================
;;; WeChat Channel Class
;;; ============================================================================

(defclass wechat-channel (channel)
  ((app-id :initarg :app-id
           :reader wechat-app-id
           :documentation "WeChat AppID (公众号 AppID)")
   (app-secret :initarg :app-secret
               :reader wechat-app-secret
               :documentation "WeChat AppSecret")
   (token :initarg :token
          :reader wechat-token
          :documentation "Token for server verification")
   (aes-key :initarg :aes-key
            :initform nil
            :reader wechat-aes-key
            :documentation "Encoding AES key for encrypted messages")
   (access-token :initform nil
                 :accessor wechat-access-token
                 :documentation "Cached access token")
   (token-expires-at :initform 0
                     :accessor wechat-token-expires-at
                     :documentation "Access token expiration time")
   (api-base :initform "https://api.weixin.qq.com/cgi-bin"
             :accessor wechat-api-base
             :documentation "WeChat API base URL"))
  (:documentation "WeChat Official Account channel"))

(defmethod print-object ((channel wechat-channel) stream)
  (print-unreadable-object (channel stream :type t)
    (format stream "~A [~A]"
            (wechat-app-id channel)
            (if (channel-connected-p channel) "connected" "disconnected"))))

(defun make-wechat-channel (app-id app-secret token &key aes-key)
  "Create a WeChat channel.

  Args:
    APP-ID: WeChat Official Account AppID
    APP-SECRET: WeChat Official Account AppSecret
    TOKEN: Token for server verification
    AES-KEY: Encoding AES key (optional, for encrypted messages)

  Returns:
    WeChat channel instance"
  (make-instance 'wechat-channel
                 :app-id app-id
                 :app-secret app-secret
                 :token token
                 :aes-key aes-key))

;;; ============================================================================
;;; Access Token Management
;;; ============================================================================

(defun wechat-get-access-token (channel)
  "Get cached access token, refresh if expired.

  Args:
    CHANNEL: WeChat channel instance

  Returns:
    Access token string"
  (let ((now (get-universal-time)))
    (if (and (wechat-access-token channel)
             (< now (wechat-token-expires-at channel)))
        (wechat-access-token channel)
        (wechat-refresh-access-token channel))))

(defun wechat-refresh-access-token (channel)
  "Refresh access token from WeChat.

  Args:
    CHANNEL: WeChat channel instance

  Returns:
    New access token string"
  (let* ((url (format nil "~A/token?grant_type=client_credential&appid=~A&secret=~A"
                      (wechat-api-base channel)
                      (wechat-app-id channel)
                      (wechat-app-secret channel)))
         (response (dexador:get url))
         (data (parse-json response)))

    (if (getf data :access_token)
        (let ((token (getf data :access_token))
              (expires-in (getf data :expires_in 7200)))
          (setf (wechat-access-token channel) token)
          (setf (wechat-token-expires-at channel)
                (+ (get-universal-time) (- expires-in 300)))  ; Refresh 5 min early
          (log-info "WeChat access token refreshed, expires in ~A seconds" expires-in)
          token)
        (progn
          (log-error "Failed to refresh WeChat access token: ~A" data)
          (error "WeChat API error: ~A" (getf data :errmsg))))))

;;; ============================================================================
;;; Message Classes
;;; ============================================================================

(defclass wechat-message-text ()
  ((content :initarg :content
            :reader wechat-text-content
            :documentation "Text content"))
  (:documentation "WeChat text message"))

(defclass wechat-message-image ()
  ((media-id :initarg :media-id
             :reader wechat-image-media-id
             :documentation "Image media ID"))
  (:documentation "WeChat image message"))

(defclass wechat-message-voice ()
  ((media-id :initarg :media-id
             :reader wechat-voice-media-id
             :documentation "Voice media ID")
   (title :initarg :title
          :initform nil
          :reader wechat-voice-title
          :documentation "Voice title"))
  (:documentation "WeChat voice message"))

(defclass wechat-message-video ()
  ((media-id :initarg :media-id
             :reader wechat-video-media-id
             :documentation "Video media ID")
   (title :initarg :title
          :initform nil
          :reader wechat-video-title
          :documentation "Video title")
   (description :initarg :description
                :initform nil
                :reader wechat-video-description
                :documentation "Video description"))
  (:documentation "WeChat video message"))

(defclass wechat-message-music ()
  ((title :initarg :title
          :reader wechat-music-title
          :documentation "Music title")
   (description :initarg :description
                :reader wechat-music-description
                :documentation "Music description")
   (music-url :initarg :music-url
              :reader wechat-music-url
              :documentation "Music URL")
   (hq-music-url :initarg :hq-music-url
                 :reader wechat-music-hq-url
                 :documentation "High quality music URL")
   (thumb-media-id :initarg :thumb-media-id
                   :reader wechat-music-thumb-id
                   :documentation "Thumbnail media ID"))
  (:documentation "WeChat music message"))

(defclass wechat-message-news ()
  ((articles :initarg :articles
             :reader wechat-news-articles
             :documentation "List of news articles"))
  (:documentation "WeChat news (multiple articles) message"))

(defclass wechat-message-template ()
  ((template-id :initarg :template-id
                :reader wechat-template-id
                :documentation "Template ID")
   (data :initarg :data
         :reader wechat-template-data
         :documentation "Template data plist")
   (url :initarg :url
        :initform nil
        :reader wechat-template-url
        :documentation "Click URL")
   (miniprogram :initarg :miniprogram
                :initform nil
                :reader wechat-template-miniprogram
                :documentation "Mini program info"))
  (:documentation "WeChat template message"))

;;; ============================================================================
;;; Sending Messages
;;; ============================================================================

(defun wechat-send-text (channel user-id content)
  "Send text message to user.

  Args:
    CHANNEL: WeChat channel instance
    USER-ID: User's WeChat openid
    CONTENT: Text content

  Returns:
    T on success"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/message/custom/send?access_token=~A"
                      (wechat-api-base channel) token))
         (body (json-to-string
                (list :touser user-id
                      :msgtype "text"
                      :text (list :content content)))))

    (let ((response (dexador:post url :content body)))
      (let ((data (parse-json response)))
        (if (or (getf data :errmsg) (equal (getf data :errcode) 0))
            (progn
              (log-info "WeChat text message sent to ~A" user-id)
              t)
            (progn
              (log-error "WeChat send message failed: ~A" data)
              nil))))))

(defun wechat-send-image (channel user-id media-id)
  "Send image message to user.

  Args:
    CHANNEL: WeChat channel instance
    USER-ID: User's WeChat openid
    MEDIA-ID: Image media ID (upload first)

  Returns:
    T on success"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/message/custom/send?access_token=~A"
                      (wechat-api-base channel) token))
         (body (json-to-string
                (list :touser user-id
                      :msgtype "image"
                      :image (list :media_id media-id)))))

    (let ((response (dexador:post url :content body)))
      (let ((data (parse-json response)))
        (if (or (getf data :errmsg) (equal (getf data :errcode) 0))
            (progn
              (log-info "WeChat image message sent to ~A" user-id)
              t)
            (progn
              (log-error "WeChat send image failed: ~A" data)
              nil))))))

(defun wechat-send-voice (channel user-id media-id &key title)
  "Send voice message to user.

  Args:
    CHANNEL: WeChat channel instance
    USER-ID: User's WeChat openid
    MEDIA-ID: Voice media ID
    TITLE: Optional title

  Returns:
    T on success"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/message/custom/send?access_token=~A"
                      (wechat-api-base channel) token))
         (body (json-to-string
                (list :touser user-id
                      :msgtype "voice"
                      :voice (list :media_id media-id
                                   :title title)))))

    (let ((response (dexador:post url :content body)))
      (let ((data (parse-json response)))
        (if (or (getf data :errmsg) (equal (getf data :errcode) 0))
            (progn
              (log-info "WeChat voice message sent to ~A" user-id)
              t)
            (progn
              (log-error "WeChat send voice failed: ~A" data)
              nil))))))

(defun wechat-send-video (channel user-id media-id &key title description)
  "Send video message to user.

  Args:
    CHANNEL: WeChat channel instance
    USER-ID: User's WeChat openid
    MEDIA-ID: Video media ID
    TITLE: Optional title
    DESCRIPTION: Optional description

  Returns:
    T on success"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/message/custom/send?access_token=~A"
                      (wechat-api-base channel) token))
         (body (json-to-string
                (list :touser user-id
                      :msgtype "video"
                      :video (list :media_id media-id
                                   :title (or title "")
                                   :description (or description ""))))))

    (let ((response (dexador:post url :content body)))
      (let ((data (parse-json response)))
        (if (or (getf data :errmsg) (equal (getf data :errcode) 0))
            (progn
              (log-info "WeChat video message sent to ~A" user-id)
              t)
            (progn
              (log-error "WeChat send video failed: ~A" data)
              nil))))))

(defun wechat-send-music (channel user-id title description music-url hq-music-url thumb-media-id)
  "Send music message to user.

  Args:
    CHANNEL: WeChat channel instance
    USER-ID: User's WeChat openid
    TITLE: Music title
    DESCRIPTION: Music description
    MUSIC-URL: Music URL
    HQ-MUSIC-URL: High quality music URL
    THUMB-MEDIA-ID: Thumbnail media ID

  Returns:
    T on success"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/message/custom/send?access_token=~A"
                      (wechat-api-base channel) token))
         (body (json-to-string
                (list :touser user-id
                      :msgtype "music"
                      :music (list :title title
                                   :description description
                                   :musicurl music-url
                                   :hqmusicurl hq-music-url
                                   :thumb_media_id thumb-media-id)))))

    (let ((response (dexador:post url :content body)))
      (let ((data (parse-json response)))
        (if (or (getf data :errmsg) (equal (getf data :errcode) 0))
            (progn
              (log-info "WeChat music message sent to ~A" user-id)
              t)
            (progn
              (log-error "WeChat send music failed: ~A" data)
              nil))))))

(defun wechat-send-news (channel user-id articles)
  "Send news (multiple articles) message to user.

  Args:
    CHANNEL: WeChat channel instance
    USER-ID: User's WeChat openid
    ARTICLES: List of article plists (:title :description :url :picurl)

  Returns:
    T on success"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/message/custom/send?access_token=~A"
                      (wechat-api-base channel) token))
         (articles-data (mapcar (lambda (article)
                                  (list :title (getf article :title)
                                        :description (getf article :description)
                                        :url (getf article :url)
                                        :picurl (getf article :picurl)))
                                articles))
         (body (json-to-string
                (list :touser user-id
                      :msgtype "news"
                      :news (list :articles articles-data)))))

    (let ((response (dexador:post url :content body)))
      (let ((data (parse-json response)))
        (if (or (getf data :errmsg) (equal (getf data :errcode) 0))
            (progn
              (log-info "WeChat news message sent to ~A" user-id)
              t)
            (progn
              (log-error "WeChat send news failed: ~A" data)
              nil))))))

(defun wechat-send-template (channel user-id template-id data &key url miniprogram)
  "Send template message to user.

  Args:
    CHANNEL: WeChat channel instance
    USER-ID: User's WeChat openid
    TEMPLATE-ID: Template ID
    DATA: Template data plist
    URL: Optional click URL
    MINIPROGRAM: Optional mini program info (:appid :pagepath)

  Returns:
    T on success"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/message/template/send?access_token=~A"
                      (wechat-api-base channel) token))
         (body (json-to-string
                (append (list :touser user-id
                              :template_id template-id
                              :data data)
                        (when url (list :url url))
                        (when miniprogram (list :miniprogram miniprogram))))))

    (let ((response (dexador:post url :content body)))
      (let ((data (parse-json response)))
        (if (or (getf data :errmsg) (equal (getf data :errcode) 0))
            (progn
              (log-info "WeChat template message sent to ~A" user-id)
              t)
            (progn
              (log-error "WeChat send template failed: ~A" data)
              nil))))))

(defun wechat-send-customer-service-message (channel user-id msgtype content)
  "Send customer service message.

  Args:
    CHANNEL: WeChat channel instance
    USER-ID: User's WeChat openid
    MSGTYPE: Message type (text, image, voice, etc.)
    CONTENT: Message content

  Returns:
    T on success"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/message/custom/send?access_token=~A"
                      (wechat-api-base channel) token))
         (body (json-to-string
                (list :touser user-id
                      :msgtype msgtype
                      msgtype content))))

    (let ((response (dexador:post url :content body)))
      (let ((data (parse-json response)))
        (if (or (getf data :errmsg) (equal (getf data :errcode) 0))
            t
            nil)))))

;;; ============================================================================
;;; Webhook Handling
;;; ============================================================================

(defun wechat-verify-server (channel signature timestamp nonce echo-str)
  "Verify WeChat server configuration.

  Args:
    CHANNEL: WeChat channel instance
    SIGNATURE: SHA1 signature from WeChat
    TIMESTAMP: Timestamp
    NONCE: Random nonce
    ECHO-STR: String to echo back

  Returns:
    ECHO-STR if verification succeeds, NIL otherwise"
  (let* ((token (wechat-token channel))
         (list (sort (list token timestamp nonce) #'string<))
         (concatenated (format nil "~{~A~}" list))
         (computed-signature (string-upcase
                              (ironclad:byte-array-to-hex-string
                               (ironclad:digest-sequence :sha1
                                                         (babel:string-to-octets concatenated))))))

    (if (string= signature computed-signature)
        (progn
          (log-info "WeChat server verification successful")
          echo-str)
        (progn
          (log-warning "WeChat server verification failed")
          nil))))

(defun wechat-parse-incoming-message (xml-data)
  "Parse incoming WeChat message XML.

  Args:
    XML-DATA: XML string from WeChat

  Returns:
    Message plist"
  ;; Simple XML parsing (in production, use a proper XML parser)
  (let ((result (make-hash-table :test 'equal)))
    ;; Extract basic fields
    (dolist (field '("ToUserName" "FromUserName" "CreateTime" "MsgType"
                     "Content" "MsgId" "PicUrl" "MediaId" "Format"
                     "Recognition" "ThumbMediaId" "Location_X" "Location_Y"
                     "Scale" "Label" "Title" "Description" "Url" "Event"
                     "EventKey" "Ticket"))
      (let ((start (search (format nil "<~A>" field) xml-data))
            (end (search (format nil "</~A>" field) xml-data)))
        (when (and start end)
          (setf (gethash (string-downcase field) result)
                (subseq xml-data (+ start (length field) 2) end)))))
    result))

(defun wechat-handle-message (channel request-data)
  "Handle incoming WeChat message.

  Args:
    CHANNEL: WeChat channel instance
    REQUEST-DATA: Request data (XML or JSON)

  Returns:
    Response XML string"
  (let ((parsed (wechat-parse-incoming-message request-data))
        (msg-type (gethash "msgtype" parsed))
        (from-user (gethash "fromusername" parsed))
        (to-user (gethash "tousername" parsed))
        (create-time (parse-integer (gethash "createtime" parsed) :junk-allowed t)))

    (log-info "WeChat message from ~A: ~A" from-user msg-type)

    (cond
      ;; Text message
      ((string= msg-type "text")
       (let ((content (gethash "content" parsed)))
         (format nil "<xml>
<ToUserName><![CDATA[~A]]></ToUserName>
<FromUserName><![CDATA[~A]]></FromUserName>
<CreateTime>~A</CreateTime>
<MsgType><![CDATA[text]]></MsgType>
<Content><![CDATA[Received: ~A]]></Content>
</xml>" to-user from-user create-time content)))

      ;; Image message
      ((string= msg-type "image")
       (let ((pic-url (gethash "picurl" parsed))
             (media-id (gethash "mediaid" parsed)))
         (format nil "<xml>
<ToUserName><![CDATA[~A]]></ToUserName>
<FromUserName><![CDATA[~A]]></FromUserName>
<CreateTime>~A</CreateTime>
<MsgType><![CDATA[text]]></MsgType>
<Content><![CDATA[Image received: ~A]]></Content>
</xml>" to-user from-user create-time pic-url)))

      ;; Event: Subscribe
      ((and (string= msg-type "event")
            (string= (gethash "event" parsed) "subscribe"))
       (format nil "<xml>
<ToUserName><![CDATA[~A]]></ToUserName>
<FromUserName><![CDATA[~A]]></FromUserName>
<CreateTime>~A</CreateTime>
<MsgType><![CDATA[text]]></MsgType>
<Content><![CDATA[欢迎关注！]]></Content>
</xml>" to-user from-user create-time))

      ;; Default response
      (t
       (format nil "<xml>
<ToUserName><![CDATA[~A]]></ToUserName>
<FromUserName><![CDATA[~A]]></FromUserName>
<CreateTime>~A</CreateTime>
<MsgType><![CDATA[text]]></MsgType>
<Content><![CDATA[Message received]]></Content>
</xml>" to-user from-user create-time)))))

;;; ============================================================================
;;; Media Management
;;; ============================================================================

(defun wechat-upload-temporary-media (channel type file-path)
  "Upload temporary media to WeChat.

  Args:
    CHANNEL: WeChat channel instance
    TYPE: Media type (image, voice, video, thumb)
    FILE-PATH: Path to media file

  Returns:
    Media ID string"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/media/upload?access_token=~A&type=~A"
                      (wechat-api-base channel) token type))
         (response (dexador:post url
                                 :file (list (cons "media" file-path)))))
    (let ((data (parse-json response)))
      (if (getf data :media_id)
          (let ((media-id (getf data :media_id)))
            (log-info "WeChat media uploaded: ~A" media-id)
            media-id)
          (progn
            (log-error "WeChat media upload failed: ~A" data)
            (error "WeChat upload error: ~A" (getf data :errmsg)))))))

(defun wechat-download-media (channel media-id)
  "Download media from WeChat.

  Args:
    CHANNEL: WeChat channel instance
    MEDIA-ID: Media ID to download

  Returns:
    Binary content or file path"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/media/get?access_token=~A&media_id=~A"
                      (wechat-api-base channel) token media-id)))
    (dexador:get url)))

;;; ============================================================================
;;; User Management
;;; ============================================================================

(defun wechat-get-user-info (channel user-id &key lang)
  "Get user information.

  Args:
    CHANNEL: WeChat channel instance
    USER-ID: User's WeChat openid
    LANG: Language (zh_CN, en, etc.)

  Returns:
    User info plist"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/user/info?access_token=~A&openid=~A~@[&lang=~A~]"
                      (wechat-api-base channel) token user-id lang))
         (response (dexador:get url))
         (data (parse-json response)))

    (if (getf data :subscribe)
        data
        (progn
          (log-error "WeChat get user info failed: ~A" data)
          nil))))

(defun wechat-get-user-list (channel &key next-openid)
  "Get user list.

  Args:
    CHANNEL: WeChat channel instance
    NEXT-OPENID: Optional next openid for pagination

  Returns:
    User list plist"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/user/get?access_token=~A~@[&next_openid=~A~]"
                      (wechat-api-base channel) token next-openid))
         (response (dexador:get url))
         (data (parse-json response)))

    (if (getf data :total)
        data
        (progn
          (log-error "WeChat get user list failed: ~A" data)
          nil))))

;;; ============================================================================
;;; Menu Management
;;; ============================================================================

(defun wechat-create-menu (channel menu)
  "Create custom menu.

  Args:
    CHANNEL: WeChat channel instance
    MENU: Menu structure (plist)

  Returns:
    T on success"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/menu/create?access_token=~A"
                      (wechat-api-base channel) token))
         (body (json-to-string (list :button menu)))
         (response (dexador:post url :content body))
         (data (parse-json response)))

    (if (or (getf data :errmsg) (equal (getf data :errcode) 0))
        (progn
          (log-info "WeChat menu created")
          t)
        (progn
          (log-error "WeChat menu creation failed: ~A" data)
          nil))))

(defun wechat-delete-menu (channel)
  "Delete custom menu.

  Args:
    CHANNEL: WeChat channel instance

  Returns:
    T on success"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/menu/delete?access_token=~A"
                      (wechat-api-base channel) token))
         (response (dexador:post url))
         (data (parse-json response)))

    (if (or (getf data :errmsg) (equal (getf data :errcode) 0))
        (progn
          (log-info "WeChat menu deleted")
          t)
        (progn
          (log-error "WeChat menu deletion failed: ~A" data)
          nil))))

(defun wechat-get-menu (channel)
  "Get custom menu.

  Args:
    CHANNEL: WeChat channel instance

  Returns:
    Menu structure or NIL"
  (let* ((token (wechat-get-access-token channel))
         (url (format nil "~A/menu/get?access_token=~A"
                      (wechat-api-base channel) token))
         (response (dexador:get url))
         (data (parse-json response)))

    (if (getf data :menu)
        (getf data :menu)
        nil)))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-wechat-channel (&key app-id app-secret token aes-key)
  "Initialize WeChat channel.

  Args:
    APP-ID: WeChat AppID
    APP-SECRET: WeChat AppSecret
    TOKEN: Verification token
    AES-KEY: Encoding AES key

  Returns:
    WeChat channel instance"
  (let ((channel (make-wechat-channel app-id app-secret token :aes-key aes-key)))
    ;; Get initial access token
    (wechat-refresh-access-token channel)
    (log-info "WeChat channel initialized: ~A" app-id)
    channel))
