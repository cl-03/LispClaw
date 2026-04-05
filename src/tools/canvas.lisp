;;; tools/canvas.lisp --- Canvas/A2UI Integration for Lisp-Claw
;;;
;;; This file implements Canvas/A2UI integration for rich UI rendering.
;;; A2UI (Agent-to-User Interface) provides structured UI components.

(defpackage #:lisp-claw.tools.canvas
  (:nicknames #:lc.tools.canvas)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   #:canvas-element
   #:make-canvas-element
   #:canvas-render
   #:canvas-to-html
   #:canvas-to-markdown
   #:canvas-send
   #:*canvas-registry*
   #:register-canvas-type
   #:render-canvas))

(in-package #:lisp-claw.tools.canvas)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *canvas-registry* (make-hash-table :test 'equal)
  "Registry of canvas element renderers.")

;;; ============================================================================
;;; Canvas Element Class
;;; ============================================================================

(defclass canvas-element ()
  ((type :initarg :type
         :reader canvas-type
         :documentation "Element type (text, image, code, etc.)")
   (content :initarg :content
            :accessor canvas-content
            :documentation "Element content")
   (props :initarg :props
          :initform nil
          :accessor canvas-props
          :documentation "Element properties")
   (children :initarg :children
             :initform nil
             :accessor canvas-children
             :documentation "Child elements"))
  (:documentation "A Canvas UI element"))

(defmethod print-object ((element canvas-element) stream)
  "Print canvas element representation."
  (print-unreadable-object (element stream :type t)
    (format stream "~A" (canvas-type element))))

(defun make-canvas-element (type content &rest props)
  "Create a canvas element.

  Args:
    TYPE: Element type keyword
    CONTENT: Element content
    PROPS: Additional properties

  Returns:
    Canvas-element instance"
  (make-instance 'canvas-element
                 :type type
                 :content content
                 :props props))

;;; ============================================================================
;;; Canvas Element Types
;;; ============================================================================

;; Text element
(defun canvas-text (text &key bold italic color size)
  "Create a text element.

  Args:
    TEXT: Text content
    BOLD: Bold text
    ITALIC: Italic text
    COLOR: Text color
    SIZE: Font size

  Returns:
    Canvas-element"
  (make-canvas-element :text text
                       :bold bold
                       :italic italic
                       :color color
                       :size size))

;; Image element
(defun canvas-image (url &key alt width height caption)
  "Create an image element.

  Args:
    URL: Image URL
    ALT: Alt text
    WIDTH: Image width
    HEIGHT: Image height
    CAPTION: Image caption

  Returns:
    Canvas-element"
  (make-canvas-element :image url
                       :alt alt
                       :width width
                       :height height
                       :caption caption))

;; Code block element
(defun canvas-code (code &key language title)
  "Create a code block element.

  Args:
    CODE: Code content
    LANGUAGE: Programming language
    TITLE: Code block title

  Returns:
    Canvas-element"
  (make-canvas-element :code code
                       :language language
                       :title title))

;; Button element
(defun canvas-button (label &key action style disabled)
  "Create a button element.

  Args:
    LABEL: Button label
    ACTION: Action identifier
    STYLE: Button style
    DISABLED: Whether disabled

  Returns:
    Canvas-element"
  (make-canvas-element :button label
                       :action action
                       :style style
                       :disabled disabled))

;; Input element
(defun canvas-input (&key type placeholder value on-change)
  "Create an input element.

  Args:
    TYPE: Input type (text, number, etc.)
    PLACEHOLDER: Placeholder text
    VALUE: Initial value
    ON-CHANGE: Change callback

  Returns:
    Canvas-element"
  (make-canvas-element :input nil
                       :type type
                       :placeholder placeholder
                       :value value
                       :on-change on-change))

;; Container element
(defun canvas-container (&rest children)
  "Create a container element.

  Args:
    CHILDREN: Child elements

  Returns:
    Canvas-element"
  (make-canvas-element :container nil
                       :children children))

;; Card element
(defun canvas-card (title content &key image footer)
  "Create a card element.

  Args:
    TITLE: Card title
    CONTENT: Card content
    IMAGE: Card image URL
    FOOTER: Card footer

  Returns:
    Canvas-element"
  (make-canvas-element :card content
                       :title title
                       :image image
                       :footer footer))

;; Table element
(defun canvas-table (headers rows &key sortable)
  "Create a table element.

  Args:
    HEADERS: List of column headers
    ROWS: List of row data (each row is a list)
    SORTABLE: Whether columns are sortable

  Returns:
    Canvas-element"
  (make-canvas-element :table nil
                       :headers headers
                       :rows rows
                       :sortable sortable))

;; Progress element
(defun canvas-progress (value &key max show-label)
  "Create a progress element.

  Args:
    VALUE: Current value
    MAX: Maximum value
    SHOW-LABEL: Show percentage label

  Returns:
    Canvas-element"
  (make-canvas-element :progress value
                       :max max
                       :show-label show-label))

;; Divider element
(defun canvas-divider ()
  "Create a divider element.

  Returns:
    Canvas-element"
  (make-canvas-element :divider nil))

;; Spacer element
(defun canvas-spacer (&key (size 16))
  "Create a spacer element.

  Args:
    SIZE: Spacer size in pixels

  Returns:
    Canvas-element"
  (make-canvas-element :spacer nil
                       :size size))

;;; ============================================================================
;;; Canvas Rendering
;;; ============================================================================

(defun register-canvas-type (type renderer)
  "Register a canvas type renderer.

  Args:
    TYPE: Type keyword
    RENDERER: Render function

  Returns:
    T"
  (setf (gethash (string-downcase type) *canvas-registry*) renderer)
  (log-debug "Registered canvas type: ~A" type)
  t)

(defun render-canvas (element format)
  "Render a canvas element to specified format.

  Args:
    ELEMENT: Canvas-element or list of elements
    FORMAT: Output format (:html, :markdown, :json)

  Returns:
    Rendered string"
  (cond
    ((listp element)
     ;; Render list of elements
     (case format
       (:html (format nil "~{~A~^~%}" (mapcar (lambda (e) (render-canvas e format)) element)))
       (:markdown (format nil "~{~A~%~%}" (mapcar (lambda (e) (render-canvas e format)) element)))
       (:json (stringify-json (mapcar (lambda (e) (canvas-to-json e)) element))))
     )
    ((eq format :json)
     (canvas-to-json element))
    ((eq format :html)
     (canvas-to-html element))
    ((eq format :markdown)
     (canvas-to-markdown element))
    (t
     (canvas-to-html element))))

(defun canvas-to-json (element)
  "Convert canvas element to JSON structure.

  Args:
    ELEMENT: Canvas-element

  Returns:
    JSON-compatible alist"
  `(("type" . ,(string-downcase (canvas-type element)))
    ("content" . ,(canvas-content element))
    ("props" . ,(canvas-props element))
    ("children" . ,(mapcar #'canvas-to-json (canvas-children element)))))

(defun canvas-to-html (element)
  "Convert canvas element to HTML.

  Args:
    ELEMENT: Canvas-element

  Returns:
    HTML string"
  (let ((type (canvas-type element))
        (content (canvas-content element))
        (props (canvas-props element))
        (children (canvas-children element)))
    (case type
      (:text
       (let ((tag (if (getf props :bold) "strong" "span"))
             (style (format nil "~@[color: ~A;~]~@[font-size: ~A;~]"
                            (getf props :color)
                            (getf props :size))))
         (format nil "<~A~@[ style=\"~A\"~]>~A</~A>"
                 tag (if (string= style "") nil style) content tag)))

      (:image
       (format nil "<figure~@[ class=\"canvas-image\"~]>
<img src=\"~A\"~@[ alt=\"~A\"~]~@[ width=\"~A\"~]~@[ height=\"~A\"~]>
~:[~;<figcaption>~A</figcaption>~]</figure>"
               content
               (getf props :alt)
               (getf props :width)
               (getf props :height)
               (getf props :caption)
               (getf props :caption)))

      (:code
       (format nil "<pre~@[ class=\"language-~A\"~]>~@[<code>~]~A~[/code]</pre>"
               (getf props :language)
               (getf props :title)
               content
               (if (getf props :title) "" "")))

      (:button
       (format nil "<button~@[ class=\"btn-~A\"~]~:[~; disabled=\"disabled\"~]>~A</button>"
               (getf props :style)
               (getf props :disabled)
               content))

      (:input
       (format nil "<input type=\"~A\"~@[ placeholder=\"~A\"~]~@[ value=\"~A\"~]>"
               (getf props :type "text")
               (getf props :placeholder)
               (getf props :value)))

      (:container
       (format nil "<div class=\"canvas-container\">~{~A~}</div>"
               (mapcar #'canvas-to-html children)))

      (:card
       (format nil "<div class=\"canvas-card\">~
                    ~@[<div class=\"card-title\">~A</div>~]~
                    ~@[<img src=\"~A\" class=\"card-image\">~]~
                    <div class=\"card-content\">~A</div>~
                    ~@[<div class=\"card-footer\">~A</div>~]</div>"
               (getf props :title)
               (getf props :image)
               content
               (getf props :footer)))

      (:table
       (format nil "<table class=\"canvas-table\">
<thead><tr>~{<th>~A</th>~}</tr></thead>
<tbody>~{<tr>~{<td>~A</td>~}</tr>~}</tbody>
</table>"
               (getf props :headers)
               (getf props :rows)))

      (:progress
       (let* ((value (or content 0))
              (max (or (getf props :max) 100))
              (percent (floor (* 100 (/ value max))))
              (label (when (getf props :show-label)
                       (format nil "~A%" percent))))
         (format nil "<div class=\"canvas-progress\"~@[ title=\"~A\"~]>
<div class=\"progress-bar\" style=\"width: ~A%\"></div>
~:[~;<span class=\"progress-label\">~A</span>~]</div>"
                 label percent label label)))

      (:divider
       "<hr class=\"canvas-divider\">")

      (:spacer
       (format nil "<div style=\"height: ~Apx\"></div>"
               (getf props :size 16)))

      (otherwise
       (log-warn "Unknown canvas type: ~A" type)
       (format nil "<span>~A</span>" content)))))

(defun canvas-to-markdown (element)
  "Convert canvas element to Markdown.

  Args:
    ELEMENT: Canvas-element

  Returns:
    Markdown string"
  (let ((type (canvas-type element))
        (content (canvas-content element))
        (props (canvas-props element))
        (children (canvas-children element)))
    (case type
      (:text
       (format nil "~@[**~]~A~@[**~]~@[_~A_~]"
               (getf props :bold)
               content
               (getf props :bold)
               (if (getf props :italic) content "")))

      (:image
       (format nil "~![~A](~A)~@[~%~A~]"
               (getf props :alt "")
               content
               (getf props :caption)))

      (:code
       (format nil "```~A~%~A~%```"
               (getf props :language "")
               content))

      (:button
       (format nil "[~A]" content))

      (:container
       (format nil "~{~A~^~%~}" (mapcar #'canvas-to-markdown children)))

      (:card
       (format nil "### ~A~%~%~A~%~%~@[~A~]"
               (getf props :title "")
               content
               (getf props :footer)))

      (:table
       (let ((headers (getf props :headers))
             (rows (getf props :rows)))
         (format nil "| ~{~A~^ | ~} |~%|~{---~^|---~}|~%~{~A~^~%~}"
                 headers
                 (loop for row in rows
                       collect (format nil "| ~{~A~^ | ~} |" row)))))

      (:divider
       "---")

      (:spacer
       "")

      (otherwise
       (princ-to-string content)))))

;;; ============================================================================
;;; Canvas Rendering to Channels
;;; ============================================================================

(defun canvas-send (channel element &key format)
  "Send canvas element to a channel.

  Args:
    CHANNEL: Channel instance
    ELEMENT: Canvas-element or list
    FORMAT: Preferred format (auto-detect if NIL)

  Returns:
    T on success"
  (let* ((channel-type (type-of channel))
         (format (or format
                     (cond
                       ((search "telegram" (string-downcase channel-type)) :html)
                       ((search "discord" (string-downcase channel-type)) :markdown)
                       ((search "slack" (string-downcase channel-type)) :markdown)
                       (t :html)))))
    (let ((rendered (render-canvas element format)))
      (log-debug "Sending canvas to ~A as ~A" channel-type format)
      ;; Use channel's send-message method
      (let ((send-fn (find-symbol (string-upcase "send-message") '#:lisp-claw.channels)))
        (when send-fn
          (funcall send-fn channel rendered)))
      t)))

;;; ============================================================================
;;; Built-in Renderers
;;; ============================================================================

(defun register-built-in-renderers ()
  "Register built-in canvas renderers.

  Returns:
    T"
  ;; Text renderer
  (register-canvas-type :text
    (lambda (element format)
      (case format
        (:html (canvas-to-html element))
        (:markdown (canvas-to-markdown element))
        (otherwise (canvas-content element)))))

  ;; Image renderer
  (register-canvas-type :image
    (lambda (element format)
      (case format
        (:html (canvas-to-html element))
        (:markdown (canvas-to-markdown element))
        (otherwise (canvas-content element)))))

  ;; Code renderer
  (register-canvas-type :code
    (lambda (element format)
      (case format
        (:html (canvas-to-html element))
        (:markdown (canvas-to-markdown element))
        (otherwise (canvas-content element)))))

  (log-info "Built-in canvas renderers registered")
  t)

;;; ============================================================================
;;; Tool Registration
;;; ============================================================================

(defun register-canvas-tools ()
  "Register canvas tools with the tool registry.

  Returns:
    T on success"
  (let ((tool-registry (symbol-value (find-symbol "*TOOL-REGISTRY*" '#:lisp-claw.agent.core))))
    (when tool-registry
      ;; canvas.render
      (setf (gethash "canvas.render" tool-registry)
            `(:handler ,(lambda (args)
                          (let ((elements (gethash "elements" args))
                                (format (gethash "format" args :html)))
                            (render-canvas elements (or format :html))))
              :description "Render canvas elements to HTML/Markdown"
              :parameters `(("type" . "object")
                            ("properties" . (("elements" . (("type" . "array")
                                                            ("description" . "Canvas elements to render"))
                                              ("format" . (("type" . "string")
                                                           ("description" . "Output format: html, markdown, json")
                                                           ("enum" . ("html" "markdown" "json")))))
                            ("required" . ("elements")))))

      ;; canvas.text
      (setf (gethash "canvas.text" tool-registry)
            `(:handler ,(lambda (args)
                          (let ((text (gethash "text" args))
                                (bold (gethash "bold" args))
                                (italic (gethash "italic" args)))
                            (canvas-text text :bold bold :italic italic)))
              :description "Create a text element"
              :parameters `(("type" . "object")
                            ("properties" . (("text" . (("type" . "string")
                                                        ("description" . "Text content"))
                                              ("bold" . (("type" . "boolean")
                                                         ("description" . "Bold text"))
                                              ("italic" . (("type" . "boolean")
                                                           ("description" . "Italic text"))))))))

      ;; canvas.image
      (setf (gethash "canvas.image" tool-registry)
            `(:handler ,(lambda (args)
                          (let ((url (gethash "url" args))
                                (alt (gethash "alt" args))
                                (caption (gethash "caption" args)))
                            (canvas-image url :alt alt :caption caption)))
              :description "Create an image element"
              :parameters `(("type" . "object")
                            ("properties" . (("url" . (("type" . "string")
                                                       ("description" . "Image URL"))
                                              ("alt" . (("type" . "string")
                                                        ("description" . "Alt text"))
                                              ("caption" . (("type" . "string")
                                                            ("description" . "Image caption"))))))))

      ;; canvas.code
      (setf (gethash "canvas.code" tool-registry)
            `(:handler ,(lambda (args)
                          (let ((code (gethash "code" args))
                                (language (gethash "language" args)))
                            (canvas-code code :language language)))
              :description "Create a code block element"
              :parameters `(("type" . "object")
                            ("properties" . (("code" . (("type" . "string")
                                                        ("description" . "Code content"))
                                              ("language" . (("type" . "string")
                                                             ("description" . "Programming language"))))))))

      ;; canvas.button
      (setf (gethash "canvas.button" tool-registry)
            `(:handler ,(lambda (args)
                          (let ((label (gethash "label" args))
                                (action (gethash "action" args)))
                            (canvas-button label :action action)))
              :description "Create a button element"
              :parameters `(("type" . "object")
                            ("properties" . (("label" . (("type" . "string")
                                                         ("description" . "Button label"))
                                              ("action" . (("type" . "string")
                                                           ("description" . "Action identifier")))))))))

    (log-info "Canvas tools registered")
    t))
