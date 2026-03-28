;;; crypto.lisp --- Cryptography Utilities for Lisp-Claw
;;;
;;; This file provides cryptographic utilities using Ironclad and cl+ssl.
;;; Includes token generation, password hashing, and signature verification.

(defpackage #:lisp-claw.utils.crypto
  (:nicknames #:lc.utils.crypto)
  (:use #:cl
        #:alexandria
        #:ironclad)
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
  (ironclad:make-random-salt :num-bytes num-bytes))

(defun generate-uuid ()
  "Generate a random UUID string.

  Returns:
    A UUID string (e.g., \"550e8400-e29b-41d4-a716-446655440000\")"
  #+uuid
  (symbol-call :uuid :generate-uuid)
  #-uuid
  (format nil "~36,'0x"
          (ironclad:octets-to-uint
           (secure-random 16) 0 16)))

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
    (ironclad:byte-array-to-base64-string octets)))

(defun base64-decode (string)
  "Decode a base64 string.

  Args:
    STRING: A base64-encoded string

  Returns:
    Decoded octet array"
  (ironclad:base64-string-to-byte-array string))

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
         (key (ironclad:pbkdf2-hash-password password-octets
                                             :salt salt-octets
                                             :iterations 100000
                                             :digest :sha256)))
    (values (hex-encode key)
            (hex-encode salt))))

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
;;; Digital Signatures (RSA)
;;; ============================================================================

(defun sign-data (data private-key &key (algorithm :sha256))
  "Sign data using RSA private key.

  Args:
    DATA: Data to sign (string or octet array)
    PRIVATE-KEY: RSA private key object
    ALGORITHM: Hash algorithm to use

  Returns:
    Signature as octet array

  Note: Requires loading the private key using ironclad or cl+ssl"
  (let ((data-octets (if (stringp data)
                         (ironclad:ascii-string-to-byte-array data)
                         data))
        (digest (ironclad:digest-sequence algorithm data-octets)))
    (ironclad:sign-message private-key digest)))

(defun verify-signature (data signature public-key &key (algorithm :sha256))
  "Verify a digital signature using RSA public key.

  Args:
    DATA: Original data (string or octet array)
    SIGNATURE: Signature octet array
    PUBLIC-KEY: RSA public key object
    ALGORITHM: Hash algorithm used

  Returns:
    T if signature is valid, NIL otherwise"
  (let ((data-octets (if (stringp data)
                         (ironclad:ascii-string-to-byte-array data)
                         data))
        (digest (ironclad:digest-sequence algorithm data-octets)))
    (ironclad:verify-signature public-key digest signature)))

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
