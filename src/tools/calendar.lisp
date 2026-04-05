;;; tools/calendar.lisp --- Calendar Tool for Lisp-Claw
;;;
;;; This file implements calendar integration supporting:
;;; - Google Calendar API
;;; - Outlook Calendar API
;;; - Local calendar operations
;;; - Event CRUD operations
;;; - Event search and filtering

(defpackage #:lisp-claw.tools.calendar
  (:nicknames #:lc.tools.calendar)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.tools.registry
        #:dexador
        #:json-mop
        #:local-time
        #:uuid)
  (:export
   ;; Calendar client classes
   #:calendar-client
   #:google-calendar-client
   #:outlook-calendar-client
   #:local-calendar-client
   ;; Calendar operations
   #:make-calendar-client
   #:list-calendars
   #:get-calendar-events
   #:create-calendar-event
   #:update-calendar-event
   #:delete-calendar-event
   #:accept-event
   #:decline-event
   ;; Search operations
   #:search-events
   #:get-upcoming-events
   #:get-events-for-day
   #:get-events-for-week
   #:get-events-for-month
   ;; Initialization
   #:initialize-calendar-tools))

(in-package #:lisp-claw.tools.calendar)

;;; ============================================================================
;;; Calendar Client Class
;;; ============================================================================

(defclass calendar-client ()
  ((provider :initarg :provider
             :reader calendar-provider
             :documentation "Calendar provider: google, outlook, local")
   (access-token :initarg :access-token
                 :initform nil
                 :accessor calendar-access-token
                 :documentation "OAuth access token")
   (refresh-token :initarg :refresh-token
                  :initform nil
                  :accessor calendar-refresh-token
                  :documentation "OAuth refresh token")
   (token-expires :initform nil
                  :accessor calendar-token-expires
                  :documentation "Token expiration time")
   (client-id :initarg :client-id
              :reader calendar-client-id
              :documentation "OAuth client ID")
   (client-secret :initarg :client-secret
                  :reader calendar-client-secret
                  :documentation "OAuth client secret")
   (calendar-id :initarg :calendar-id
                :initform "primary"
                :reader calendar-id
                :documentation "Default calendar ID"))
  (:documentation "Base calendar client"))

(defmethod print-object ((client calendar-client) stream)
  (print-unreadable-object (client stream :type t)
    (format stream "~A" (calendar-provider client))))

;;; ============================================================================
;;; Google Calendar Client
;;; ============================================================================

(defclass google-calendar-client (calendar-client)
  ((api-endpoint :initform "https://www.googleapis.com/calendar/v3"
                 :reader google-api-endpoint
                 :documentation "Google Calendar API endpoint"))
  (:documentation "Google Calendar API client"))

(defun make-google-calendar-client (&key client-id client-secret access-token refresh-token calendar-id)
  "Create a Google Calendar client.

  Args:
    CLIENT-ID: OAuth client ID
    CLIENT-SECRET: OAuth client secret
    ACCESS-TOKEN: OAuth access token (optional)
    REFRESH-TOKEN: OAuth refresh token (optional)
    CALENDAR-ID: Default calendar ID (default: \"primary\")

  Returns:
    Google calendar client instance"
  (make-instance 'google-calendar-client
                 :provider :google
                 :client-id client-id
                 :client-secret client-secret
                 :access-token access-token
                 :refresh-token refresh-token
                 :calendar-id (or calendar-id "primary")))

(defun google-refresh-token (client)
  "Refresh Google OAuth token.

  Args:
    CLIENT: Google calendar client

  Returns:
    New access token or NIL"
  (handler-case
      (let* ((url "https://oauth2.googleapis.com/token")
             (params (list (cons "client_id" (calendar-client-id client))
                           (cons "client_secret" (calendar-client-secret client))
                           (cons "refresh_token" (calendar-refresh-token client))
                           (cons "grant_type" "refresh_token")
                           (cons "scope" "https://www.googleapis.com/auth/calendar"))))
        (let* ((response (dex:post url :content params))
               (json (json:decode-json-from-string response)))
          (when (gethash "access_token" json)
            (setf (calendar-access-token client) (gethash "access_token" json))
            (setf (calendar-token-expires client)
                  (+ (get-universal-time) (gethash "expires_in" json 3600)))
            (log-info "Google Calendar token refreshed")
            (calendar-access-token client))))
    (error (e)
      (log-error "Failed to refresh Google Calendar token: ~A" e)
      nil)))

(defun google-auth-header (client)
  "Get Google Calendar authorization header.

  Args:
    CLIENT: Google calendar client

  Returns:
    Authorization header string"
  (let ((token (calendar-access-token client)))
    (when (or (null token)
              (and (calendar-token-expires client)
                   (>= (get-universal-time) (calendar-token-expires client))))
      (if (calendar-refresh-token client)
          (google-refresh-token client)
          (error "Google Calendar: No valid token and no refresh token")))
    (format nil "Bearer ~A" token)))

;;; ============================================================================
;;; Outlook Calendar Client
;;; ============================================================================

(defclass outlook-calendar-client (calendar-client)
  ((api-endpoint :initform "https://graph.microsoft.com/v1.0"
                 :reader outlook-api-endpoint
                 :documentation "Microsoft Graph API endpoint"))
  (:documentation "Outlook/Office 365 Calendar API client"))

(defun make-outlook-calendar-client (&key client-id client-secret access-token refresh-token calendar-id)
  "Create an Outlook Calendar client.

  Args:
    CLIENT-ID: Azure AD application ID
    CLIENT-SECRET: Azure AD client secret
    ACCESS-TOKEN: OAuth access token (optional)
    REFRESH-TOKEN: OAuth refresh token (optional)
    CALENDAR-ID: Default calendar ID (optional)

  Returns:
    Outlook calendar client instance"
  (make-instance 'outlook-calendar-client
                 :provider :outlook
                 :client-id client-id
                 :client-secret client-secret
                 :access-token access-token
                 :refresh-token refresh-token
                 :calendar-id (or calendar-id "calendar")))

(defun outlook-refresh-token (client)
  "Refresh Outlook OAuth token.

  Args:
    CLIENT: Outlook calendar client

  Returns:
    New access token or NIL"
  (handler-case
      (let* ((url "https://login.microsoftonline.com/common/oauth2/v2.0/token")
             (params (list (cons "client_id" (calendar-client-id client))
                           (cons "client_secret" (calendar-client-secret client))
                           (cons "refresh_token" (calendar-refresh-token client))
                           (cons "grant_type" "refresh_token")
                           (cons "scope" "https://graph.microsoft.com/Calendars.ReadWrite"))))
        (let* ((response (dex:post url :content params))
               (json (json:decode-json-from-string response)))
          (when (gethash "access_token" json)
            (setf (calendar-access-token client) (gethash "access_token" json))
            (setf (calendar-token-expires client)
                  (+ (get-universal-time) (gethash "expires_in" json 3600)))
            (log-info "Outlook Calendar token refreshed")
            (calendar-access-token client))))
    (error (e)
      (log-error "Failed to refresh Outlook Calendar token: ~A" e)
      nil)))

(defun outlook-auth-header (client)
  "Get Outlook Calendar authorization header.

  Args:
    CLIENT: Outlook calendar client

  Returns:
    Authorization header string"
  (let ((token (calendar-access-token client)))
    (when (or (null token)
              (and (calendar-token-expires client)
                   (>= (get-universal-time) (calendar-token-expires client))))
      (if (calendar-refresh-token client)
          (outlook-refresh-token client)
          (error "Outlook Calendar: No valid token and no refresh token")))
    (format nil "Bearer ~A" token)))

;;; ============================================================================
;;; Local Calendar Client
;;; ============================================================================

(defclass local-calendar-client (calendar-client)
  ((events-file :initform nil
                :accessor local-events-file
                :documentation "Path to events storage file")
   (events-store :initform (make-hash-table :test 'equal)
                 :accessor local-events-store
                 :documentation "Local events storage"))
  (:documentation "Local file-based calendar client"))

(defvar *local-calendar-store* (make-hash-table :test 'equal)
  "Global local calendar store.")

(defun make-local-calendar-client (&key calendar-id)
  "Create a local calendar client.

  Args:
    CALENDAR-ID: Calendar identifier (default: \"default\")

  Returns:
    Local calendar client instance"
  (make-instance 'local-calendar-client
                 :provider :local
                 :calendar-id (or calendar-id "default")))

;;; ============================================================================
;;; Factory Function
;;; ============================================================================

(defun make-calendar-client (provider &key client-id client-secret access-token refresh-token calendar-id)
  "Create a calendar client for the specified provider.

  Args:
    PROVIDER: Calendar provider (:google, :outlook, :local)
    CLIENT-ID: OAuth client ID
    CLIENT-SECRET: OAuth client secret
    ACCESS-TOKEN: OAuth access token
    REFRESH-TOKEN: OAuth refresh token
    CALENDAR-ID: Default calendar ID

  Returns:
    Calendar client instance"
  (ecase provider
    (:google (make-google-calendar-client
              :client-id client-id
              :client-secret client-secret
              :access-token access-token
              :refresh-token refresh-token
              :calendar-id calendar-id))
    (:outlook (make-outlook-calendar-client
               :client-id client-id
               :client-secret client-secret
               :access-token access-token
               :refresh-token refresh-token
               :calendar-id calendar-id))
    (:local (make-local-calendar-client :calendar-id calendar-id))))

;;; ============================================================================
;;; Calendar Operations - Google
;;; ============================================================================

(defun google-list-calendars (client)
  "List Google calendars.

  Args:
    CLIENT: Google calendar client

  Returns:
    List of calendar objects"
  (let* ((url (format nil "~A/users/me/calendarList" (google-api-endpoint client)))
         (headers (list (cons "Authorization" (google-auth-header client))))
         (response (dex:get url :headers headers)))
    (let ((json (json:decode-json-from-string response)))
      (let ((calendars nil))
        (dolist (item (gethash "items" json nil))
          (push (list :id (gethash "id" item)
                      :summary (gethash "summary" item)
                      :primary (gethash "primary" item))
                calendars))
        calendars))))

(defun google-get-events (client &key calendar-id time-min time-max max-results)
  "Get Google Calendar events.

  Args:
    CLIENT: Google calendar client
    CALENDAR-ID: Calendar ID (default: primary)
    TIME-MIN: Start time (ISO 8601 string)
    TIME-MAX: End time (ISO 8601 string)
    MAX-RESULTS: Max events to return

  Returns:
    List of event objects"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (url (format nil "~A/calendars/~A/events"
                      (google-api-endpoint client)
                      (url-encode cal-id)))
         (params nil))
    (when time-min
      (push (cons "timeMin" time-min) params))
    (when time-max
      (push (cons "timeMax" time-max) params))
    (when max-results
      (push (cons "maxResults" (write-to-string max-results)) params))
    (let* ((headers (list (cons "Authorization" (google-auth-header client))))
           (response (dex:get url :headers headers :query params))
           (json (json:decode-json-from-string response)))
      (let ((events nil))
        (dolist (item (gethash "items" json nil))
          (push (parse-google-event item) events))
        events))))

(defun parse-google-event (json)
  "Parse Google Calendar event JSON.

  Args:
    JSON: Event JSON object

  Returns:
    Event plist"
  (list :id (gethash "id" json)
        :summary (gethash "summary" json)
        :description (gethash "description" json)
        :location (gethash "location" json)
        :start (gethash "start" json)
        :end (gethash "end" json)
        :attendees (gethash "attendees" json)
        :organizer (gethash "organizer" json)
        :status (gethash "status" json)
        :html-link (gethash "htmlLink" json)
        :created (gethash "created" json)
        :updated (gethash "updated" json)))

(defun google-create-event (client event &key calendar-id)
  "Create a Google Calendar event.

  Args:
    CLIENT: Google calendar client
    EVENT: Event plist (:summary, :description, :start, :end, :attendees, etc.)
    CALENDAR-ID: Calendar ID (default: primary)

  Returns:
    Created event plist"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (url (format nil "~A/calendars/~A/events"
                      (google-api-endpoint client)
                      (url-encode cal-id)))
         (headers (list (cons "Authorization" (google-auth-header client))
                        (cons "Content-Type" "application/json")))
         (body (build-google-event event))
         (response (dex:post url
                             :headers headers
                             :content (json:encode-json-to-string body))))
    (parse-google-event (json:decode-json-from-string response))))

