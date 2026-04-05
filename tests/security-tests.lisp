;;; security-tests.lisp --- Security Features Tests
;;;
;;; This file contains tests for security features (encryption, rate-limit, validation).

(defpackage #:lisp-claw-tests.security
  (:nicknames #:lc-tests.security)
  (:use #:cl
        #:prove
        #:lisp-claw.security.encryption
        #:lisp-claw.security.rate-limit
        #:lisp-claw.security.input-validation))

(in-package #:lisp-claw-tests.security)

(defsuite test-security "Security features tests")

;;; ============================================================================
;;; Encryption Tests
;;; ============================================================================

(deftest test-random-key-generation "Random key generation"
  (let ((key1 (generate-random-key :size 32))
        (key2 (generate-random-key :size 32)))
    (is (= (length key1) 32))
    (is (= (length key2) 32))
    ;; Keys should be different
    (ok (not (equalp key1 key2)))))

(deftest test-bytes-hex-conversion "Bytes/hex conversion"
  (let* ((bytes #(1 2 3 4 255 128))
         (hex (bytes-to-hex-string bytes))
         (converted-back (hex-string-to-bytes hex)))
    (is (string= hex "01020304ff80"))
    (ok (equalp bytes converted-back))))

(deftest test-encryption-decryption "Encryption/Decryption"
  ;; Generate a test key
  (let* ((key (generate-random-key :size 32))
         (data (babel:string-to-octets "Secret message"))
         (encrypted (encrypt-key key data))
         (decrypted (decrypt-key key encrypted)))
    ;; Encrypted should be different from original
    (ok (not (equalp encrypted data)))
    ;; Decrypted should match original
    (ok (equalp decrypted data))))

(deftest test-secret-store "Secret store"
  (let ((store (make-secret-store))
        (key (generate-random-key :size 32)))
    ;; Set master key for testing
    (setf *master-key* key)

    ;; Store secret
    (ok (store-secret store "api-key" "sk-test-12345"))

    ;; Retrieve secret
    (let ((secret (get-secret store "api-key")))
      (is (string= secret "sk-test-12345")))

    ;; Delete secret
    (ok (delete-secret store "api-key"))
    (ok (null (get-secret store "api-key")))))

;;; ============================================================================
;;; Rate Limit Tests
;;; ============================================================================

(deftest test-rate-limiter-creation "Rate limiter creation"
  (let ((limiter (make-rate-limiter :window 60 :limit 100)))
    (ok limiter)
    (is (= (rate-limiter-window limiter) 60))
    (is (= (rate-limiter-limit limiter) 100))))

(deftest test-rate-limit-checks "Rate limit checks"
  (let ((limiter (make-rate-limiter :window 60 :limit 5)))
    ;; First 5 requests should succeed
    (loop 5 times do
      (ok (check-rate-limit limiter "client-1")))

    ;; 6th request should fail
    (handler-case
        (check-rate-limit limiter "client-1")
      (rate-limit-exceeded (e)
        (ok e)
        (ok (> (rate-limit-retry-after e) 0))))))

(deftest test-rate-limit-status "Rate limit status"
  (let ((limiter (make-rate-limiter :window 60 :limit 100)))
    ;; Make some requests
    (check-rate-limit limiter "status-client")
    (check-rate-limit limiter "status-client")

    (let ((status (get-rate-limit-status limiter "status-client")))
      (is (= (getf status :limit) 100))
      (is (= (getf status :window) 60))
      (ok (getf status :remaining)))))

(deftest test-rate-limit-reset "Rate limit reset"
  (let ((limiter (make-rate-limiter :window 60 :limit 5)))
    ;; Make requests
    (loop 5 times do
      (check-rate-limit limiter "reset-client"))

    ;; Reset
    (ok (reset-rate-limit limiter "reset-client"))

    ;; Should be able to make requests again
    (ok (check-rate-limit limiter "reset-client"))))

(deftest test-token-bucket "Token bucket limiter"
  (let ((limiter (make-token-bucket-limiter :capacity 10 :refill-rate 1)))
    ;; First request should succeed
    (ok (check-token-bucket-limit limiter "bucket-client"))

    ;; Exhaust tokens
    (loop 10 times do
      (check-token-bucket-limit limiter "bucket-client"))

    ;; Next request should fail (no tokens left)
    (ok (not (check-token-bucket-limit limiter "bucket-client")))))

;;; ============================================================================
;;; Input Validation Tests
;;; ============================================================================

(deftest test-validate-string "String validation"
  (ok (validate-string "hello"))
  (ok (validate-string "hello" :min 1))
  (ok (validate-string "hello" :max 10))
  (ok (validate-string "hello" :min 1 :max 10))

  ;; Too short
  (handler-case
      (validate-string "hi" :min 5)
    (validation-error (e)
      (ok e)))

  ;; Too long
  (handler-case
      (validate-string "hello world" :max 5)
    (validation-error (e)
      (ok e))))

(deftest test-validate-integer "Integer validation"
  (ok (validate-integer 42))
  (ok (validate-integer 42 :min 0))
  (ok (validate-integer 42 :max 100))

  ;; Out of range
  (handler-case
      (validate-integer 10 :min 20)
    (validation-error (e)
      (ok e)))

  (handler-case
      (validate-integer 200 :max 100)
    (validation-error (e)
      (ok e))))

(deftest test-validate-email "Email validation"
  (ok (validate-email "test@example.com"))
  (ok (validate-email "user.name+tag@domain.co.uk"))

  ;; Invalid emails
  (handler-case
      (validate-email "not-an-email")
    (validation-error (e)
      (ok e)))

  (handler-case
      (validate-email "@example.com")
    (validation-error (e)
      (ok e))))

(deftest test-validate-url "URL validation"
  (ok (validate-url "https://example.com"))
  (ok (validate-url "http://localhost:8080/path"))

  ;; Invalid URLs
  (handler-case
      (validate-email "not-a-url")
    (validation-error (e)
      (ok e))))

(deftest test-validate-json "JSON validation"
  (ok (validate-json "{}"))
  (ok (validate-json "{\"key\": \"value\"}"))
  (ok (validate-json "[1, 2, 3]"))

  ;; Invalid JSON
  (handler-case
      (validate-json "{invalid}")
    (validation-error (e)
      (ok e))))

(deftest test-validate-regex "Regex validation"
  (ok (validate-regex "abc123" "^[a-z0-9]+$"))
  (ok (validate-regex "hello" "hello"))

  ;; Pattern doesn't match
  (handler-case
      (validate-regex "ABC" "^[a-z]+$")
    (validation-error (e)
      (ok e))))

(deftest test-sanitize-html "HTML sanitization"
  ;; Remove script tags
  (let ((clean (sanitize-html "<p>Hello</p><script>alert(1)</script>")))
    (ok (not (search "<script" clean :test 'char-equal))))

  ;; Remove event handlers
  (let ((clean (sanitize-html "<img src=\"x\" onerror=\"alert(1)\">")))
    (ok (not (search "onerror" clean :test 'char-equal))))

  ;; Remove javascript: URLs
  (let ((clean (sanitize-html "<a href=\"javascript:void(0)\">link</a>")))
    (ok (not (search "javascript:" clean :test 'char-equal))))

(deftest test-sanitize-xss "XSS sanitization"
  (let ((input "<script>alert('xss')</script>")
        (sanitized (sanitize-xss input)))
    ;; Should be HTML encoded
    (ok (search "&lt;" sanitized)))

(deftest test-trim-input "Trim input"
  (is (string= (trim-input "  hello  ") "hello"))
  (is (string= (trim-input "	test	") "test"))

(deftest test-validate-fields "Batch field validation"
  (let ((spec '((:name . (:type string :required t :min 1 :max 100))
                (:email . (:type email :required t))
                (:age . (:type integer :min 0 :max 150))))
        (valid-data '(:name "John" :email "john@example.com" :age 30))
        (invalid-data '(:name "" :email "not-email" :age 200)))

    ;; Valid data
    (let ((result (validate-fields spec valid-data)))
      (ok (validation-success-p result)))

    ;; Invalid data - should have errors
    (let ((result (validate-fields spec invalid-data)))
      (ok (not (validation-success-p result)))
      (ok (> (length (validation-errors result)) 0)))))

;;; ============================================================================
;;; Run Security Tests
;;; ============================================================================

(defun run-security-tests ()
  "Run all security features tests.

  Returns:
    Test results"
  (prove:run #'test-security))
