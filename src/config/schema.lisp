;;; schema.lisp --- Configuration Schema for Lisp-Claw
;;;
;;; This file defines the configuration schema and validation rules.

(defpackage #:lisp-claw.config.schema
  (:nicknames #:lc.config.schema)
  (:use #:cl
        #:alexandria)
  (:export
   #:config-schema
   #:validate-schema
   #:get-schema-default
   #:get-schema-type
   #:schema-path-p))

(in-package #:lisp-claw.config.schema)

;;; ============================================================================
;;; Configuration Schema
;;; ============================================================================

(defvar *config-schema*
  '((:agent . ((:type . object)
               (:properties . ((:model . ((:type . string)
                                          (:default . "anthropic/claude-opus-4-6")))
                               (:thinking-level . ((:type . string)
                                                   (:enum . ("off" "minimal" "low" "medium" "high" "xhigh")
                                                   (:default . "medium")))
                               (:verbose-level . ((:type . string)
                                                  (:enum . ("off" "normal" "full")
                                                  (:default . "normal")))
                               (:workspace . ((:type . string)
                                              (:default . "~/.openclaw/workspace")))))))
    (:gateway . ((:type . object)
                 (:properties . ((:port . ((:type . integer)
                                           (:min . 1)
                                           (:max . 65535)
                                           (:default . 18789)))
                                 (:bind . ((:type . string)
                                           (:enum . ("127.0.0.1" "0.0.0.0" "::1" "::"))
                                           (:default . "127.0.0.1")))
                                 (:auth . ((:type . object)
                                           (:properties . ((:mode . ((:type . string)
                                                                      (:enum . ("none" "token" "password"))
                                                                      (:default . "token")))
                                                           (:token . ((:type . (or string null))
                                                                      (:default . nil)))
                                                           (:password . ((:type . (or string null))
                                                                         (:default . nil)))
                                                           (:allow-tailscale . ((:type . boolean)
                                                                                (:default . t)))))))
                                 (:tailscale . ((:type . object)
                                                 (:properties . ((:mode . ((:type . string)
                                                                            (:enum . ("off" "serve" "funnel"))
                                                                            (:default . "off")))
                                                                 (:reset-on-exit . ((:type . boolean)
                                                                                    (:default . nil))))))))))
    (:channels . ((:type . object)
                  (:properties . ((:whatsapp . ((:type . object)
                                                 (:properties . ((:enabled . ((:type . boolean)
                                                                              (:default . nil))
                                                              (:allow-from . ((:type . array)
                                                                              (:default . ()))))))))
                                  (:telegram . ((:type . object)
                                                 (:properties . ((:enabled . ((:type . boolean)
                                                                              (:default . nil))
                                                              (:bot-token . ((:type . (or string null))
                                                                             (:default . nil)))
                                                              (:allow-from . ((:type . array)
                                                                              (:default . ()))))))))
                                  (:discord . ((:type . object)
                                                (:properties . ((:enabled . ((:type . boolean)
                                                                             (:default . nil))
                                                            (:token . ((:type . (or string null))
                                                                       (:default . nil)))
                                                            (:dm-policy . ((:type . string)
                                                                           (:enum . ("pairing" "open"))
                                                                           (:default . "pairing"))))))
                                  (:slack . ((:type . object)
                                              (:properties . ((:enabled . ((:type . boolean)
                                                                           (:default . nil))
                                                          (:bot-token . ((:type . (or string null))
                                                                         (:default . nil)))
                                                          (:app-token . ((:type . (or string null))
                                                                         (:default . nil)))))))))))
    (:browser . ((:type . object)
                 (:properties . ((:enabled . ((:type . boolean)
                                              (:default . nil)))
                                 (:profile . ((:type . (or string null))
                                              (:default . nil)))
                                 (:color . ((:type . string)
                                            (:default . "#FF4500")))))))
    (:logging . ((:type . object)
                 (:properties . ((:level . ((:type . string)
                                            (:enum . ("debug" "info" "warn" "error")
                                            (:default . "info")))
                                 (:file . ((:type . (or string null))
                                           (:default . nil)))
                                 (:pattern . ((:type . string)
                                              (:default . "[%-5p %d{HH:mm:ss}] %m%n")))))))))

;;; ============================================================================
;;; Schema Accessors
;;; ============================================================================

(defun schema-path-p (path)
  "Check if a path exists in the schema.

  Args:
    PATH: List of keys representing a path

  Returns:
    T if path exists in schema, NIL otherwise"
  (loop with current = *config-schema*
        for key in path
        do (let ((found (assoc key current :test #'equal)))
             (unless found
               (return-from schema-path-p nil))
             (let ((props (assoc :properties (cdr found))))
               (if props
                   (setf current (cdr props))
                   (setf current nil)))))
        finally (return t)))

(defun get-schema-default (path)
  "Get the default value for a schema path.

  Args:
    PATH: List of keys representing a path

  Returns:
    Default value or NIL if not found"
  (loop with current = *config-schema*
        for key in path
        for schema-node = nil
        do (let ((found (assoc key current :test #'equal)))
             (unless found
               (return-from get-schema-default nil))
             (setf schema-node (cdr found))
             (let* ((props (assoc :properties schema-node))
                    (next-key (car (last path))))
               (if (equal key next-key)
                   ;; This is the final key, return default
                   (return-from get-schema-default
                     (cdr (assoc :default schema-node))))
               (if props
                   (setf current (cdr props))
                   (return-from get-schema-default nil))))))

(defun get-schema-type (path)
  "Get the type for a schema path.

  Args:
    PATH: List of keys representing a path

  Returns:
    Type specification or NIL if not found"
  (loop with current = *config-schema*
        for key in path
        for schema-node = nil
        do (let ((found (assoc key current :test #'equal)))
             (unless found
               (return-from get-schema-type nil))
             (setf schema-node (cdr found))
             (let* ((props (assoc :properties schema-node))
                    (next-key (car (last path))))
               (if (equal key next-key)
                   ;; This is the final key, return type
                   (return-from get-schema-type
                     (cdr (assoc :type schema-node))))
               (if props
                   (setf current (cdr props))
                   (return-from get-schema-type nil))))))

;;; ============================================================================
;;; Schema Validation
;;; ============================================================================

(defun validate-schema (config &optional (schema *config-schema*) (path nil))
  "Validate a configuration against the schema.

  Args:
    CONFIG: Configuration to validate
    SCHEMA: Schema to validate against (default: *config-schema*)
    PATH: Current path for error reporting

  Returns:
    Values: (valid-p errors)
    - valid-p: T if config is valid
    - errors: List of error messages"
  (let ((errors nil))
    (dolist (pair config)
      (let ((key (car pair))
            (value (cdr pair))
            (current-path (append path (list key))))
        (let ((schema-entry (assoc key schema :test #'equal)))
          (when schema-entry
            (let* ((schema-props (cdr schema-entry))
                   (expected-type (cdr (assoc :type schema-props))))
              ;; Type validation
              (when expected-type
                (unless (type_matches_p value expected-type)
                  (push (format nil "~{~A.~} has wrong type: expected ~A, got ~A"
                                current-path expected-type (type-of value))
                        errors)))

              ;; Enum validation
              (let ((enum-values (cdr (assoc :enum schema-props))))
                (when enum-values
                  (unless (member value enum-values :test #'equal)
                    (push (format nil "~{~A.~} must be one of: ~{~A~^, ~}"
                                  current-path enum-values)
                          errors))))

              ;; Range validation
              (let ((min-val (cdr (assoc :min schema-props)))
                    (max-val (cdr (assoc :max schema-props))))
                (when (and (numberp value) min-val)
                  (when (< value min-val)
                    (push (format nil "~{~A.~} must be >= ~A" current-path min-val)
                          errors)))
                (when (and (numberp value) max-val)
                  (when (> value max-val)
                    (push (format nil "~{~A.~} must be <= ~A" current-path max-val)
                          errors))))

              ;; Nested object validation
              (when (and (eq expected-type 'object)
                         (alist-p value))
                (let ((nested-props (cdr (assoc :properties schema-props))))
                  (when nested-props
                    (multiple-value-bind (nested-valid nested-errors)
                        (validate-schema value nested-props current-path)
                      (declare (ignore nested-valid))
                      (setf errors (nconc errors nested-errors)))))))))))
    (values (null errors) (nreverse errors))))

(defun type_matches_p (value expected-type)
  "Check if a value matches an expected type.

  Args:
    VALUE: Value to check
    EXPECTED-TYPE: Type specification

  Returns:
    T if type matches, NIL otherwise"
  (case expected-type
    (string (stringp value))
    (integer (integerp value))
    (number (numberp value))
    (boolean (typep value 'boolean))
    (array (or (vectorp value) (listp value)))
    (object (alist-p value))
    (null (null value))
    (otherwise t)))

(defun alist-p (x)
  "Check if X is an association list.

  Args:
    X: Any object

  Returns:
    T if X is an alist, NIL otherwise"
  (and (listp x)
       (every (lambda (elem)
                (and (consp elem)
                     (keywordp (car elem))))
              x)))