(defun build-google-event (event)
  "Build Google Calendar event JSON.

  Args:
    EVENT: Event plist

  Returns:
    JSON object for Google Calendar API"
  (let ((json (make-hash-table :test 'equal)))
    (when (getf event :summary)
      (setf (gethash "summary" json) (getf event :summary)))
    (when (getf event :description)
      (setf (gethash "description" json) (getf event :description)))
    (when (getf event :location)
      (setf (gethash "location" json) (getf event :location)))
    (when (getf event :start)
      (setf (gethash "start" json) (getf event :start)))
    (when (getf event :end)
      (setf (gethash "end" json) (getf event :end)))
    (when (getf event :attendees)
      (setf (gethash "attendees" json)
            (mapcar (lambda (a) (list (cons "email" a))) (getf event :attendees))))
    json))

(defun google-update-event (client event-id updates &key calendar-id)
  "Update a Google Calendar event.

  Args:
    CLIENT: Google calendar client
    EVENT-ID: Event ID to update
    UPDATES: Update plist
    CALENDAR-ID: Calendar ID

  Returns:
    Updated event plist"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (url (format nil "~A/calendars/~A/events/~A"
                      (google-api-endpoint client)
                      (url-encode cal-id)
                      (url-encode event-id)))
         (headers (list (cons "Authorization" (google-auth-header client))
                        (cons "Content-Type" "application/json")))
         (body (build-google-event updates))
         (response (dex:patch url
                              :headers headers
                              :content (json:encode-json-to-string body))))
    (parse-google-event (json:decode-json-from-string response))))

