;;; tools/http-client.lisp --- HTTP Client for REST API Calls
;;;
;;; This file provides HTTP client functionality for making REST API calls.
;;; Built on top of Dexador for HTTP requests.

(defpackage #:lisp-claw.tools.http-client
  (:nicknames #:lc.tools.http-client)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; HTTP client class
   #:http-client
   #:make-http-client
   #:http-client-get
   #:http-client-post
   #:http-client-put
   #:http-client-patch
   #:http-client-delete
   #:http-client-head
   ;; Request options
   #:http-request
   #:http-request-get
   #:http-request-post
   #:http-request-put
   #:http-request-patch
   #:http-request-delete
   ;; Response handling
   #:http-response
   #:http-response-status
   #:http-response-headers
   #:http-response-body
   #:http-response-json
   ;; Convenience functions
   #:http-get
   #:http-post
   #:http-put
   #:http-patch
   #:http-delete
   ;; Session management
   #:http-session
   #:make-http-session
   #:session-request
   ;; Utilities
   #:url-encode
   #:url-decode
   #:parse-url
   #:build-query-string))

(in-package #:lisp-claw.tools.http-client)

;;; ============================================================================
;;; HTTP Response Class
;;; ============================================================================

(defclass http-response ()
  ((status :initarg :status
           :reader http-response-status
           :documentation "HTTP status code")
   (headers :initarg :headers
            :reader http-response-headers
            :documentation "Response headers (hash table)")
   (body :initarg :body
         :reader http-response-body
         :documentation "Response body (string)")
   (url :initarg :url
        :reader http-response-url
        :documentation "Final URL (after redirects)")
   (elapsed :initarg :elapsed
            :reader http-response-elapsed
            :documentation "Request time in seconds"))
  (:documentation "HTTP response"))

(defmethod print-object ((response http-response) stream)
  (print-unreadable-object (response stream :type t)
    (format stream "~A ~A"
            (http-response-status response)
            (http-response-url response))))

(defun make-http-response (status headers body &key url elapsed)
  "Create an HTTP response instance.

  Args:
    STATUS: HTTP status code
    HEADERS: Response headers
    BODY: Response body
    URL: Final URL (optional)
    ELAPSED: Request time in seconds (optional)

  Returns:
    HTTP response instance"
  (make-instance 'http-response
                 :status status
                 :headers headers
                 :body body
                 :url (or url "unknown")
                 :elapsed (or elapsed 0)))

(defun http-response-json (response)
  "Parse response body as JSON.

  Args:
    RESPONSE: HTTP response instance

  Returns:
    Parsed JSON object or NIL"
  (let ((body (http-response-body response)))
    (when (and body (plusp (length body)))
      (handler-case
          (parse-json body)
        (error (e)
          (log-warning "Failed to parse JSON response: ~A" e)
          nil)))))

;;; ============================================================================
;;; HTTP Client Class
;;; ============================================================================

(defclass http-client ()
  ((default-headers :initarg :default-headers
                    :accessor http-client-default-headers
                    :documentation "Default headers for all requests")
   (timeout :initarg :timeout
            :initform 30
            :accessor http-client-timeout
            :documentation "Request timeout in seconds")
   (max-redirects :initarg :max-redirects
                  :initform 5
                  :accessor http-client-max-redirects
                  :documentation "Maximum redirects to follow")
   (verify-ssl :initarg :verify-ssl
               :initform t
               :accessor http-client-verify-ssl
               :documentation "Verify SSL certificates")
   (cookies :initarg :cookies
            :initform (make-hash-table :test 'equal)
            :accessor http-client-cookies
            :documentation "Cookie jar"))
  (:documentation "HTTP client for REST API calls"))

(defmethod print-object ((client http-client) stream)
  (print-unreadable-object (client stream :type t)
    (format stream "timeout=~As" (http-client-timeout client))))

(defun make-http-client (&key default-headers timeout max-redirects verify-ssl)
  "Create an HTTP client.

  Args:
    DEFAULT-HEADERS: Default headers for all requests
    TIMEOUT: Request timeout in seconds (default: 30)
    MAX-REDIRECTS: Maximum redirects (default: 5)
    VERIFY-SSL: Verify SSL certificates (default: T)

  Returns:
    HTTP client instance"
  (make-instance 'http-client
                 :default-headers (or default-headers
                                      (list (cons "User-Agent" "Lisp-Claw/0.1")))
                 :timeout (or timeout 30)
                 :max-redirects (or max-redirects 5)
                 :verify-ssl (if (null verify-ssl) nil t)))

;;; ============================================================================
;;; URL Utilities
;;; ============================================================================

(defun url-encode (string)
  "URL encode a string.

  Args:
    STRING: String to encode

  Returns:
    URL encoded string"
  (flet ((encode-char (c)
           (let ((code (char-code c)))
             (if (or (char<= #\a c #\z)
                     (char<= #\A c #\Z)
                     (char<= #\0 c #\9)
                     (find c "-_.~"))
                 (string c)
                 (format nil "%~2,'0X" code)))))
    (map 'string #'encode-char string)))

(defun url-decode (string)
  "URL decode a string.

  Args:
    STRING: String to decode

  Returns:
    URL decoded string"
  (with-output-to-string (out)
    (let ((i 0)
          (len (length string)))
      (loop while (< i len)
            do (let ((c (char string i)))
                 (cond
                   ((char= c #\%)
                    (when (<= (+ i 2) len)
                      (let ((hex (subseq string (1+ i) (+ i 3))))
                        (write-char (code-char (parse-integer hex :radix 16)) out)
                        (incf i 3))))
                   ((char= c #\+)
                    (write-char #\Space out)
                    (incf i))
                   (t
                    (write-char c out)
                    (incf i)))))))))

(defun parse-url (url)
  "Parse a URL into components.

  Args:
    URL: URL string

  Returns:
    Plist with :scheme, :host, :port, :path, :query, :fragment"
  (let ((scheme-end (search "://" url))
        (host-start 0)
        (host-end nil)
        (port nil)
        (path-start nil)
        (query-start nil)
        (fragment-start nil))

    ;; Parse scheme
    (let ((scheme (if scheme-end
                      (subseq url 0 scheme-end)
                      "http")))
      (when scheme-end
        (setf host-start (+ scheme-end 3))))

    ;; Find path start
    (let ((slash-pos (position #\/ url :start host-start)))
      (if slash-pos
          (setf path-start slash-pos)
          (setf path-start (length url))))

    ;; Find port
    (let ((colon-pos (position #\: url :start host-start :end path-start)))
      (when colon-pos
        (setf host-end colon-pos)
        (setf port (parse-integer url :start (1+ colon-pos) :end path-start))))

    ;; Find query string
    (let ((q-pos (position #\? url :start (or path-start host-end (length url)))))
      (when q-pos
        (setf query-start q-pos)))

    ;; Find fragment
    (let ((f-pos (position #\# url :start (or query-start path-start host-end (length url)))))
      (when f-pos
        (setf fragment-start f-pos)))

    (list :scheme scheme
          :host (subseq url host-start (or host-end path-start))
          :port port
          :path (cond
                  (query-start (subseq url path-start query-start))
                  (fragment-start (subseq url path-start fragment-start))
                  (t (subseq url path-start)))
          :query (when query-start
                   (subseq url (1+ query-start)
                           (or fragment-start (length url))))
          :fragment (when fragment-start
                      (subseq url (1+ fragment-start))))))

(defun build-query-string (params)
  "Build query string from plist.

  Args:
    PARAMS: Plist of parameters

  Returns:
    Query string (without leading ?)"
  (let ((pairs nil))
    (loop for (key value) on params by #'cddr
          do (push (format nil "~A=~A"
                           (url-encode (string key))
                           (url-encode (princ-to-string value)))
                   pairs))
    (format nil "~{~A~^&~}" (nreverse pairs))))

;;; ============================================================================
;;; HTTP Request Methods
;;; ============================================================================

(defun http-client-request (client method url &key headers body query params
                            content-type timeout)
  "Make an HTTP request.

  Args:
    CLIENT: HTTP client instance
    METHOD: HTTP method (GET, POST, PUT, PATCH, DELETE)
    URL: Request URL
    HEADERS: Additional headers
    BODY: Request body (for POST/PUT/PATCH)
    QUERY: Query parameters (plist, appended to URL)
    PARAMS: Form parameters (plist, for POST)
    CONTENT-TYPE: Content-Type header
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (let* ((start-time (get-universal-time))
         (merged-headers (alexandria:alist-hash-table
                          (append (http-client-default-headers client)
                                  headers)))
         (final-url (if (or query params)
                        (let* ((parsed (parse-url url))
                               (existing-query (getf parsed :query))
                               (new-query (build-query-string (append query params))))
                          (format nil "~A~A~@[?~]~@[~A~]~@[#~A~]"
                                  (getf parsed :scheme) "://"
                                  (getf parsed :host)
                                  (getf parsed :path)
                                  (if existing-query
                                      (format nil "~A&~A" existing-query new-query)
                                      new-query)
                                  (getf parsed :fragment)))
                        url))
         (request-timeout (or timeout (http-client-timeout client)))
         (status nil)
         (response-headers nil)
         (response-body nil))

    (log-info "~A ~A" method final-url)

    ;; Use Dexador for actual HTTP request
    (handler-case
        (let ((dex-headers nil)
              (dex-body nil))

          ;; Convert headers for Dexador
          (maphash (lambda (k v)
                     (push (cons (string-downcase k) v) dex-headers))
                   merged-headers)

          ;; Make request based on method
          (ecase (intern (string-upcase (string method)) :keyword)
            ((:get :head)
             (multiple-value-setq (response-body status dex-headers)
               (if (eq method :get)
                   (dexador:get final-url
                                :headers dex-headers
                                :timeout request-timeout
                                :want-stream nil)
                   (dexador:head final-url
                                 :headers dex-headers
                                 :timeout request-timeout))))

            ((:post)
             (multiple-value-setq (response-body status dex-headers)
               (dexador:post final-url
                             :content (or body
                                          (when params
                                            (build-query-string params)))
                             :headers dex-headers
                             :timeout request-timeout
                             :want-stream nil)))

            ((:put)
             (multiple-value-setq (response-body status dex-headers)
               (dexador:put final-url
                            :content (or body
                                         (when params
                                           (build-query-string params)))
                            :headers dex-headers
                            :timeout request-timeout
                            :want-stream nil)))

            ((:patch)
             (multiple-value-setq (response-body status dex-headers)
               (dexador:patch final-url
                              :content (or body
                                           (when params
                                             (build-query-string params)))
                              :headers dex-headers
                              :timeout request-timeout
                              :want-stream nil)))

            ((:delete)
             (multiple-value-setq (response-body status dex-headers)
               (dexador:delete final-url
                               :headers dex-headers
                               :timeout request-timeout
                               :want-stream nil))))

          ;; Create response
          (let ((elapsed (- (get-universal-time) start-time))
                (headers-hash (make-hash-table :test 'equal)))
            ;; Convert Dexador headers to hash table
            (when dex-headers
              (dolist (header dex-headers)
                (setf (gethash (car header) headers-hash) (cdr header))))

            (make-http-response status headers-hash response-body
                                :url final-url
                                :elapsed elapsed)))

      (dexador.error:http-request-failed (e)
        (log-error "HTTP request failed: ~A" e)
        (make-http-response (dexador.error:http-request-status e)
                            (make-hash-table)
                            (dexador.error:http-request-body e)
                            :url final-url
                            :elapsed (- (get-universal-time) start-time)))

      (error (e)
        (log-error "HTTP request error: ~A" e)
        (make-http-response 0
                            (make-hash-table)
                            (format nil "Error: ~A" e)
                            :url final-url
                            :elapsed (- (get-universal-time) start-time))))))

;;; ============================================================================
;;; Convenience Methods
;;; ============================================================================

(defun http-client-get (client url &key headers query params timeout)
  "Make HTTP GET request.

  Args:
    CLIENT: HTTP client instance
    URL: Request URL
    HEADERS: Additional headers
    QUERY: Query parameters (plist)
    PARAMS: Additional URL parameters
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (http-client-request client :get url
                       :headers headers
                       :query query
                       :params params
                       :timeout timeout))

(defun http-client-post (client url &key headers body params content-type timeout)
  "Make HTTP POST request.

  Args:
    CLIENT: HTTP client instance
    URL: Request URL
    HEADERS: Additional headers
    BODY: Request body
    PARAMS: Form parameters (plist)
    CONTENT-TYPE: Content-Type header
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (let ((merged-headers (if content-type
                            (alexandria:alist-hash-table
                             (list (cons "Content-Type" content-type)))
                            (make-hash-table))))
    (maphash (lambda (k v) (setf (gethash k merged-headers) v)) headers)
    (http-client-request client :post url
                         :headers merged-headers
                         :body body
                         :params params
                         :timeout timeout)))

(defun http-client-put (client url &key headers body params timeout)
  "Make HTTP PUT request.

  Args:
    CLIENT: HTTP client instance
    URL: Request URL
    HEADERS: Additional headers
    BODY: Request body
    PARAMS: Form parameters (plist)
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (http-client-request client :put url
                       :headers headers
                       :body body
                       :params params
                       :timeout timeout))

(defun http-client-patch (client url &key headers body params timeout)
  "Make HTTP PATCH request.

  Args:
    CLIENT: HTTP client instance
    URL: Request URL
    HEADERS: Additional headers
    BODY: Request body
    PARAMS: Form parameters (plist)
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (http-client-request client :patch url
                       :headers headers
                       :body body
                       :params params
                       :timeout timeout))

(defun http-client-delete (client url &key headers timeout)
  "Make HTTP DELETE request.

  Args:
    CLIENT: HTTP client instance
    URL: Request URL
    HEADERS: Additional headers
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (http-client-request client :delete url
                       :headers headers
                       :timeout timeout))

;;; ============================================================================
;;; Standalone Functions
;;; ============================================================================

(defvar *default-client* (make-http-client)
  "Default HTTP client for standalone functions.")

(defun http-get (url &key headers query params timeout)
  "Make HTTP GET request with default client.

  Args:
    URL: Request URL
    HEADERS: Additional headers
    QUERY: Query parameters (plist)
    PARAMS: Additional URL parameters
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (http-client-get *default-client* url
                   :headers headers
                   :query query
                   :params params
                   :timeout timeout))

(defun http-post (url &key headers body params content-type timeout)
  "Make HTTP POST request with default client.

  Args:
    URL: Request URL
    HEADERS: Additional headers
    BODY: Request body
    PARAMS: Form parameters (plist)
    CONTENT-TYPE: Content-Type header
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (http-client-post *default-client* url
                    :headers headers
                    :body body
                    :params params
                    :content-type content-type
                    :timeout timeout))

(defun http-put (url &key headers body params timeout)
  "Make HTTP PUT request with default client.

  Args:
    URL: Request URL
    HEADERS: Additional headers
    BODY: Request body
    PARAMS: Form parameters (plist)
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (http-client-put *default-client* url
                   :headers headers
                   :body body
                   :params params
                   :timeout timeout))

(defun http-patch (url &key headers body params timeout)
  "Make HTTP PATCH request with default client.

  Args:
    URL: Request URL
    HEADERS: Additional headers
    BODY: Request body
    PARAMS: Form parameters (plist)
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (http-client-patch *default-client* url
                     :headers headers
                     :body body
                     :params params
                     :timeout timeout))

(defun http-delete (url &key headers timeout)
  "Make HTTP DELETE request with default client.

  Args:
    URL: Request URL
    HEADERS: Additional headers
    TIMEOUT: Request timeout override

  Returns:
    HTTP response instance"
  (http-client-delete *default-client* url
                      :headers headers
                      :timeout timeout))

;;; ============================================================================
;;; HTTP Session (Connection Pooling)
;;; ============================================================================

(defclass http-session ()
  ((client :initarg :client
           :reader session-client
           :documentation "HTTP client for this session")
   (base-url :initarg :base-url
             :reader session-base-url
             :documentation "Base URL for all requests")
   (default-headers :initarg :default-headers
                    :accessor session-default-headers
                    :documentation "Default headers for this session"))
  (:documentation "HTTP session with connection pooling"))

(defun make-http-session (base-url &key headers timeout verify-ssl)
  "Create an HTTP session.

  Args:
    BASE-URL: Base URL for all requests
    HEADERS: Default headers
    TIMEOUT: Request timeout
    VERIFY-SSL: Verify SSL certificates

  Returns:
    HTTP session instance"
  (make-instance 'http-session
                 :base-url base-url
                 :client (make-http-client :default-headers headers
                                           :timeout timeout
                                           :verify-ssl verify-ssl)
                 :default-headers (or headers (make-hash-table))))

(defun session-request (session method path &key headers body params query)
  "Make a request using session.

  Args:
    SESSION: HTTP session instance
    METHOD: HTTP method
    PATH: URL path (appended to base-url)
    HEADERS: Additional headers
    BODY: Request body
    PARAMS: Form parameters
    QUERY: Query parameters

  Returns:
    HTTP response instance"
  (let ((url (format nil "~A~A" (session-base-url session) path))
        (merged-headers (make-hash-table)))
    ;; Merge session and request headers
    (maphash (lambda (k v) (setf (gethash k merged-headers) v))
             (session-default-headers session))
    (when headers
      (maphash (lambda (k v) (setf (gethash k merged-headers) v))
               headers))

    (http-client-request (session-client session)
                         method
                         url
                         :headers merged-headers
                         :body body
                         :params params
                         :query query)))

(defun session-get (session path &key headers query params)
  "Make GET request using session."
  (session-request session :get path :headers headers :query query :params params))

(defun session-post (session path &key headers body params)
  "Make POST request using session."
  (session-request session :post path :headers headers :body body :params params))

(defun session-put (session path &key headers body params)
  "Make PUT request using session."
  (session-request session :put path :headers headers :body body :params params))

(defun session-patch (session path &key headers body params)
  "Make PATCH request using session."
  (session-request session :patch path :headers headers :body body :params params))

(defun session-delete (session path &key headers)
  "Make DELETE request using session."
  (session-request session :delete path :headers headers))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-http-client-system (&key timeout max-redirects verify-ssl)
  "Initialize the HTTP client system.

  Args:
    TIMEOUT: Default timeout in seconds
    MAX-REDIRECTS: Maximum redirects
    VERIFY-SSL: Verify SSL certificates

  Returns:
    T"
  (setf *default-client* (make-http-client :timeout timeout
                                           :max-redirects max-redirects
                                           :verify-ssl verify-ssl))
  (log-info "HTTP client system initialized")
  t)
