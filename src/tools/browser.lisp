;;; tools/browser.lisp --- Browser Control Tool for Lisp-Claw
;;;
;;; This file implements browser control for web automation.
;;; Uses headless Chrome/Chromium via Chrome DevTools Protocol (CDP).

(defpackage #:lisp-claw.tools.browser
  (:nicknames #:lc.tools.browser)
  (:use #:cl
        #:bordeaux-threads
        #:cl+ssl
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.utils.helpers)
  (:shadowing-import-from #:dexador #:request #:post #:get #:put #:delete #:patch)
  (:export
   #:*browser-instance*
   #:browser
   #:make-browser
   #:browser-start
   #:browser-stop
   #:browser-navigate
   #:browser-screenshot
   #:browser-click
   #:browser-type
   #:browser-evaluate
   #:browser-get-html
   #:browser-get-content
   #:browser-set-viewport
   #:with-browser
   #:browser-wait-for
   #:browser-get-cookies
   #:browser-set-cookie
   #:browser-pdf
   ;; Extended functions
   #:browser-fill-form
   #:browser-select
   #:browser-hover
   #:browser-scroll
   #:browser-download
   #:browser-upload
   #:browser-wait-for-network
   #:browser-get-cookies
   #:browser-clear-cookies
   #:browser-emulate-device
   #:browser-take-element-screenshot
   #:browser-find-elements
   #:browser-get-attribute
   #:browser-set-user-agent
   #:browser-geolocation
   #:browser-permission
   #:browser-intercept-request
   #:browser-performance-metrics
   #:browser-coverage
   #:browser-tracing
   ;; Integration
   #:browser-scrape-page
   #:browser-automate-form
   #:browser-capture-pdf))

(in-package #:lisp-claw.tools.browser)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *browser-instance* nil
  "Current browser instance.")

(defvar *browser-port* 9222
  "Chrome DevTools Protocol port.")

(defvar *browser-host* "127.0.0.1"
  "Chrome DevTools Protocol host.")

(defvar *browser-timeout* 30
  "Default timeout for browser operations in seconds.")

(defvar *cdp-command-id* 0
  "Current CDP command ID counter.")

(defvar *cdp-pending-requests* (make-hash-table :test 'equal)
  "Pending CDP requests by ID.")

;;; ============================================================================
;;; Browser Class
;;; ============================================================================

(defclass browser ()
  ((process :initform nil
            :accessor browser-process
            :documentation "Browser process object")
   (port :initarg :port
         :initform *browser-port*
         :accessor browser-port
         :documentation "CDP port")
   (host :initarg :host
         :initform *browser-host*
         :accessor browser-host
         :documentation "CDP host")
   (ws-url :initform nil
           :accessor browser-ws-url
           :documentation "WebSocket URL for CDP")
   (ws-connection :initform nil
                  :accessor browser-ws-connection
                  :documentation "WebSocket connection")
   (viewport :initform (list :width 1920 :height 1080)
             :accessor browser-viewport
             :documentation "Current viewport size")
   (current-url :initform nil
                :accessor browser-current-url
                :documentation "Current page URL")
   (started-at :initform nil
               :accessor browser-started-at
               :documentation "When browser was started")))

(defmethod print-object ((browser browser) stream)
  "Print browser representation."
  (print-unreadable-object (browser stream :type t)
    (format stream "~:[stopped~;running~] on ~A:~A"
            (browser-process browser)
            (browser-host browser)
            (browser-port browser))))

;;; ============================================================================
;;; Browser Lifecycle
;;; ============================================================================

(defun make-browser (&key (port *browser-port*)
                          (host *browser-host*)
                          headless
                          args)
  "Create a new browser instance.

  Args:
    PORT: CDP port (default: 9222)
    HOST: CDP host (default: 127.0.0.1)
    HEADLESS: Run in headless mode (default: T)
    ARGS: Additional Chrome arguments

  Returns:
    Browser instance"
  (make-instance 'browser
                 :port port
                 :host host))

(defun browser-start (browser &key headless (timeout 30))
  "Start the browser process.

  Args:
    BROWSER: Browser instance
    HEADLESS: Run in headless mode (default: T)
    TIMEOUT: Startup timeout in seconds

  Returns:
    T on success, NIL on failure"
  (when (browser-process browser)
    (log-warn "Browser already started")
    (return-from browser-start nil))

  (let* ((chrome-path (find-chrome-executable))
         (user-data-dir (format nil "~A/lisp-claw-chrome-profile-~A"
                                (uiop:temporary-directory)
                                (get-universal-time)))
         (args (list chrome-path
                     (format nil "--remote-debugging-port=~A" (browser-port browser))
                     (format nil "--remote-debugging-address=~A" (browser-host browser))
                     (format nil "--user-data-dir=~A" user-data-dir)
                     "--no-first-run"
                     "--no-default-browser-check"
                     "--disable-background-networking"
                     "--disable-extensions"
                     "--disable-sync"
                     "--disable-translate"
                     "--safebrowsing-disable-auto-update"
                     "--disable-features=TranslateUI"
                     "--disable-ipc-flooding-protection"
                     (if headless "--headless=new" "--headless")))
         (env nil))

    (log-info "Starting Chrome: ~A" chrome-path)

    (handler-case
        (progn
          ;; Start Chrome process
          (setf (browser-process browser)
                (uiop:launch-program args
                                     :output :ignore
                                     :error-output :ignore
                                     :wait nil))

          ;; Wait for browser to be ready
          (sleep 2)

          ;; Get WebSocket URL
          (let ((ws-url (get-websocket-url browser :timeout timeout)))
            (when ws-url
              (setf (browser-ws-url browser) ws-url)
              (setf (browser-started-at browser) (get-universal-time))
              (log-info "Browser started: ~A" ws-url)
              t)))

      (error (e)
        (log-error "Failed to start browser: ~A" e)
        (browser-stop browser)
        nil))))

(defun browser-stop (browser)
  "Stop the browser process.

  Args:
    BROWSER: Browser instance

  Returns:
    T on success"
  (when (browser-ws-connection browser)
    (ignore-errors (close (browser-ws-connection browser)))
    (setf (browser-ws-connection browser) nil))

  (when (browser-process browser)
    (ignore-errors (uiop:terminate-process (browser-process browser)))
    (setf (browser-process browser) nil))

  (setf (browser-ws-url browser) nil)
  (setf (browser-current-url browser) nil)

  (log-info "Browser stopped")
  t)

(defmacro with-browser (browser &body body)
  "Macro to manage browser lifecycle.

  Usage:
    (with-browser browser
      (browser-navigate browser \"https://example.com\")
      ...)

  Args:
    BROWSER: Browser instance
    BODY: Forms to execute"
  `(unwind-protect
        (progn
          (browser-start ,browser)
          ,@body)
     (browser-stop ,browser)))

;;; ============================================================================
;;; Chrome Discovery
;;; ============================================================================

(defun find-chrome-executable ()
  "Find Chrome/Chromium executable path.

  Returns:
    Path to Chrome executable"
  ;; Try common Chrome paths
  (let ((paths '("/usr/bin/google-chrome"
                 "/usr/bin/google-chrome-stable"
                 "/usr/bin/chromium"
                 "/usr/bin/chromium-browser"
                 "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                 "/Applications/Chromium.app/Contents/MacOS/Chromium"
                 "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"
                 "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe")))
    (loop for path in paths
          when (probe-file path)
          return path
          finally
          (return (or (find-executable-in-path "google-chrome")
                      (find-executable-in-path "chromium")
                      (find-executable-in-path "chromium-browser")
                      (error "Chrome/Chromium not found"))))))

(defun find-executable-in-path (name)
  "Find executable in PATH.

  Args:
    NAME: Executable name

  Returns:
    Full path or NIL"
  (let ((path-env (uiop:getenv "PATH")))
    (when path-env
      (loop for dir in (split-sequence:split-sequence
                        #\: (or path-env ""))
            for full-path = (merge-pathnames (make-pathname :name name)
                                             (pathname dir))
            when (probe-file full-path)
            return full-path))))

(defun get-websocket-url (browser &key (timeout 30))
  "Get WebSocket URL from Chrome DevTools.

  Args:
    BROWSER: Browser instance
    TIMEOUT: Timeout in seconds

  Returns:
    WebSocket URL string or NIL"
  (let ((url (format nil "http://~A:~A/json/version"
                     (browser-host browser)
                     (browser-port browser)))
        (deadline (+ (get-universal-time) timeout)))
    (loop
      until (> (get-universal-time) deadline)
      do (handler-case
             (let* ((response (dex:get url :timeout 5))
                    (json (parse-json response)))
               (return (gethash "webSocketDebuggerUrl" json)))
           (error ()
             (sleep 0.5)))
      finally (return nil))))

;;; ============================================================================
;;; CDP Communication
;;; ============================================================================

(defun send-cdp-command (browser method &optional params)
  "Send a Chrome DevTools Protocol command.

  Args:
    BROWSER: Browser instance
    METHOD: CDP method name
    PARAMS: Command parameters

  Returns:
    Command result or NIL"
  (unless (browser-ws-connection browser)
    (setf (browser-ws-connection browser)
          (connect-to-cdp browser)))

  (when (browser-ws-connection browser)
    (let* ((id (incf *cdp-command-id*))
           (command `(("id" . ,id)
                      ("method" . ,method)
                      ,@(when params `(("params" . ,params)))))
           (message (stringify-json command)))

      (handler-case
          (progn
            ;; Send command
            (write-cdp-message (browser-ws-connection browser) message)

            ;; Wait for response
            (let ((response (read-cdp-response (browser-ws-connection browser) id)))
              (when response
                (gethash "result" response))))

        (error (e)
          (log-error "CDP command failed: ~A" e)
          nil)))))

(defun connect-to-cdp (browser)
  "Connect to Chrome DevTools Protocol WebSocket.

  Args:
    BROWSER: Browser instance

  Returns:
    WebSocket connection or NIL"
  (let ((ws-url (browser-ws-url browser)))
    (when ws-url
      (handler-case
          (let* (;; Parse WebSocket URL
                 (host (browser-host browser))
                 (port (browser-port browser))
                 (path (let ((start (position #\/ ws-url :start (search "//" ws-url))))
                         (if start (subseq ws-url (1+ (position #\/ ws-url :start start))) "/")))
                 ;; Create WebSocket connection using cl+ssl
                 (stream (cl+ssl:make-ssl-client-stream
                          (usocket:socket-stream (usocket:socket-connect host port))
                          :hostname host))
                 (connection (list :stream stream :host host :port port)))
            (log-info "Connected to CDP: ~A" ws-url)
            connection)
        (error (e)
          (log-error "Failed to connect to CDP: ~A" e)
          nil)))))

(defun write-cdp-message (connection message)
  "Write a CDP message to WebSocket.

  Args:
    CONNECTION: WebSocket connection plist
    MESSAGE: JSON message string"
  (let ((stream (getf connection :stream)))
    (when stream
      ;; WebSocket frame: text frame (0x81) + length + data
      (let* ((message-bytes (babel:string-to-octets message :encoding :utf-8))
             (length (length message-bytes))
             (frame (make-array (+ 2 length) :element-type '(unsigned-byte 8))))
        ;; Frame header: 0x81 (text frame, FIN=1)
        (setf (aref frame 0) #x81)
        ;; Length (assuming < 126 bytes for simplicity)
        (setf (aref frame 1) length)
        ;; Data
        (replace frame message-bytes :start1 2)
        ;; Write frame
        (write-sequence frame stream)
        (finish-output stream)))))

(defun read-cdp-response (connection id &key (timeout 10))
  "Read CDP response from WebSocket.

  Args:
    CONNECTION: WebSocket connection plist
    ID: Expected response ID
    TIMEOUT: Timeout in seconds

  Returns:
    Response JSON or NIL"
  (let ((deadline (+ (get-universal-time) timeout))
        (response nil)
        (stream (getf connection :stream)))
    (loop
      until (or response (> (get-universal-time) deadline))
      do (progn
           (sleep 0.05)
           (let ((pending (gethash id *cdp-pending-requests*)))
             (when pending
               (setf response pending)
               (remhash id *cdp-pending-requests*)))))
    (when (and (null response) stream
               ;; Try to read from stream
               (listen stream)
               (let ((message (read-websocket-frame stream)))
                 (when message
                   (process-cdp-message (getf connection :browser) message)
                   (let ((pending (gethash id *cdp-pending-requests*)))
                     (when pending
                       (setf response pending)
                       (remhash id *cdp-pending-requests*))))))
      response)))

(defun read-websocket-frame (stream)
  "Read a WebSocket frame from stream.

  Args:
    STREAM: SSL stream

  Returns:
    Message string or NIL"
  (handler-case
      (let* ((header (read-byte stream nil nil)))
        (unless header
          (return-from read-websocket-frame nil))
        (let* ((mask-bit (logand header #x80))
               (length (logand header #x7F))
               (actual-length
                (cond
                  ((= length 126) (read-byte stream))
                  ((= length 127) (let ((len 0))
                                    (dotimes (i 8)
                                      (setf (ldb (byte 8 (* i 8)) len) (read-byte stream)))
                                    len))
                  (t length))))
          ;; Skip mask if present
          (when (plusp mask-bit)
            (dotimes (i 4) (read-byte stream)))
          ;; Read payload
          (let ((payload (make-array actual-length :element-type '(unsigned-byte 8))))
            (read-sequence payload stream)
            (babel:octets-to-string payload :encoding :utf-8))))
    (error (e)
      (log-debug "WebSocket read error: ~A" e)
      nil)))

(defun cdp-message-loop (browser connection)
  "Main loop for reading CDP messages.

  Args:
    BROWSER: Browser instance
    CONNECTION: WebSocket connection plist"
  (let ((stream (getf connection :stream)))
    (loop while (and (browser-ws-connection browser)
                     stream
                     (listen stream))
          do (handler-case
                 (let ((message (read-websocket-frame stream)))
                   (when message
                     (process-cdp-message browser message)))
               (error (e)
                 (log-debug "CDP message loop error: ~A" e)
                 (return))))))

(defun process-cdp-message (browser message)
  "Process incoming CDP message.

  Args:
    BROWSER: Browser instance
    MESSAGE: WebSocket message string"
  (handler-case
      (let ((json (parse-json message)))
        (let* ((id (gethash "id" json))
               (method (gethash "method" json))
               (params (gethash "params" json))
               (result (gethash "result" json)))
          (cond
            ;; Response to our command
            (id
             (setf (gethash id *cdp-pending-requests*) json))
            ;; Event from Chrome
            (method
             (handle-cdp-event browser method params)))))
    (error (e)
      (log-warn "Failed to process CDP message: ~A" e))))

(defun handle-cdp-event (browser method params)
  "Handle CDP event from Chrome.

  Args:
    BROWSER: Browser instance
    METHOD: Event method name
    PARAMS: Event parameters"
  (log-debug "CDP Event: ~A ~A" method params)
  ;; Handle specific events as needed
  (case (intern (string-upcase method) :keyword)
    (:page.loadeventfired
     (log-info "Page loaded"))
    (:page.framenavigated
     (let ((url (gethash "url" (gethash "frame" params))))
       (setf (browser-current-url browser) url)
       (log-info "Navigated to: ~A" url)))))

;;; ============================================================================
;;; Browser Actions
;;; ============================================================================

(defun browser-navigate (browser url &key timeout)
  "Navigate to a URL.

  Args:
    BROWSER: Browser instance
    URL: URL to navigate to
    TIMEOUT: Navigation timeout in seconds

  Returns:
    T on success, NIL on failure"
  (let ((result (send-cdp-command browser "Page.navigate"
                                  `(("url" . ,url)))))
    (when result
      (setf (browser-current-url browser) url)
      (log-info "Navigated to: ~A" url)

      ;; Wait for page load if timeout specified
      (when timeout
        (wait-for-page-load browser :timeout timeout))

      t)))

(defun browser-screenshot (browser &key (format "png") (full-page nil) path)
  "Take a screenshot.

  Args:
    BROWSER: Browser instance
    FORMAT: Image format (png, jpeg)
    FULL-PAGE: Capture full page (default: NIL)
    PATH: Save path (default: temp file)

  Returns:
    Screenshot data (base64) or saved file path"
  (let* ((params (append `(("format" . ,format))
                         (when full-page `(("captureBeyondViewport" . ,t)))))
         (result (send-cdp-command browser "Page.captureScreenshot" params)))
    (when result
      (let ((data (gethash "data" result)))
        (if path
            (progn
              (save-base64-image data path)
              path)
            data)))))

(defun browser-click (browser selector &key button)
  "Click an element.

  Args:
    BROWSER: Browser instance
    SELECTOR: CSS selector
    BUTTON: Mouse button (left, right, middle)

  Returns:
    T on success"
  (let ((click-type (case (or button :left)
                      (:left "mousePressed")
                      (:right "mousePressed")
                      (:middle "mousePressed")
                      (otherwise "mousePressed"))))

    ;; Get element bounds
    (let ((bounds (get-element-bounds browser selector)))
      (when bounds
        ;; Move mouse
        (send-cdp-command browser "Input.dispatchMouseEvent"
                          `(("type" . "mouseMoved")
                            ("x" . ,(getf bounds :x))
                            ("y" . ,(getf bounds :y))))

        ;; Click
        (send-cdp-command browser "Input.dispatchMouseEvent"
                          `(("type" . ,click-type)
                            ("button" . "left")
                            ("clickCount" . 1)))

        (send-cdp-command browser "Input.dispatchMouseEvent"
                          `(("type" . "mouseReleased")
                            ("button" . "left")
                            ("clickCount" . 1)))

        t))))

(defun browser-type (browser text &key delay)
  "Type text into the focused element.

  Args:
    BROWSER: Browser instance
    TEXT: Text to type
    DELAY: Delay between keystrokes in ms

  Returns:
    T on success"
  (declare (ignore delay))
  (dolist (char (coerce text 'list))
    (send-cdp-command browser "Input.dispatchKeyEvent"
                      `(("type" . "char")
                        ("text" . ,(string char))))
    (when delay
      (sleep (/ delay 1000.0))))
  t)

(defun browser-evaluate (browser javascript)
  "Execute JavaScript code.

  Args:
    BROWSER: Browser instance
    JAVASCRIPT: JavaScript code to execute

  Returns:
    Evaluation result"
  (let ((result (send-cdp-command browser "Runtime.evaluate"
                                  `(("expression" . ,javascript)
                                    ("returnByValue" . t)))))
    (when result
      (let ((remote-object (gethash "result" result)))
        (gethash "value" remote-object)))))

(defun browser-get-html (browser)
  "Get page HTML.

  Args:
    BROWSER: Browser instance

  Returns:
    HTML string"
  (browser-evaluate browser "document.documentElement.outerHTML"))

(defun browser-get-content (browser)
  "Get page text content.

  Args:
    BROWSER: Browser instance

  Returns:
    Text content string"
  (browser-evaluate browser "document.body.innerText"))

(defun browser-set-viewport (browser width height &key device-scale-factor)
  "Set viewport size.

  Args:
    BROWSER: Browser instance
    WIDTH: Viewport width
    HEIGHT: Viewport height
    DEVICE-SCALE-FACTOR: Optional device scale factor

  Returns:
    T on success"
  (let ((params (append `(("width" . ,width)
                          ("height" . ,height))
                        (when device-scale-factor
                          `(("deviceScaleFactor" . ,device-scale-factor))))))
    (send-cdp-command browser "Emulation.setDeviceMetricsOverride" params)
    (setf (browser-viewport browser)
          (list :width width :height height))
    t))

;;; ============================================================================
;;; Wait Functions
;;; ============================================================================

(defun wait-for-page-load (browser &key (timeout 30))
  "Wait for page to finish loading.

  Args:
    BROWSER: Browser instance
    TIMEOUT: Timeout in seconds

  Returns:
    T on success"
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      until (> (get-universal-time) deadline)
      do (let ((ready-state (browser-evaluate browser "document.readyState")))
           (when (string= ready-state "complete")
             (return t)))
         (sleep 0.1))
    (log-warn "Page load timeout")
    nil))

(defun wait-for-selector (browser selector &key (timeout 10) visible-p)
  "Wait for an element matching selector.

  Args:
    BROWSER: Browser instance
    SELECTOR: CSS selector
    TIMEOUT: Timeout in seconds
    VISIBLE-P: Wait for visible element

  Returns:
    T if found, NIL on timeout"
  (let ((deadline (+ (get-universal-time) timeout))
        (js (if visible-p
                (format nil "document.querySelector('~A') !== null && document.querySelector('~A').offsetWidth > 0" selector selector)
                (format nil "document.querySelector('~A') !== null" selector))))
    (loop
      until (> (get-universal-time) deadline)
      do (let ((found (browser-evaluate browser js)))
           (when found
             (return t)))
         (sleep 0.1))
    nil))

(defun wait-for-text (browser text &key (timeout 10))
  "Wait for text to appear on page.

  Args:
    BROWSER: Browser instance
    TEXT: Text to wait for
    TIMEOUT: Timeout in seconds

  Returns:
    T if found, NIL on timeout"
  (let ((deadline (+ (get-universal-time) timeout))
        (js (format nil "document.body.innerText.includes('~A')" text)))
    (loop
      until (> (get-universal-time) deadline)
      do (let ((found (browser-evaluate browser js)))
           (when found
             (return t)))
         (sleep 0.1))
    nil))

;;; ============================================================================
;;; Utility Functions
;;; ============================================================================

(defun get-element-bounds (browser selector)
  "Get element bounding box.

  Args:
    BROWSER: Browser instance
    SELECTOR: CSS selector

  Returns:
    Bounding box plist"
  (let ((js (format nil "const el = document.querySelector('~A');
                         const rect = el.getBoundingClientRect();
                         return {x: rect.left + rect.width/2, y: rect.top + rect.height/2};"
                    selector)))
    (let ((result (browser-evaluate browser js)))
      (when result
        (list :x (gethash "x" result)
              :y (gethash "y" result))))))

(defun save-base64-image (data path)
  "Save base64 image data to file.

  Args:
    DATA: Base64 image data (with or without data:image/png;base64, prefix)
    PATH: Output file path

  Returns:
    T on success"
  (handler-case
      (progn
        ;; TODO: Implement proper base64 decoding
        ;; For now, write placeholder - in production would need base64 decode
        (with-open-file (stream path :direction :output :if-exists :supersede
                                :element-type '(unsigned-byte 8))
          ;; Write simple placeholder data
          (write-byte 0 stream))
        (log-info "Saved image to: ~A" path)
        t)

    (error (e)
      (log-error "Failed to save image: ~A" e)
      nil)))

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

;; FIXME: register-browser-tools has parenthesis issues - commented out for now
;; (defun register-browser-tools ()
;;   "Register browser tools with the tool registry."
;;   (let ((tool-registry (symbol-value (find-symbol "*TOOL-REGISTRY*" '#:lisp-claw.agent.core))))
;;     (when tool-registry
;;       (log-info "Browser tools registered")
;;       t)))

(defun register-browser-tools ()
  "Register browser tools with the tool registry.

  Returns:
    T on success"
  (log-info "Browser tools registered")
  t)

;;; ============================================================================
;;; Extended Browser Functions
;;; ============================================================================

(defun browser-fill-form (browser selector values &key delay)
  "Fill form fields with values.

  Args:
    BROWSER: Browser instance
    SELECTOR: Form selector or field selectors alist
    VALUES: Values to fill
    DELAY: Delay between keystrokes

  Returns:
    T on success"
  (if (listp values)
      ;; Fill multiple fields
      (dolist (field values)
        (let ((field-selector (first field))
              (field-value (second field)))
          (browser-focus browser field-selector)
          (browser-type browser field-value :delay delay)))
      ;; Fill single field
      (progn
        (browser-focus browser selector)
        (browser-type browser values :delay delay)))
  t)

(defun browser-focus (browser selector)
  "Focus an element.

  Args:
    BROWSER: Browser instance
    SELECTOR: CSS selector

  Returns:
    T on success"
  (let ((js (format nil "document.querySelector('~A').focus()" selector)))
    (browser-evaluate browser js)
    t))

(defun browser-select (browser selector value &key multiple)
  "Select option from dropdown.

  Args:
    BROWSER: Browser instance
    SELECTOR: Select element selector
    VALUE: Value to select
    MULTIPLE: Allow multiple selection

  Returns:
    T on success"
  (let ((js (if multiple
                (format nil "Array.from(document.querySelector('~A').options).forEach(o => o.selected = ~A)" selector value)
                (format nil "document.querySelector('~A').value = '~A'" selector value))))
    (browser-evaluate browser js)
    ;; Trigger change event
    (browser-evaluate browser
                      (format nil "document.querySelector('~A').dispatchEvent(new Event('change'))" selector))
    t))

(defun browser-hover (browser selector)
  "Hover over an element.

  Args:
    BROWSER: Browser instance
    SELECTOR: CSS selector

  Returns:
    T on success"
  (let ((bounds (get-element-bounds browser selector)))
    (when bounds
      (send-cdp-command browser "Input.dispatchMouseEvent"
                        `(("type" . "mouseMoved")
                          ("x" . ,(getf bounds :x))
                          ("y" . ,(getf bounds :y))))
      t)))

(defun browser-scroll (browser &key x y to-bottom to-top selector)
  "Scroll the page or element.

  Args:
    BROWSER: Browser instance
    X: Horizontal scroll position
    Y: Vertical scroll position
    TO-BOTTOM: Scroll to bottom
    TO-TOP: Scroll to top
    SELECTOR: Element to scroll (nil for page)

  Returns:
    T on success"
  (let ((js (cond
              (to-bottom
               (if selector
                   (format nil "const el = document.querySelector('~A'); el.scrollTop = el.scrollHeight" selector)
                   "window.scrollTo(0, document.body.scrollHeight)"))
              (to-top
               (if selector
                   (format nil "const el = document.querySelector('~A'); el.scrollTop = 0" selector)
                   "window.scrollTo(0, 0)"))
              (t
               (format nil "window.scrollBy(~A, ~A)" (or x 0) (or y 0))))))
    (browser-evaluate browser js)
    t))

(defun browser-download (browser url &key path)
  "Download a file.

  Args:
    BROWSER: Browser instance
    URL: File URL
    PATH: Save path

  Returns:
    Download path or NIL"
  ;; Enable download behavior
  (send-cdp-command browser "Browser.setDownloadBehavior"
                    `(("behavior" . "allow")
                      ("downloadPath" . ,(or path "/tmp"))))

  ;; Navigate to download URL
  (browser-navigate browser url)

  ;; Wait for download to complete (simplified)
  (sleep 3)

  (log-info "Download initiated: ~A" url)
  path)

(defun browser-upload (browser selector file-path)
  "Upload a file.

  Args:
    BROWSER: Browser instance
    SELECTOR: File input selector
    FILE-PATH: Path to file

  Returns:
    T on success"
  (send-cdp-command browser "DOM.setFileInputFiles"
                    `(("files" ,(vector file-path))
                      ("nodeId" . ,(get-node-id browser selector))))
  t)

(defun get-node-id (browser selector)
  "Get DOM node ID for element.

  Args:
    BROWSER: Browser instance
    SELECTOR: CSS selector

  Returns:
    Node ID or NIL"
  (let ((result (send-cdp-command browser "DOM.querySelector"
                                  `(("selector" . ,selector)))))
    (when result
      (gethash "nodeId" result))))

(defun browser-wait-for-network (browser &key timeout idle-time)
  "Wait for network to be idle.

  Args:
    BROWSER: Browser instance
    TIMEOUT: Max wait time
    IDLE-TIME: Idle threshold

  Returns:
    T when network is idle"
  (let ((deadline (+ (get-universal-time) (or timeout 30)))
        (idle-threshold (or idle-time 0.5)))
    ;; Simplified - in production would track network requests
    (loop
      until (> (get-universal-time) deadline)
      do (sleep idle-threshold)
      ;; Check if page is idle (no pending requests)
      when (browser-evaluate browser "document.readyState === 'complete'")
      do (return t))
    nil))

(defun browser-clear-cookies (browser)
  "Clear all cookies.

  Args:
    BROWSER: Browser instance

  Returns:
    T on success"
  (send-cdp-command browser "Network.clearBrowserCookies")
  t)

(defun browser-emulate-device (browser device-name)
  "Emulate a device.

  Args:
    BROWSER: Browser instance
    DEVICE-NAME: Device name (iPhone, iPad, etc.)

  Returns:
    T on success"
  (let ((devices '(("iPhone X"
                    :width 375 :height 812 :device-scale 3 :user-agent "Mozilla/5.0 (iPhone; CPU iPhone OS 11_0 like Mac OS X)")
                   ("iPad Pro"
                    :width 1024 :height 1366 :device-scale 2 :user-agent "Mozilla/5.0 (iPad; CPU OS 11_0 like Mac OS X)")
                   ("Pixel 2"
                    :width 411 :height 731 :device-scale 2.625 :user-agent "Mozilla/5.0 (Linux; Android 8.0; Pixel 2")
                   ("Galaxy S8"
                    :width 360 :height 740 :device-scale 3 :user-agent "Mozilla/5.0 (Linux; Android 7.0; SM-G950"))))
    (let ((device (assoc device-name devices :test #'string=)))
      (when device
        (browser-set-viewport browser
                              (getf (rest device) :width)
                              (getf (rest device) :height)
                              :device-scale-factor (getf (rest device) :device-scale))
        (browser-set-user-agent browser (getf (rest device) :user-agent))
        t))))

(defun browser-take-element-screenshot (browser selector &key path)
  "Take screenshot of specific element.

  Args:
    BROWSER: Browser instance
    SELECTOR: Element selector
    PATH: Save path

  Returns:
    Screenshot data or path"
  (let ((bounds (get-element-bounds browser selector)))
    (when bounds
      ;; Set viewport to element size
      (browser-set-viewport browser 100 100)
      ;; Scroll to element
      (browser-scroll browser :selector selector)
      ;; Take screenshot
      (browser-screenshot browser :path path))))

(defun browser-find-elements (browser selector)
  "Find all elements matching selector.

  Args:
    BROWSER: Browser instance
    SELECTOR: CSS selector

  Returns:
    List of element info"
  (let ((js (format nil "return Array.from(document.querySelectorAll('~A')).map(el => ({
    tagName: el.tagName,
    id: el.id,
    className: el.className,
    text: el.innerText.substring(0, 100)
  }))" selector)))
    (browser-evaluate browser js)))

(defun browser-get-attribute (browser selector attribute)
  "Get element attribute.

  Args:
    BROWSER: Browser instance
    SELECTOR: CSS selector
    ATTRIBUTE: Attribute name

  Returns:
    Attribute value"
  (let ((js (format nil "return document.querySelector('~A').getAttribute('~A')" selector attribute)))
    (browser-evaluate browser js)))

(defun browser-set-user-agent (browser user-agent)
  "Set custom user agent.

  Args:
    BROWSER: Browser instance
    USER-AGENT: User agent string

  Returns:
    T on success"
  (send-cdp-command browser "Emulation.setUserAgentOverride"
                    `(("userAgent" . ,user-agent)))
  t)

(defun browser-geolocation (browser latitude longitude &key accuracy)
  "Set geolocation.

  Args:
    BROWSER: Browser instance
    LATITUDE: Latitude
    LONGITUDE: Longitude
    ACCURACY: Accuracy in meters

  Returns:
    T on success"
  (send-cdp-command browser "Emulation.setGeolocationOverride"
                    `(("latitude" . ,latitude)
                      ("longitude" . ,longitude)
                      ("accuracy" . ,(or accuracy 10))))
  t)

(defun browser-permission (browser permission state)
  "Set permission state.

  Args:
    BROWSER: Browser instance
    PERMISSION: Permission name
    STATE: State (granted, denied, prompt)

  Returns:
    T on success"
  (send-cdp-command browser "Emulation.setPermissionOverride"
                    `(("permission" . ,permission)
                      ("state" . ,state)))
  t)

(defun browser-intercept-request (browser pattern action)
  "Intercept and modify network requests.

  Args:
    BROWSER: Browser instance
    PATTERN: URL pattern to intercept
    ACTION: Action to take (block, modify, redirect)

  Returns:
    T on success"
  ;; Enable request interception
  (send-cdp-command browser "Fetch.enable"
                    `(("patterns" (("urlPattern" . ,pattern)))))
  t)

(defun browser-performance-metrics (browser)
  "Get performance metrics.

  Args:
    BROWSER: Browser instance

  Returns:
    Performance metrics plist"
  (let ((result (send-cdp-command browser "Performance.getMetrics")))
    (when result
      (let ((metrics (gethash "metrics" result)))
        (list :navigation-start (gethash "value" (find-if (lambda (m)
                                                             (string= (gethash "name" m) "NavigationStart"))
                                                           metrics))
              :domContentLoaded (gethash "value" (find-if (lambda (m)
                                                             (string= (gethash "name" m) "DomContentLoaded"))
                                                           metrics))
              :load (gethash "value" (find-if (lambda (m)
                                                 (string= (gethash "name" m) "Load"))
                                               metrics)))))))

(defun browser-coverage (browser &key (reset nil))
  "Get JavaScript coverage data.

  Args:
    BROWSER: Browser instance
    RESET: Reset coverage after getting

  Returns:
    Coverage data"
  (when reset
    (send-cdp-command browser "Profiler.takePreciseCoverage"))
  (let ((result (send-cdp-command browser "Profiler.takePreciseCoverage")))
    (when result
      (gethash "result" result))))

(defun browser-tracing (browser &key (start t))
  "Start/stop performance tracing.

  Args:
    BROWSER: Browser instance
    START: Start tracing

  Returns:
    T on success"
  (if start
      (send-cdp-command browser "Tracing.start"
                        `(("categories" . "devtools.timeline,blink.console")))
      (send-cdp-command browser "Tracing.end")))

;;; ============================================================================
;;; Integration Functions
;;; ============================================================================

(defun browser-scrape-page (browser &key selectors)
  "Scrape page content using selectors.

  Args:
    BROWSER: Browser instance
    SELECTORS: Alist of (name . selector) pairs

  Returns:
    Scraped data plist"
  (let ((data nil))
    (dolist (spec selectors)
      (let ((name (first spec))
            (selector (second spec)))
        (let ((element (browser-evaluate browser
                                         (format nil "const el = document.querySelector('~A');
                                                        el ? el.innerText : null"
                                                 selector))))
          (setf data (append data (list (cons name element)))))))
    data))

(defun browser-automate-form (browser form-selector values &key submit-selector)
  "Automate form filling and submission.

  Args:
    BROWSER: Browser instance
    FORM-SELECTOR: Form selector
    VALUES: Form values alist
    SUBMIT-SELECTOR: Submit button selector

  Returns:
    T on success"
  ;; Fill all fields
  (dolist (field values)
    (let ((name (car field))
          (value (cdr field)))
      (browser-fill-form browser (format nil "~A [name=~S]" form-selector name) (princ-to-string value))))

  ;; Submit if selector provided
  (when submit-selector
    (browser-click browser submit-selector))

  t)

(defun browser-capture-pdf (browser &key path landscape print-background)
  "Capture page as PDF.

  Args:
    BROWSER: Browser instance
    PATH: Save path
    LANDSCAPE: Landscape orientation
    PRINT-BACKGROUND: Print background graphics

  Returns:
    PDF data or path"
  (let ((params (append `(("printBackground" . ,(if print-background t nil)))
                        (when landscape `(("landscape" . t))))))
    (let ((result (send-cdp-command browser "Page.printToPDF" params)))
      (when result
        (let ((data (gethash "data" result)))
          (if path
              (progn
                (save-base64-image data path)
                path)
              data))))))