(defun google-delete-event (client event-id &key calendar-id)
  "Delete a Google Calendar event.

  Args:
    CLIENT: Google calendar client
    EVENT-ID: Event ID to delete
    CALENDAR-ID: Calendar ID

  Returns:
    T on success"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (url (format nil "~A/calendars/~A/events/~A"
                      (google-api-endpoint client)
                      (url-encode cal-id)
                      (url-encode event-id)))
         (headers (list (cons "Authorization" (google-auth-header client)))))
    (dex:delete url :headers headers)
    t))

(defun google-accept-event (client event-id &key calendar-id attendee-email)
  "Accept a Google Calendar event invitation.

  Args:
    CLIENT: Google calendar client
    EVENT-ID: Event ID
    CALENDAR-ID: Calendar ID
    ATTENDEE-EMAIL: Attendee email

  Returns:
    T on success"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (url (format nil "~A/calendars/~A/events/~A/accept"
                      (google-api-endpoint client)
                      (url-encode cal-id)
                      (url-encode event-id)))
         (headers (list (cons "Authorization" (google-auth-header client)))))
    (dex:post url :headers headers :content "")
    t))

(defun google-decline-event (client event-id &key calendar-id attendee-email)
  "Decline a Google Calendar event invitation.

  Args:
    CLIENT: Google calendar client
    EVENT-ID: Event ID
    CALENDAR-ID: Calendar ID
    ATTENDEE-EMAIL: Attendee email

  Returns:
    T on success"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (url (format nil "~A/calendars/~A/events/~A/decline"
                      (google-api-endpoint client)
                      (url-encode cal-id)
                      (url-encode event-id)))
         (headers (list (cons "Authorization" (google-auth-header client)))))
    (dex:post url :headers headers :content "")
    t))

