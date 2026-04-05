;;; schema.lisp --- Configuration Schema for Lisp-Claw
;;;
;;; This file defines the configuration schema for validation.

(defpackage #:lisp-claw.config.schema
  (:nicknames #:lc.config.schema)
  (:use #:cl)
  (:export
   #:*config-schema*
   #:schema-path-p
   #:get-schema-default
   #:validate-config-value))

(in-package #:lisp-claw.config.schema)

;;; ============================================================================
;;; Configuration Schema
;;; ============================================================================

(defvar *config-schema* nil
  "Configuration schema for validation.")

(defun init-config-schema ()
  "Initialize the configuration schema.

  Returns:
    T on success"
  (setf *config-schema*
        `((:agent (:type . object)
                  (:properties ((:model (:type . string)
                                        (:default . "anthropic/claude-opus-4-6"))
                                (:thinking-level (:type . string)
                                                 (:default . "medium"))
                                (:verbose-level (:type . string)
                                                (:default . "normal"))
                                (:workspace (:type . string)
                                            (:default . "~/.openclaw/workspace")))))
          (:gateway (:type . object)
                    (:properties ((:port (:type . integer)
                                       (:default . 18789))
                                  (:bind (:type . string)
                                         (:default . "127.0.0.1"))
                                  (:auth (:type . object)
                                         (:properties ((:mode (:type . string)
                                                              (:default . "token"))
                                                       (:token (:type . (or string null))
                                                               (:default . nil))
                                                       (:password (:type . (or string null))
                                                                  (:default . nil))))))))
          (:channels (:type . object)
                     (:properties ((:telegram (:type . object)
                                              (:properties ((:enabled (:type . boolean)
                                                                      (:default . nil))
                                                            (:bot-token (:type . (or string null))
                                                                        (:default . nil)))))
                                   (:discord (:type . object)
                                             (:properties ((:enabled (:type . boolean)
                                                                     (:default . nil))
                                                           (:token (:type . (or string null))
                                                                   (:default . nil)))))
                                   (:slack (:type . object)
                                           (:properties ((:enabled (:type . boolean)
                                                                   (:default . nil))
                                                         (:bot-token (:type . (or string null))
                                                                     (:default . nil))
                                                         (:app-token (:type . (or string null))
                                                                     (:default . nil))))))))
          (:browser (:type . object)
                    (:properties ((:enabled (:type . boolean)
                                            (:default . nil))
                                  (:profile (:type . (or string null))
                                            (:default . nil)))))
          (:logging (:type . object)
                    (:properties ((:level (:type . string)
                                          (:default . "info"))
                                  (:file (:type . (or string null))
                                         (:default . nil)))))))
  t)

;; Initialize schema on load
(init-config-schema)

;;; ============================================================================
;;; Schema Accessors
;;; ============================================================================

(defun schema-path-p (path)
  "Check if a path exists in the schema.

  Args:
    PATH: List of keys representing a path

  Returns:
    T if path exists, NIL otherwise"
  (let ((schema *config-schema*))
    (loop for key in path
          always (let ((found (assoc key schema :test #'equal)))
                   (when found
                     (setf schema (cdr found))))
          finally (return t))))

(defun get-schema-default (path)
  "Get the default value for a schema path.

  Args:
    PATH: List of keys representing a path

  Returns:
    Default value or NIL"
  (let ((schema *config-schema*))
    (loop for key in path
          for found = (assoc key schema :test #'equal)
          while found
          do (setf schema (cdr found))
          finally (return (if (and (listp schema) (assoc :default schema))
                              (cdr (assoc :default schema))
                              nil)))))

(defun validate-config-value (path value)
  "Validate a configuration value against the schema.

  Args:
    PATH: List of keys representing a path
    VALUE: Value to validate

  Returns:
    Values: (valid-p error-message)"
  (let ((schema *config-schema*))
    (loop for key in path
          for found = (assoc key schema :test #'equal)
          while found
          do (setf schema (cdr found))
          finally
          (if (null schema)
              (values nil "Path not found in schema")
              (let ((type (cdr (assoc :type schema))))
                (cond
                  ((null type) (values t nil))
                  ((eq type 'boolean)
                   (if (member value '(t nil))
                       (values t nil)
                       (values nil "Expected boolean")))
                  ((eq type 'string)
                   (if (stringp value)
                       (values t nil)
                       (values nil "Expected string")))
                  ((eq type 'integer)
                   (if (integerp value)
                       (values t nil)
                       (values nil "Expected integer")))
                  ((eq type 'array)
                   (if (listp value)
                       (values t nil)
                       (values nil "Expected array")))
                  ((eq type '(or string null))
                   (if (or (stringp value) (null value))
                       (values t nil)
                       (values nil "Expected string or null")))
                  (t (values t nil))))))))
