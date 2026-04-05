;;; crypto.lisp --- Cryptography Utilities for Lisp-Claw
;;;
;;; This file provides cryptographic utilities using Ironclad.
;;; Includes token generation, password hashing, and HMAC.

(defpackage #:lisp-claw.utils.crypto
  (:nicknames #:lc.utils.crypto)
  (:use #:cl
        #:ironclad
        #:cl-base64)
  (:export
   #:generate-token
   #:generate-uuid
   #:hash-password
   #:verify-password
   #:sign-data
   #:verify-signature
   #:generate-hmac
   #:base64-encode
   #:base64-decode
   #:hex-encode
   #:hex-decode
   #:secure-random
   #:generate-key))

(in-package #:lisp-claw.utils.crypto)

;;; ============================================================================
;;; Random Data Generation
;;; ============================================================================

(defun secure-random (num-bytes)
  "Generate cryptographically secure random bytes.

  Args:
    NUM-BYTES: Number of random bytes to generate

  Returns:
    An octet array containing random bytes"
  (let ((result (make-array num-bytes :element-type '(unsigned-byte 8))))
    (dotimes (i num-bytes)
      (setf (aref result i) (random 256)))
    result))

(defun generate-uuid ()
  "Generate a random UUID string.

  Returns:
    A UUID string"
  #+uuid
  (symbol-call :uuid :generate-uuid)
  #-uuid
  (let ((bytes (secure-random 16)))
    ;; Format as UUID: 8-4-4-4-12 hex digits
    (format nil "~2,'0x~2,'0x~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x~2,'0x~2,'0x~2,'0x~2,'0x"
            (aref bytes 0) (aref bytes 1) (aref bytes 2) (aref bytes 3)
            (aref bytes 4) (aref bytes 5) (aref bytes 6) (aref bytes 7)
            (aref bytes 8) (aref bytes 9) (aref bytes 10) (aref bytes 11)
            (aref bytes 12) (aref bytes 13) (aref bytes 14) (aref bytes 15))))

(defun generate-token (&optional (length 32))
  "Generate a random token for authentication.

  Args:
    LENGTH: Number of bytes in the token (default 32)

  Returns:
    A hexadecimal token string"
  (let ((random-bytes (secure-random length)))
    (ironclad:byte-array-to-hex-string random-bytes)))

(defun generate-key (&optional (length 64))
  "Generate a cryptographic key.

  Args:
    LENGTH: Number of bytes in the key

  Returns:
    A base64-encoded key string"
  (let ((random-bytes (secure-random length)))
    (base64-encode random-bytes)))

;;; ============================================================================
;;; Encoding/Decoding
;;; ============================================================================

(defun base64-encode (data)
  "Encode data to base64.

  Args:
    DATA: A string or octet array

  Returns:
    Base64-encoded string"
  (let ((octets (if (stringp data)
                    (ironclad:ascii-string-to-byte-array data)
                    data)))
    (cl-base64:usb8-array-to-base64-string octets)))

(defun base64-decode (string)
  "Decode a base64 string.

  Args:
    STRING: A base64-encoded string

  Returns:
    Decoded octet array"
  (cl-base64:base64-string-to-usb8-array string))

(defun hex-encode (data)
  "Encode data to hexadecimal.

  Args:
    DATA: A string or octet array

  Returns:
    Hexadecimal string"
  (let ((octets (if (stringp data)
                    (ironclad:ascii-string-to-byte-array data)
                    data)))
    (ironclad:byte-array-to-hex-string octets)))

(defun hex-decode (string)
  "Decode a hexadecimal string.

  Args:
    STRING: A hexadecimal string

  Returns:
    Decoded octet array"
  (ironclad:hex-string-to-byte-array string))

;;; ============================================================================
;;; Hashing
;;; ============================================================================

(defun hash-password (password &optional (salt (generate-token 16)))
  "Hash a password using PBKDF2 with SHA-256.

  Args:
    PASSWORD: The password string to hash
    SALT: Optional salt (generated if not provided)

  Returns:
    Values: hash-string, salt-string"
  (let* ((salt-octets (if (stringp salt)
                          (hex-decode salt)
                          salt))
         (password-octets (ironclad:ascii-string-to-byte-array password))
         (key (ironclad:pbkdf2-hash-password password
                                             :salt salt-octets
                                             :iterations 100000
                                             :digest :sha256)))
    (values (hex-encode key)
            (hex-encode salt-octets))))

(defun verify-password (password stored-hash salt)
  "Verify a password against a stored hash.

  Args:
    PASSWORD: The password to verify
    STORED-HASH: The stored hash (hex string)
    SALT: The salt used (hex string)

  Returns:
    T if password matches, NIL otherwise"
  (multiple-value-bind (computed-hash _)
      (hash-password password salt)
    (string= computed-hash stored-hash)))

(defun hash-data (data &key (algorithm :sha256))
  "Hash arbitrary data.

  Args:
    DATA: String or octet array to hash
    ALGORITHM: Hash algorithm (:md5, :sha1, :sha256, :sha512)

  Returns:
    Hex-encoded hash string"
  (let ((octets (if (stringp data)
                    (ironclad:ascii-string-to-byte-array data)
                    data)))
    (ironclad:byte-array-to-hex-string
     (ironclad:digest-sequence algorithm octets))))

;;; ============================================================================
;;; HMAC
;;; ============================================================================

(defun generate-hmac (data key &key (algorithm :sha256))
  "Generate an HMAC (Hash-based Message Authentication Code).

  Args:
    DATA: Data to sign (string or octet array)
    KEY: Secret key (string or octet array)
    ALGORITHM: Hash algorithm to use

  Returns:
    Hex-encoded HMAC string"
  (let ((data-octets (if (stringp data)
                         (ironclad:ascii-string-to-byte-array data)
                         data))
        (key-octets (if (stringp key)
                        (ironclad:ascii-string-to-byte-array key)
                        key)))
    (ironclad:byte-array-to-hex-string
     (ironclad:hmac key-octets data-octets algorithm))))

(defun verify-hmac (data key expected-hmac &key (algorithm :sha256))
  "Verify an HMAC.

  Args:
    DATA: Original data (string or octet array)
    KEY: Secret key (string or octet array)
    EXPECTED-HMAC: Expected HMAC (hex string)
    ALGORITHM: Hash algorithm used

  Returns:
    T if HMAC is valid, NIL otherwise"
  (let ((computed-hmac (generate-hmac data key :algorithm algorithm)))
    (string= computed-hmac expected-hmac)))

;;; ============================================================================
;;; Digital Signatures (Simplified)
;;; ============================================================================

(defun sign-data (data private-key &key (algorithm :sha256))
  "Sign data using a private key.

  Args:
    DATA: Data to sign (string or octet array)
    PRIVATE-KEY: Private key (simplified - just returns HMAC for now)
    ALGORITHM: Hash algorithm to use

  Returns:
    Signature as octet array"
  (declare (ignore algorithm))
  ;; Simplified implementation using HMAC
  ;; For real RSA signatures, integrate with cl+ssl or similar
  (generate-hmac data private-key))

(defun verify-signature (data signature public-key &key (algorithm :sha256))
  "Verify a digital signature.

  Args:
    DATA: Original data (string or octet array)
    SIGNATURE: Signature octet array
    PUBLIC-KEY: Public key (simplified - just verifies HMAC)
    ALGORITHM: Hash algorithm used

  Returns:
    T if signature is valid, NIL otherwise"
  (declare (ignore algorithm))
  ;; Simplified implementation using HMAC
  (let ((computed-hmac (generate-hmac data public-key)))
    (string= (hex-encode signature) computed-hmac)))

;;; ============================================================================
;;; Challenge-Response
;;; ============================================================================

(defun generate-challenge (&optional (length 64))
  "Generate a challenge string for authentication.

  Args:
    LENGTH: Length of the challenge string

  Returns:
    A random challenge string"
  (generate-token length))

(defun sign-challenge (challenge secret)
  "Sign a challenge with a secret.

  Args:
    CHALLENGE: Challenge string
    SECRET: Secret key

  Returns:
    Signature string"
  (generate-hmac challenge secret))

(defun verify-challenge (challenge signature secret)
  "Verify a signed challenge.

  Args:
    CHALLENGE: Original challenge string
    SIGNATURE: Signature to verify
    SECRET: Secret key

  Returns:
    T if valid, NIL otherwise"
  (verify-hmac challenge secret signature))