;;; ============================================================================
;;; Calendar Operations - Outlook
;;; ============================================================================

(defun outlook-list-calendars (client)
  "List Outlook calendars.

  Args:
    CLIENT: Outlook calendar client

  Returns:
    List of calendar objects"
  (let* ((url (format nil "~A/me/calendars" (outlook-api-endpoint client)))
         (headers (list (cons "Authorization" (outlook-auth-header client))))
         (response (dex:get url :headers headers)))
    (let ((json (json:decode-json-from-string response)))
      (let ((calendars nil))
        (dolist (item (gethash "value" json nil))
          (push (list :id (gethash "id" item)
                      :name (gethash "name" item)
                      :owner (gethash "owner" item))
                calendars))
        calendars))))

(defun outlook-get-events (client &key calendar-id time-min time-max max-results)
  "Get Outlook Calendar events.

  Args:
    CLIENT: Outlook calendar client
    CALENDAR-ID: Calendar ID
    TIME-MIN: Start time
    TIME-MAX: End time
    MAX-RESULTS: Max events

  Returns:
    List of event objects"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (url (format nil "~A/me/calendars/~A/events"
                      (outlook-api-endpoint client)
                      cal-id))
         (headers (list (cons "Authorization" (outlook-auth-header client))))
         (response (dex:get url :headers headers))
         (json (json:decode-json-from-string response)))
    (let ((events nil))
      (dolist (item (gethash "value" json nil))
        (push (parse-outlook-event item) events))
      events)))

