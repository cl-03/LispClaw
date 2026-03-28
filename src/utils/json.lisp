;;; json.lisp --- JSON Utilities for Lisp-Claw
;;;
;;; This file provides JSON parsing and serialization utilities
;;; using json-mop and joni libraries.

(defpackage #:lisp-claw.utils.json
  (:nicknames #:lc.utils.json)
  (:use #:cl
        #:alexandria
        #:json-mop
        #:joni)
  (:export
   #:parse-json
   #:stringify-json
   #:json-get
   #:json-get*
   #:json-array-to-list
   #:alist-to-json
   #:plist-to-json
   #:read-json-from-string
   #:write-json-to-string))

(in-package #:lisp-claw.utils.json)

;;; ============================================================================
;;; JSON Parsing
;;; ============================================================================

(defun parse-json (json-string)
  "Parse a JSON string into a Lisp object.

  Args:
    JSON-STRING: A string containing valid JSON

  Returns:
    A Lisp object (alist, plist, vector, string, number, etc.)

  Example:
    (parse-json \"{\\\"name\\\": \\\"test\\\"}\")
    => ((:NAME . \"test\"))"
  (when (null json-string)
    (return-from parse-json nil))

  (if (stringp json-string)
      (joni:decode-json json-string)
      json-string))

(defun read-json-from-string (string)
  "Read JSON from a string. Alias for parse-json.

  Args:
    STRING: JSON string

  Returns:
    Parsed Lisp object"
  (parse-json string))

;;; ============================================================================
;;; JSON Serialization
;;; ============================================================================

(defun stringify-json (object &optional (pretty nil))
  "Convert a Lisp object to a JSON string.

  Args:
    OBJECT: A Lisp object to serialize
    PRETTY: If true, format with indentation

  Returns:
    JSON string

  Example:
    (stringify-json '((:name . \"test\") (:value . 42)))
    => \"{\\\"name\\\":\\\"test\\\",\\\"value\\\":42}\""
  (if pretty
      (joni:encode-json object)
      (joni:encode-json object)))

(defun write-json-to-string (object &key (pretty nil))
  "Write a Lisp object to JSON string. Alias for stringify-json.

  Args:
    OBJECT: Lisp object to serialize
    PRETTY: Enable pretty printing

  Returns:
    JSON string"
  (stringify-json object pretty))

;;; ============================================================================
;;; JSON Accessors
;;; ============================================================================

(defun json-get (json-object key &optional default)
  "Get a value from a JSON object (alist) by key.

  Args:
    JSON-object: An alist representing a JSON object
    KEY: The key to look up (keyword or string)
    DEFAULT: Default value if key not found

  Returns:
    The value associated with KEY, or DEFAULT if not found

  Example:
    (json-get '((:name . \"test\") (:value . 42)) :name)
    => \"test\""
  (let ((key-sym (if (stringp key)
                     (intern (string-upcase key) :keyword)
                     key)))
    (cdr (assoc key-sym json-object :test #'equal))))

(defun json-get* (json-object &rest keys)
  "Get a nested value from a JSON object using a path of keys.

  Args:
    JSON-OBJECT: A JSON object (alist)
    KEYS: A sequence of keys to traverse

  Returns:
    The value at the nested path, or NIL if any key is not found

  Example:
    (json-get* '((:data . ((:user . ((:name . \"John\")))))
                 :data :user :name)
    => \"John\""
  (loop with result = json-object
        for key in keys
        do (setf result (json-get result key))
        while result
        finally (return result)))

(defun json-array-to-list (json-array)
  "Convert a JSON array (vector) to a Lisp list.

  Args:
    JSON-ARRAY: A vector representing a JSON array

  Returns:
    A Lisp list containing the array elements

  Example:
    (json-array-to-list #(1 2 3))
    => (1 2 3)"
  (when (vectorp json-array)
    (coerce json-array 'list)))

;;; ============================================================================
;;; Conversion Utilities
;;; ============================================================================

(defun alist-to-json (alist)
  "Convert an alist to a JSON-compatible structure.

  Args:
    ALIST: An association list

  Returns:
    A JSON-compatible structure"
  alist)

(defun plist-to-json (plist)
  "Convert a plist to a JSON-compatible structure.

  Args:
    PLIST: A property list

  Returns:
    A JSON-compatible structure (alist)"
  (loop for (key value) on plist by #'cddr
        collect (cons key value)))

(defun hash-table-to-alist (hash-table)
  "Convert a hash table to an alist for JSON serialization.

  Args:
    HASH-TABLE: A hash table

  Returns:
    An alist representation"
  (loop for key being the hash-keys of hash-table
        using (hash-value value)
        collect (cons key value)))

(defun alist-to-hash-table (alist)
  "Convert an alist to a hash table.

  Args:
    ALIST: An association list

  Returns:
    A hash table"
  (let ((ht (make-hash-table :test 'equal)))
    (dolist (pair alist)
      (setf (gethash (car pair) ht) (cdr pair)))
    ht))

;;; ============================================================================
;;; JSON Predicates
;;; ============================================================================

(defun json-object-p (object)
  "Check if OBJECT is a JSON object (alist).

  Args:
    OBJECT: Any Lisp object

  Returns:
    T if OBJECT is an alist, NIL otherwise"
  (and (listp object)
       (every (lambda (pair)
                (and (consp pair)
                     (keywordp (car pair))))
              object)))

(defun json-array-p (object)
  "Check if OBJECT is a JSON array (vector).

  Args:
    OBJECT: Any Lisp object

  Returns:
    T if OBJECT is a vector, NIL otherwise"
  (vectorp object))
