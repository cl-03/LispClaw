;;; security/encryption.lisp --- API Key Encryption
;;;
;;; This file provides encrypted storage for API keys and secrets.

(defpackage #:lisp-claw.security.encryption
  (:nicknames #:lc.sec.encryption)
  (:use #:cl
        #:lisp-claw.utils.logging
        #:ironclad
        #:cl+ssl
        #:alexandria)
  (:shadow #:xor)
  (:export
   ;; Key encryption
   #:encrypt-key
   #:decrypt-key
   #:make-encrypted-key
   #:encrypted-key-p
   ;; Secret store
   #:secret-store
   #:make-secret-store
   #:store-secret
   #:get-secret
   #:delete-secret
   #:list-secrets
   ;; Master key
   #:*master-key*
   #:initialize-master-key
   #:derive-key-from-password
   ;; Utilities
   #:generate-random-key
   #:bytes-to-hex-string
   #:hex-string-to-bytes
   ;; Initialization
   #:initialize-encryption-system))

(in-package #:lisp-claw.security.encryption)

;;; ============================================================================
;;; Master Key
;;; ============================================================================

(defvar *master-key* nil
  "Master encryption key (kept in memory only).")

(defvar *master-key-file* nil
  "Path to encrypted master key file.")

(defun generate-random-key (&key (size 32))
  "Generate a random encryption key.

  Args:
    SIZE: Key size in bytes (default 32 for AES-256)

  Returns:
    Vector of random bytes"
  (let ((key (make-array size :element-type '(unsigned-byte 8))))
    (ironclad:random-data key)
    key))

(defun derive-key-from-password (password &key (salt nil) (iterations 100000))
  "Derive an encryption key from a password using PBKDF2.

  Args:
    PASSWORD: Password string
    SALT: Optional salt (generated if NIL)
    ITERATIONS: PBKDF2 iterations (default 100000)

  Returns:
    Values: key (32 bytes), salt (16 bytes)"
  (let* ((salt (or salt (generate-random-key :size 16)))
         (password-bytes (babel:string-to-octets password :encoding :utf-8))
         (key (pbkdf2-hmac password-bytes salt iterations 32 :sha256)))
    (values key salt)))

(defun initialize-master-key (&key password key-file)
  "Initialize the master encryption key.

  Args:
    PASSWORD: Password to derive key from
    KEY-FILE: Optional file to store encrypted key

  Returns:
    T on success"
  (cond
    ;; Derive from password
    (password
     (multiple-value-bind (key salt)
         (derive-key-from-password password)
       (setf *master-key* key)
       (when key-file
         (setf *master-key-file* key-file)
         ;; Store salt with encrypted key
         (with-open-file (out key-file :direction :output
                              :if-exists :supersede
                              :element-type '(unsigned-byte 8))
           (write-sequence salt out)
           (let ((encrypted (encrypt-key key key)))
             (write-sequence encrypted out))))
       (log-info "Master key derived from password")
       t))
    ;; Load from file
    (key-file
     (with-open-file (in key-file :direction :input
                         :element-type '(unsigned-byte 8))
       (let ((salt (make-array 16 :element-type '(unsigned-byte 8))))
         (read-sequence salt in)
         (multiple-value-bind (key _)
             (derive-key-from-password (read-password "Enter master password: ")
                                       :salt salt)
           (declare (ignore _))
           (setf *master-key* key)
           (setf *master-key-file* key-file)
           (log-info "Master key loaded from ~A" key-file)
           t))))
    (t (error "Either PASSWORD or KEY-FILE must be provided"))))

(defun read-password (prompt)
  "Read a password from user.

  Args:
    PROMPT: Prompt string

  Returns:
    Password string"
  (declare (ignore prompt))
  ;; Simplified - in real implementation would hide input
  (read-line))

;;; ============================================================================
;;; Key Encryption
;;; ============================================================================

(defun encrypt-key (key data)
  "Encrypt data using the master key.

  Args:
    KEY: Encryption key (or use *master-key*)
    DATA: Data to encrypt (octets)

  Returns:
    Encrypted data (octets with prepended IV)"
  (let* ((actual-key (or key *master-key*))
         (iv (generate-random-key :size 16))
         (cipher (make-instance 'aes-cbc-256))
         (padded-data (pkcs7-pad data)))
    (encrypt cipher actual-key iv padded-data)
    ;; Prepend IV to ciphertext
    (concatenate '(vector (unsigned-byte 8)) iv padded-data)))

(defun decrypt-key (key encrypted-data)
  "Decrypt data using the master key.

  Args:
    KEY: Decryption key (or use *master-key*)
    ENCRYPTED-DATA: Encrypted data (IV prepended to ciphertext)

  Returns:
    Decrypted data (octets)"
  (let* ((actual-key (or key *master-key*))
         (iv (subseq encrypted-data 0 16))
         (ciphertext (subseq encrypted-data 16))
         (cipher (make-instance 'aes-cbc-256))
         (decrypted (decrypt cipher actual-key iv ciphertext)))
    (pkcs7-unpad decrypted)))

(defun pkcs7-pad (data)
  "Apply PKCS7 padding to data.

  Args:
    DATA: Data to pad

  Returns:
    Padded data"
  (let* ((block-size 16)
         (pad-len (- block-size (mod (length data) block-size)))
         (padded (make-array (+ (length data) pad-len)
                            :element-type '(unsigned-byte 8))))
    (replace padded data)
    (fill padded pad-len :start (length data))
    padded))

(defun pkcs7-unpad (data)
  "Remove PKCS7 padding from data.

  Args:
    DATA: Padded data

  Returns:
    Unpadded data"
  (let ((pad-len (aref data (1- (length data)))))
    (subseq data 0 (- (length data) pad-len))))

(defun make-encrypted-key (key-string)
  "Encrypt a key string for storage.

  Args:
    KEY-STRING: Key to encrypt

  Returns:
    Encrypted key as hex string"
  (let* ((data (babel:string-to-octets key-string :encoding :utf-8))
         (encrypted (encrypt-key nil data)))
    (bytes-to-hex-string encrypted)))

(defun encrypted-key-p (key-string)
  "Check if a key string appears to be encrypted.

  Args:
    KEY-STRING: Key to check

  Returns:
    T if encrypted"
  (and (stringp key-string)
       (evenp (length key-string))
       (every (lambda (c) (find c "0123456789abcdef")) key-string)))

(defun decrypt-key-string (encrypted-hex)
  "Decrypt an encrypted key string.

  Args:
    ENCRYPTED-HEX: Encrypted key as hex string

  Returns:
    Decrypted key string"
  (let* ((encrypted (hex-string-to-bytes encrypted-hex))
         (decrypted (decrypt-key nil encrypted)))
    (babel:octets-to-string decrypted :encoding :utf-8)))

;;; ============================================================================
;;; Secret Store
;;; ============================================================================

(defclass secret-store ()
  ((secrets :initform (make-hash-table :test 'equal)
            :documentation "Encrypted secrets store"))
  (:documentation "Secure storage for secrets"))

(defun make-secret-store ()
  "Create a new secret store.

  Returns:
    New secret-store instance"
  (make-instance 'secret-store))

(defun store-secret (store name secret)
  "Store an encrypted secret.

  Args:
    STORE: Secret store instance
    NAME: Secret name
    SECRET: Secret value

  Returns:
    T"
  (let* ((data (babel:string-to-octets secret :encoding :utf-8))
         (encrypted (encrypt-key nil data)))
    (setf (gethash name (slot-value store 'secrets)) encrypted)
    (log-debug "Stored secret ~A" name)
    t))

(defun get-secret (store name)
  "Retrieve a decrypted secret.

  Args:
    STORE: Secret store instance
    NAME: Secret name

  Returns:
    Secret value or NIL"
  (let ((encrypted (gethash name (slot-value store 'secrets))))
    (when encrypted
      (let ((decrypted (decrypt-key nil encrypted)))
        (babel:octets-to-string decrypted :encoding :utf-8)))))

(defun delete-secret (store name)
  "Delete a secret.

  Args:
    STORE: Secret store instance
    NAME: Secret name

  Returns:
    T if secret existed"
  (when (gethash name (slot-value store 'secrets))
    (remhash name (slot-value store 'secrets))
    t))

(defun list-secrets (store)
  "List all secret names.

  Args:
    STORE: Secret store instance

  Returns:
    List of secret names"
  (let ((names nil))
    (maphash (lambda (k v)
               (declare (ignore v))
               (push k names))
             (slot-value store 'secrets))
    names))

;;; ============================================================================
;;; Utilities
;;; ============================================================================

(defun bytes-to-hex-string (bytes)
  "Convert bytes to hex string.

  Args:
    BYTES: Byte vector

  Returns:
    Hex string"
  (with-output-to-string (out)
    (loop for byte across bytes
          do (format out "~2,'0x" byte))))

(defun hex-string-to-bytes (hex-string)
  "Convert hex string to bytes.

  Args:
    HEX-STRING: Hex string

  Returns:
    Byte vector"
  (let ((len (length hex-string))
        (bytes (make-array (/ len 2) :element-type '(unsigned-byte 8))))
    (loop for i from 0 below (/ len 2)
          do (setf (aref bytes i)
                   (parse-integer hex-string
                                  :start (* i 2)
                                  :end (+ (* i 2) 2)
                                  :radix 16)))
    bytes))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-encryption-system (&key password key-file)
  "Initialize the encryption system.

  Args:
    PASSWORD: Master password
    KEY-FILE: Optional key file path

  Returns:
    T"
  (when (or password key-file)
    (initialize-master-key :password password :key-file key-file))
  (log-info "Encryption system initialized")
  t)
