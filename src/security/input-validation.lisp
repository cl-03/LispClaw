;;; security/input-validation.lisp --- Input Validation System
;;;
;;; This file provides input validation and sanitization.

(defpackage #:lisp-claw.security.input-validation
  (:nicknames #:lc.sec.validation)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:cl-ppcre)
  (:export
   ;; Validation conditions
   #:validation-error
   #:validation-error-field
   #:validation-error-reason
   ;; Validation functions
   #:validate-input
   #:validate-string
   #:validate-email
   #:validate-url
   #:validate-json
   #:validate-integer
   #:validate-float
   #:validate-boolean
   #:validate-enum
   ;; Sanitization
   #:sanitize-html
   #:sanitize-sql
   #:sanitize-xss
   #:trim-input
   #:normalize-whitespace
   ;; Pattern validators
   #:validate-regex
   #:make-validator
   ;; Batch validation
   #:validate-fields
   #:validation-result
   #:validation-success-p
   #:validation-errors
   ;; Initialization
   #:initialize-validation-system))

(in-package #:lisp-claw.security.input-validation)

;;; ============================================================================
;;; Validation Conditions
;;; ============================================================================

(define-condition validation-error (error)
  ((field :initarg :field
          :reader validation-error-field
          :documentation "Field that failed validation")
   (reason :initarg :reason
           :reader validation-error-reason
           :documentation "Reason for failure"))
  (:report (lambda (condition stream)
             (format stream "Validation error for '~A': ~A"
                     (validation-error-field condition)
                     (validation-error-reason condition)))))

(defstruct validation-result
  (success t :type boolean)
  (errors nil :type list)
  (data nil :type t))

(defun validation-success-p (result)
  "Check if validation succeeded.

  Args:
    RESULT: Validation result

  Returns:
    T if successful"
  (validation-result-success result))

(defun validation-errors (result)
  "Get validation errors.

  Args:
    RESULT: Validation result

  Returns:
    List of errors"
  (validation-result-errors result))

;;; ============================================================================
;;; Core Validation
;;; ============================================================================

(defun validate-input (value type &key required min max pattern error-msg)
  "Validate an input value.

  Args:
    VALUE: Value to validate
    TYPE: Expected type (string, integer, float, boolean, email, url, json)
    REQUIRED: Whether value is required (default NIL)
    MIN: Minimum value/length
    MAX: Maximum value/length
    PATTERN: Regex pattern for strings
    ERROR-MSG: Custom error message

  Returns:
    Validation result

  Raises:
    VALIDATION-ERROR on failure"
  (handler-case
      (cond
        ;; Check required
        ((and required (or (null value) (equal value "")))
         (error 'validation-error
                :field (or error-msg "value")
                :reason "Value is required"))
        ;; Skip validation if nil and not required
        ((null value) t)
        ;; Type validation
        ((eq type 'string) (validate-string value :min min :max max :pattern pattern))
        ((eq type 'integer) (validate-integer value :min min :max max))
        ((eq type 'float) (validate-float value :min min :max max))
        ((eq type 'boolean) (validate-boolean value))
        ((eq type 'email) (validate-email value))
        ((eq type 'url) (validate-url value))
        ((eq type 'json) (validate-json value))
        (t (error 'validation-error
                  :field error-msg
                  :reason (format nil "Unknown type: ~A" type))))
    (validation-error (c)
      (make-validation-result
       :success nil
       :errors (list c)
       :data nil))))

(defun validate-string (value &key min max pattern)
  "Validate a string value.

  Args:
    VALUE: String to validate
    MIN: Minimum length
    MAX: Maximum length
    PATTERN: Regex pattern

  Returns:
    T if valid

  Raises:
    VALIDATION-ERROR on failure"
  (unless (stringp value)
    (error 'validation-error :field "value" :reason "Must be a string"))
  ;; Length checks
  (when (and min (< (length value) min))
    (error 'validation-error :field "value"
           :reason (format nil "Must be at least ~A characters" min)))
  (when (and max (> (length value) max))
    (error 'validation-error :field "value"
           :reason (format nil "Must be at most ~A characters" max)))
  ;; Pattern check
  (when (and pattern (not (cl-ppcre:scan pattern value)))
    (error 'validation-error :field "value"
           :reason (format nil "Must match pattern: ~A" pattern)))
  t)

(defun validate-integer (value &key min max)
  "Validate an integer value.

  Args:
    VALUE: Integer to validate
    MIN: Minimum value
    MAX: Maximum value

  Returns:
    T if valid

  Raises:
    VALIDATION-ERROR on failure"
  (unless (integerp value)
    (error 'validation-error :field "value" :reason "Must be an integer"))
  (when (and min (< value min))
    (error 'validation-error :field "value"
           :reason (format nil "Must be at least ~A" min)))
  (when (and max (> value max))
    (error 'validation-error :field "value"
           :reason (format nil "Must be at most ~A" max)))
  t)

(defun validate-float (value &key min max)
  "Validate a float value.

  Args:
    VALUE: Float to validate
    MIN: Minimum value
    MAX: Maximum value

  Returns:
    T if valid

  Raises:
    VALIDATION-ERROR on failure"
  (unless (realp value)
    (error 'validation-error :field "value" :reason "Must be a number"))
  (when (and min (< value min))
    (error 'validation-error :field "value"
           :reason (format nil "Must be at least ~A" min)))
  (when (and max (> value max))
    (error 'validation-error :field "value"
           :reason (format nil "Must be at most ~A" max)))
  t)

(defun validate-boolean (value)
  "Validate a boolean value.

  Args:
    VALUE: Value to validate

  Returns:
    T if valid boolean

  Raises:
    VALIDATION-ERROR on failure"
  (unless (member value '(t nil))
    (error 'validation-error :field "value" :reason "Must be a boolean"))
  t)

(defun validate-email (value)
  "Validate an email address.

  Args:
    VALUE: Email to validate

  Returns:
    T if valid

  Raises:
    VALIDATION-ERROR on failure"
  (let ((email-pattern "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"))
    (unless (and (stringp value) (cl-ppcre:scan email-pattern value))
      (error 'validation-error :field "email" :reason "Invalid email address"))
    t))

(defun validate-url (value)
  "Validate a URL.

  Args:
    VALUE: URL to validate

  Returns:
    T if valid

  Raises:
    VALIDATION-ERROR on failure"
  (let ((url-pattern "^https?://[a-zA-Z0-9.-]+(?:/[a-zA-Z0-9._~:/?#\\[\\]@!$&'()*+,;=-]*)?$"))
    (unless (and (stringp value) (cl-ppcre:scan url-pattern value))
      (error 'validation-error :field "url" :reason "Invalid URL"))
    t))

(defun validate-json (value)
  "Validate JSON.

  Args:
    VALUE: JSON string to validate

  Returns:
    Parsed JSON if valid

  Raises:
    VALIDATION-ERROR on failure"
  (unless (stringp value)
    (error 'validation-error :field "json" :reason "Must be a string"))
  (handler-case
      (let ((parsed (lisp-claw.utils.json:parse-json value)))
        (or parsed (error 'validation-error :field "json" :reason "Empty JSON")))
    (error ()
      (error 'validation-error :field "json" :reason "Invalid JSON format"))))

(defun validate-enum (value allowed)
  "Validate value is in allowed list.

  Args:
    VALUE: Value to validate
    ALLOWED: List of allowed values

  Returns:
    T if valid

  Raises:
    VALIDATION-ERROR on failure"
  (unless (member value allowed :test 'equal)
    (error 'validation-error :field "value"
           :reason (format nil "Must be one of: ~{~A~^, ~}" allowed)))
  t)

;;; ============================================================================
;;; Regex Validator
;;; ============================================================================

(defun validate-regex (value pattern &optional error-msg)
  "Validate string against regex pattern.

  Args:
    VALUE: String to validate
    PATTERN: Regex pattern
    ERROR-MSG: Optional custom error message

  Returns:
    T if valid

  Raises:
    VALIDATION-ERROR on failure"
  (unless (and (stringp value) (cl-ppcre:scan pattern value))
    (error 'validation-error
           :field "value"
           :reason (or error-msg (format nil "Must match pattern: ~A" pattern))))
  t)

(defun make-validator (pattern &key error-msg min max)
  "Create a reusable validator.

  Args:
    PATTERN: Regex pattern
    ERROR-MSG: Custom error message
    MIN: Minimum length
    MAX: Maximum length

  Returns:
    Validator function"
  (lambda (value)
    (when min
      (validate-string value :min min))
    (when max
      (validate-string value :max max))
    (validate-regex value pattern error-msg)))

;;; ============================================================================
;;; Sanitization
;;; ============================================================================

(defun sanitize-html (value)
  "Sanitize HTML by removing dangerous tags.

  Args:
    VALUE: HTML string

  Returns:
    Sanitized string"
  (when (null value)
    (return-from sanitize-html nil))
  (let ((result (copy-seq value)))
    ;; Remove script tags
    (setf result (cl-ppcre:regex-replace-all "<script[^>]*>.*?</script>" result "" :case-fold-mode t))
    ;; Remove style tags
    (setf result (cl-ppcre:regex-replace-all "<style[^>]*>.*?</style>" result "" :case-fold-mode t))
    ;; Remove event handlers
    (setf result (cl-ppcre:regex-replace-all "\\s+on\\w+\\s*=\\s*['\"][^'\"]*['\"]" result "" :case-fold-mode t))
    ;; Remove javascript: URLs
    (setf result (cl-ppcre:regex-replace-all "javascript:" result "" :case-fold-mode t))
    result))

(defun sanitize-xss (value)
  "Sanitize string to prevent XSS attacks.

  Args:
    VALUE: String to sanitize

  Returns:
    Sanitized string"
  (when (null value)
    (return-from sanitize-xss nil))
  (let ((result (copy-seq value)))
    ;; HTML entity encode dangerous characters
    (setf result (cl-ppcre:regex-replace-all "&" result "&amp;"))
    (setf result (cl-ppcre:regex-replace-all "<" result "&lt;"))
    (setf result (cl-ppcre:regex-replace-all ">" result "&gt;"))
    (setf result (cl-ppcre:regex-replace-all "\"" result "&quot;"))
    (setf result (cl-ppcre:regex-replace-all "'" result "&#39;"))
    result))

(defun sanitize-sql (value)
  "Sanitize string for SQL usage.

  Args:
    VALUE: String to sanitize

  Returns:
    Sanitized string"
  (when (null value)
    (return-from sanitize-sql nil))
  ;; Escape single quotes
  (cl-ppcre:regex-replace-all "'" value "''"))

(defun trim-input (value)
  "Trim whitespace from input.

  Args:
    VALUE: String to trim

  Returns:
    Trimmed string"
  (when (and value (stringp value))
    (string-trim '(#\Space #\Tab #\Newline #\Return) value)))

(defun normalize-whitespace (value)
  "Normalize whitespace in string.

  Args:
    VALUE: String to normalize

  Returns:
    Normalized string"
  (when (null value)
    (return-from normalize-whitespace nil))
  ;; Replace multiple whitespace with single space
  (cl-ppcre:regex-replace-all "\\s+" value " "))

;;; ============================================================================
;;; Batch Validation
;;; ============================================================================

(defun validate-fields (fields-spec data)
  "Validate multiple fields.

  Args:
    FIELDS-SPEC: Alist of (field-name . validation-spec)
    DATA: Alist of field values

  Returns:
    Validation result

  Example:
    (validate-fields
     '((:name . (:type string :required t :min 1 :max 100))
       (:email . (:type email :required t))
       (:age . (:type integer :min 0 :max 150)))
     '(:name \"John\" :email \"john@example.com\" :age 30))"
  (let ((errors nil)
        (validated-data nil))
    (dolist (spec fields-spec)
      (let* ((field (car spec))
             (fspec (cdr spec))
             (type (getf fspec :type))
             (required (getf fspec :required))
             (min (getf fspec :min))
             (max (getf fspec :max))
             (pattern (getf fspec :pattern))
             (error-msg (getf fspec :error-msg))
             (value (getf data field)))
        (handler-case
            (let ((result (validate-input value type
                                          :required required
                                          :min min
                                          :max max
                                          :pattern pattern
                                          :error-msg error-msg)))
              (when (validation-success-p result)
                (push (cons field value) validated-data)))
          (validation-error (e)
            (push e errors)))))
    (make-validation-result
     :success (null errors)
     :errors (nreverse errors)
     :data (nreverse validated-data))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-validation-system ()
  "Initialize the input validation system.

  Returns:
    T"
  (log-info "Input validation system initialized")
  t)