(defun parse-outlook-event (json)
  "Parse Outlook Calendar event JSON.

  Args:
    JSON: Event JSON object

  Returns:
    Event plist"
  (list :id (gethash "id" json)
        :subject (gethash "subject" json)
        :body (gethash "body" json)
        :location (gethash "location" json)
        :start (gethash "start" json)
        :end (gethash "end" json)
        :attendees (gethash "attendees" json)
        :organizer (gethash "organizer" json)
        :show-as (gethash "showAs" json)
        :web-link (gethash "webLink" json)))

(defun outlook-create-event (client event &key calendar-id)
  "Create an Outlook Calendar event.

  Args:
    CLIENT: Outlook calendar client
    EVENT: Event plist
    CALENDAR-ID: Calendar ID

  Returns:
    Created event plist"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (url (format nil "~A/me/calendars/~A/events"
                      (outlook-api-endpoint client)
                      cal-id))
         (headers (list (cons "Authorization" (outlook-auth-header client))
                        (cons "Content-Type" "application/json")))
         (body (build-outlook-event event))
         (response (dex:post url
                             :headers headers
                             :content (json:encode-json-to-string body))))
    (parse-outlook-event (json:decode-json-from-string response))))

(defun build-outlook-event (event)
  "Build Outlook Calendar event JSON.

  Args:
    EVENT: Event plist

  Returns:
    JSON object for Outlook Calendar API"
  (let ((json (make-hash-table :test 'equal)))
    (when (getf event :subject)
      (setf (gethash "subject" json) (getf event :subject)))
    (when (getf event :body)
      (setf (gethash "body" json) (list (cons "contentType" "HTML")
                                         (cons "content" (getf event :body)))))
    (when (getf event :location)
      (setf (gethash "location" json) (list (cons "displayName" (getf event :location)))))
    (when (getf event :start)
      (setf (gethash "start" json) (list (cons "dateTime" (getf event :start))
                                          (cons "timeZone" "UTC"))))
    (when (getf event :end)
      (setf (gethash "end" json) (list (cons "dateTime" (getf event :end))
                                        (cons "timeZone" "UTC"))))
    json))

;;; ============================================================================
;;; Calendar Operations - Local
;;; ============================================================================

(defun local-list-calendars (client)
  "List local calendars.

  Args:
    CLIENT: Local calendar client

  Returns:
    List of calendar IDs"
  (list (list :id (calendar-id client)
              :name (calendar-id client)
              :type :local)))

(defun local-get-events (client &key calendar-id time-min time-max)
  "Get local calendar events.

  Args:
    CLIENT: Local calendar client
    CALENDAR-ID: Calendar ID
    TIME-MIN: Start time
    TIME-MAX: End time

  Returns:
    List of event objects"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (events (gethash cal-id (local-events-store client) nil)))
    (remove-if (lambda (e)
                 (or (and time-min
                          (string< (getf e :end) time-min))
                     (and time-max
                          (string> (getf e :start) time-max))))
               events)))

(defun local-create-event (client event &key calendar-id)
  "Create a local calendar event.

  Args:
    CLIENT: Local calendar client
    EVENT: Event plist
    CALENDAR-ID: Calendar ID

  Returns:
    Created event plist"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (event-id (uuid:make-uuid-string))
         (new-event (list* :id event-id
                           :created (get-universal-time)
                           event)))
    (let ((events (gethash cal-id (local-events-store client) nil)))
      (setf (gethash cal-id (local-events-store client))
            (cons new-event events)))
    new-event))

