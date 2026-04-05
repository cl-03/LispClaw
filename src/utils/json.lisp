;;; json.lisp --- JSON Utilities for Lisp-Claw
;;;
;;; This file provides JSON parsing and serialization utilities
;;; using yason library.

(defpackage #:lisp-claw.utils.json
  (:nicknames #:lc.utils.json)
  (:use #:cl
        #:alexandria)
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

;; Simple JSON parser using built-in functions
;; This is a minimal implementation that avoids external library dependencies

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
      (with-input-from-string (s json-string)
        (read-json-from-stream s))
      json-string))

(defun read-json-from-stream (stream)
  "Read JSON from a stream.

  Args:
    STREAM: Input stream

  Returns:
    Parsed Lisp object"
  (let ((char (peek-char nil stream nil nil)))
    (cond
      ((null char) nil)
      ((char= char #\{) (read-json-object stream))
      ((char= char #\[) (read-json-array stream))
      ((char= char #\") (read-json-string stream))
      ((or (digit-char-p char) (char= char #\-)) (read-json-number stream))
      ((char= char #\t) (read-json-true stream))
      ((char= char #\f) (read-json-false stream))
      ((char= char #\n) (read-json-null stream))
      (t (error "Unexpected character: ~A" char)))))

(defun read-json-object (stream)
  "Read a JSON object from stream.

  Args:
    STREAM: Input stream

  Returns:
    Alist representing the JSON object"
  (read-char stream) ; consume {
  (skip-whitespace stream)
  (when (eq (peek-char nil stream nil nil) #\})
    (read-char stream)
    (return-from read-json-object nil))

  (let ((pairs nil))
    (loop
      (skip-whitespace stream)
      (let* ((key (read-json-key stream))
             (value (progn
                      (skip-whitespace stream)
                      (read-char stream) ; consume :
                      (skip-whitespace stream)
                      (read-json-from-stream stream))))
        (push (cons key value) pairs))
      (skip-whitespace stream)
      (let ((next (peek-char nil stream nil nil)))
        (cond
          ((char= next #\,)
           (read-char stream))
          ((char= next #\})
           (read-char stream)
           (return))
          (t (error "Expected , or } in JSON object")))))
    (nreverse pairs)))

(defun read-json-array (stream)
  "Read a JSON array from stream.

  Args:
    STREAM: Input stream

  Returns:
    Vector representing the JSON array"
  (read-char stream) ; consume [
  (skip-whitespace stream)
  (when (eq (peek-char nil stream nil nil) #\])
    (read-char stream)
    (return-from read-json-array #()))

  (let ((elements nil))
    (loop
      (push (read-json-from-stream stream) elements)
      (skip-whitespace stream)
      (let ((next (peek-char nil stream nil nil)))
        (cond
          ((char= next #\,)
           (read-char stream))
          ((char= next #\])
           (read-char stream)
           (return))
          (t (error "Expected , or ] in JSON array")))))
    (coerce (nreverse elements) 'vector)))

(defun read-json-string (stream)
  "Read a JSON string from stream.

  Args:
    STREAM: Input stream

  Returns:
    String value"
  (read-char stream) ; consume opening "
  (with-output-to-string (out)
    (loop
      (let ((ch (read-char stream nil nil)))
        (when (null ch)
          (error "Unterminated string"))
        (cond
          ((char= ch #\\)
           (let ((escaped (read-char stream)))
             (case escaped
               (#\" (write-char #\" out))
               (#\\ (write-char #\\ out))
               (#\/ (write-char #\/ out))
               (#\b (write-char #\backspace out))
               (#\f (write-char #\page out))
               (#\n (write-char #\newline out))
               (#\r (write-char #\return out))
               (#\t (write-char #\tab out))
               (#\u ; Unicode escape
                (let ((code (make-string 4)))
                  (dotimes (i 4)
                    (setf (char code i) (read-char stream)))
                  (write-char (code-char (parse-integer code :radix 16)) out)))
               (otherwise (write-char escaped out)))))
          ((char= ch #\")
           (return))
          (t
           (write-char ch out)))))))

(defun read-json-number (stream)
  "Read a JSON number from stream.

  Args:
    STREAM: Input stream

  Returns:
    Number value"
  (with-output-to-string (out)
    (when (eq (peek-char nil stream) #\-)
      (write-char (read-char stream) out))
    (loop
      (let ((ch (peek-char nil stream nil nil)))
        (when (or (null ch) (not (digit-char-p ch)))
          (return))
        (write-char (read-char stream) out))))
  (let* ((str (get-output-stream-string out))
         (num (or (parse-integer str :junk-allowed t)
                  (read-from-string str))))
    num))

(defun read-json-key (stream)
  "Read a JSON object key from stream.

  Args:
    STREAM: Input stream

  Returns:
    Keyword symbol"
  (let ((str (read-json-string stream)))
    (intern (string-upcase str) :keyword)))

(defun read-json-true (stream)
  "Read JSON true literal.

  Args:
    STREAM: Input stream

  Returns:
    T"
  (dotimes (i 4) (read-char stream)) ; consume true
  t)

(defun read-json-false (stream)
  "Read JSON false literal.

  Args:
    STREAM: Input stream

  Returns:
    NIL"
  (dotimes (i 5) (read-char stream)) ; consume false
  nil)

(defun read-json-null (stream)
  "Read JSON null literal.

  Args:
    STREAM: Input stream

  Returns:
    NIL"
  (dotimes (i 4) (read-char stream)) ; consume null
  nil)

(defun skip-whitespace (stream)
  "Skip whitespace characters in stream.

  Args:
    STREAM: Input stream"
  (loop
    (let ((ch (peek-char nil stream nil nil)))
      (when (or (null ch) (not (member ch '(#\space #\tab #\newline #\return))))
        (return)))
    (read-char stream)))

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
  (with-output-to-string (stream)
    (write-json-to-stream object stream pretty)))

(defun write-json-to-stream (object stream &optional (pretty nil) (indent 0))
  "Write JSON to stream.

  Args:
    OBJECT: Lisp object
    STREAM: Output stream
    PRETTY: Pretty print flag
    INDENT: Current indentation level"
  (cond
    ((null object) (write-string "null" stream))
    ((eq object t) (write-string "true" stream))
    ((eq object nil) (write-string "null" stream))
    ((numberp object) (princ object stream))
    ((stringp object) (write-json-string object stream))
    ((vectorp object) (write-json-array object stream pretty indent))
    ((listp object) (write-json-object object stream pretty indent))
    ((keywordp object) (write-json-string (string-downcase object) stream))
    (t (write-json-string (princ-to-string object) stream))))

(defun write-json-to-string (object &key (pretty nil))
  "Write a Lisp object to JSON string. Alias for stringify-json.

  Args:
    OBJECT: Lisp object to serialize
    PRETTY: Enable pretty printing

  Returns:
    JSON string"
  (stringify-json object pretty))

(defun write-json-string (str stream)
  "Write a string as JSON.

  Args:
    STR: String value
    STREAM: Output stream"
  (write-char #\" stream)
  (loop for ch across str
        do (case ch
             (#\" (write-string "\\\"" stream))
             (#\\ (write-string "\\\\" stream))
             (#\backspace (write-string "\\b" stream))
             (#\page (write-string "\\f" stream))
             (#\newline (write-string "\\n" stream))
             (#\return (write-string "\\r" stream))
             (#\tab (write-string "\\t" stream))
             (otherwise (write-char ch stream))))
  (write-char #\" stream))

(defun write-json-object (alist stream &optional (pretty indent))
  "Write an alist as JSON object.

  Args:
    ALIST: Association list
    STREAM: Output stream
    PRETTY: Pretty print flag
    INDENT: Indentation level"
  (write-char #\{ stream)
  (let ((first t))
    (dolist (pair alist)
      (unless first
        (write-char #\, stream))
      (setf first nil)
      (when pretty
        (format stream "~%~VT" (+ indent 2)))
      (write-json-string (string-downcase (car pair)) stream)
      (write-char #\: stream)
      (when pretty (write-char #\space stream))
      (write-json-to-stream (cdr pair) stream pretty (+ indent 2))))
  (when (and pretty (not (null alist)))
    (format stream "~%~VT" indent))
  (write-char #\} stream))

(defun write-json-array (vector stream &optional (pretty indent))
  "Write a vector as JSON array.

  Args:
    VECTOR: Vector
    STREAM: Output stream
    PRETTY: Pretty print flag
    INDENT: Indentation level"
  (write-char #\[ stream)
  (let ((first t))
    (dotimes (i (length vector))
      (unless first
        (write-char #\, stream))
      (setf first nil)
      (when pretty
        (format stream "~%~VT" (+ indent 2)))
      (write-json-to-stream (aref vector i) stream pretty (+ indent 2))))
  (when (and pretty (plusp (length vector)))
    (format stream "~%~VT" indent))
  (write-char #\] stream))

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
    (or (cdr (assoc key-sym json-object :test #'equal))
        default)))

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