(defun local-update-event (client event-id updates &key calendar-id)
  "Update a local calendar event.

  Args:
    CLIENT: Local calendar client
    EVENT-ID: Event ID
    UPDATES: Update plist
    CALENDAR-ID: Calendar ID

  Returns:
    Updated event plist or NIL"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (events (gethash cal-id (local-events-store client) nil)))
    (dolist (event events)
      (when (string= (getf event :id) event-id)
        (loop for (key value) on updates by #'cddr
              do (setf (getf event key) value))
        (return-from local-update-event event)))))

(defun local-delete-event (client event-id &key calendar-id)
  "Delete a local calendar event.

  Args:
    CLIENT: Local calendar client
    EVENT-ID: Event ID
    CALENDAR-ID: Calendar ID

  Returns:
    T on success"
  (let* ((cal-id (or calendar-id (calendar-id client)))
         (events (gethash cal-id (local-events-store client) nil)))
    (setf (gethash cal-id (local-events-store client))
          (remove-if (lambda (e) (string= (getf e :id) event-id)) events))
    t))

(defun local-accept-event (client event-id &key calendar-id)
  "Accept a local calendar event.

  Args:
    CLIENT: Local calendar client
    EVENT-ID: Event ID
    CALENDAR-ID: Calendar ID

  Returns:
    T on success"
  (local-update-event client event-id '(:status "accepted") :calendar-id calendar-id))

(defun local-decline-event (client event-id &key calendar-id)
  "Decline a local calendar event.

  Args:
    CLIENT: Local calendar client
    EVENT-ID: Event ID
    CALENDAR-ID: Calendar ID

  Returns:
    T on success"
  (local-update-event client event-id '(:status "declined") :calendar-id calendar-id))

;;; ============================================================================
;;; Unified API
;;; ============================================================================

(defun list-calendars (client)
  "List available calendars.

  Args:
    CLIENT: Calendar client

  Returns:
    List of calendars"
  (etypecase client
    (google-calendar-client (google-list-calendars client))
    (outlook-calendar-client (outlook-list-calendars client))
    (local-calendar-client (local-list-calendars client))))

(defun get-calendar-events (client &key calendar-id time-min time-max max-results)
  "Get calendar events.

  Args:
    CLIENT: Calendar client
    CALENDAR-ID: Calendar ID
    TIME-MIN: Start time (ISO 8601)
    TIME-MAX: End time (ISO 8601)
    MAX-RESULTS: Max events to return

  Returns:
    List of events"
  (etypecase client
    (google-calendar-client (google-get-events client
                                               :calendar-id calendar-id
                                               :time-min time-min
                                               :time-max time-max
                                               :max-results max-results))
    (outlook-calendar-client (outlook-get-events client
                                                  :calendar-id calendar-id
                                                  :time-min time-min
                                                  :time-max time-max))
    (local-calendar-client (local-get-events client
                                              :calendar-id calendar-id
                                              :time-min time-min
                                              :time-max time-max))))

(defun create-calendar-event (client event &key calendar-id)
  "Create a calendar event.

  Args:
    CLIENT: Calendar client
    EVENT: Event plist (:summary, :description, :start, :end, :attendees, etc.)
    CALENDAR-ID: Calendar ID

  Returns:
    Created event"
  (etypecase client
    (google-calendar-client (google-create-event client event :calendar-id calendar-id))
    (outlook-calendar-client (outlook-create-event client event :calendar-id calendar-id))
    (local-calendar-client (local-create-event client event :calendar-id calendar-id))))

(defun update-calendar-event (client event-id updates &key calendar-id)
  "Update a calendar event.

  Args:
    CLIENT: Calendar client
    EVENT-ID: Event ID
    UPDATES: Update plist
    CALENDAR-ID: Calendar ID

  Returns:
    Updated event"
  (etypecase client
    (google-calendar-client (google-update-event client event-id updates :calendar-id calendar-id))
    (outlook-calendar-client (error "Outlook update not yet implemented"))
    (local-calendar-client (local-update-event client event-id updates :calendar-id calendar-id))))

(defun delete-calendar-event (client event-id &key calendar-id)
  "Delete a calendar event.

  Args:
    CLIENT: Calendar client
    EVENT-ID: Event ID
    CALENDAR-ID: Calendar ID

  Returns:
    T on success"
  (etypecase client
    (google-calendar-client (google-delete-event client event-id :calendar-id calendar-id))
    (outlook-calendar-client (error "Outlook delete not yet implemented"))
    (local-calendar-client (local-delete-event client event-id :calendar-id calendar-id))))

(defun accept-event (client event-id &key calendar-id attendee-email)
  "Accept a calendar event invitation.

  Args:
    CLIENT: Calendar client
    EVENT-ID: Event ID
    CALENDAR-ID: Calendar ID
    ATTENDEE-EMAIL: Attendee email

  Returns:
    T on success"
  (etypecase client
    (google-calendar-client (google-accept-event client event-id
                                                  :calendar-id calendar-id
                                                  :attendee-email attendee-email))
    (outlook-calendar-client (error "Outlook accept not yet implemented"))
    (local-calendar-client (local-accept-event client event-id :calendar-id calendar-id))))

(defun decline-event (client event-id &key calendar-id attendee-email)
  "Decline a calendar event invitation.

  Args:
    CLIENT: Calendar client
    EVENT-ID: Event ID
    CALENDAR-ID: Calendar ID
    ATTENDEE-EMAIL: Attendee email

  Returns:
    T on success"
  (etypecase client
    (google-calendar-client (google-decline-event client event-id
                                                   :calendar-id calendar-id
                                                   :attendee-email attendee-email))
    (outlook-calendar-client (error "Outlook decline not yet implemented"))
    (local-calendar-client (local-decline-event client event-id :calendar-id calendar-id))))

;;; ============================================================================
;;; Search and Utility Functions
;;; ============================================================================

(defun search-events (events query &key calendar-id)
  "Search events by keyword.

  Args:
    EVENTS: List of events to search
    QUERY: Search query string
    CALENDAR-ID: Filter by calendar (optional)

  Returns:
    Matching events"
  (let ((query-lower (string-downcase query)))
    (remove-if-not (lambda (event)
                     (or (and (getf event :summary)
                              (search query-lower (string-downcase (getf event :summary))))
                         (and (getf event :description)
                              (search query-lower (string-downcase (getf event :description))))
                         (and (getf event :location)
                              (search query-lower (string-downcase (getf event :location))))))
                   events)))

(defun get-upcoming-events (client &key hours limit)
  "Get upcoming events.

  Args:
    CLIENT: Calendar client
    HOURS: Hours to look ahead (default: 24)
    LIMIT: Max events (default: 10)

  Returns:
    List of upcoming events"
  (let* ((now (get-universal-time))
         (time-min (format-time-string "~Y-~M-~DT~h:~m:~sZ" now))
         (time-max (format-time-string "~Y-~M-~DT~h:~m:~sZ"
                                        (+ now (* (or hours 24) 3600)))))
    (let ((events (get-calendar-events client :time-min time-min :time-max time-max)))
      (subseq (sort events (lambda (a b)
                             (string< (getf a :start) (getf b :start))))
              0 (min (length events) (or limit 10))))))

(defun get-events-for-day (client date &key calendar-id)
  "Get events for a specific day.

  Args:
    CLIENT: Calendar client
    DATE: Date (Universal Time)
    CALENDAR-ID: Calendar ID

  Returns:
    List of events"
  (let* ((day-start (encode-time 0 0 0 (day date) (month date) (year date)))
         (day-end (encode-time 23 59 59 (day date) (month date) (year date)))
         (time-min (format-time-string "~Y-~M-~DT00:00:00Z" day-start))
         (time-max (format-time-string "~Y-~M-~DT23:59:59Z" day-end)))
    (get-calendar-events client :calendar-id calendar-id
                              :time-min time-min
                              :time-max time-max)))

(defun get-events-for-week (client &key calendar-id)
  "Get events for the current week.

  Args:
    CLIENT: Calendar client
    CALENDAR-ID: Calendar ID

  Returns:
    List of events"
  (let* ((now (get-universal-time))
         (day-of-week (day-of-week now))
         (week-start (- now (* day-of-week 86400)))
         (week-end (+ week-start (* 6 86400))))
    (get-calendar-events client :calendar-id calendar-id
                              :time-min (format-time-string "~Y-~M-~DT00:00:00Z" week-start)
                              :time-max (format-time-string "~Y-~M-~DT23:59:59Z" week-end))))

(defun get-events-for-month (client &key calendar-id)
  "Get events for the current month.

  Args:
    CLIENT: Calendar client
    CALENDAR-ID: Calendar ID

  Returns:
    List of events"
  (let* ((now (get-universal-time))
         (month-start (encode-time 0 0 0 1 (month now) (year now)))
         (next-month (if (= (month now) 12)
                         (encode-time 0 0 0 1 1 (1+ (year now)))
                         (encode-time 0 0 0 1 (1+ (month now)) (year now))))
         (month-end (decode-universal-time next-month)))
    (get-calendar-events client :calendar-id calendar-id
                              :time-min (format-time-string "~Y-~M-~DT00:00:00Z" month-start)
                              :time-max (format-time-string "~Y-~M-~DT23:59:59Z" month-end))))

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defun register-calendar-tools ()
  "Register calendar tools with the tool registry.

  Returns:
    T on success"
  ;; Register list_calendars tool
  (register-tool 'list_calendars
                 :description "List available calendars"
                 :parameters '((:name "provider" :type "string" :description "Calendar provider"))
                 :handler (lambda (args)
                            (let* ((provider (keywordize (cdr (assoc "provider" args :test 'string=))))
                                   (client (make-calendar-client (or provider :local))))
                              (list-calendars client)))))
  t)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-calendar-tools ()
  "Initialize the calendar tools system.

  Returns:
    T on success"
  (log-info "Calendar tools system initialized")
  (register-calendar-tools)
  t)
