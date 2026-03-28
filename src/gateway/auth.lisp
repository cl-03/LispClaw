;;; auth.lisp --- Gateway Authentication for Lisp-Claw
;;;
;;; This file implements authentication and authorization
;;; for the Lisp-Claw gateway.

(defpackage #:lisp-claw.gateway.auth
  (:nicknames #:lc.gateway.auth)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.crypto)
  (:export
   #:*auth-mode*
   #:*auth-token*
   #:*device-store*
   #:auth-mode-p
   #:verify-token
   #:generate-device-token
   #:verify-device-signature
   #:create-device-pairing
   #:approve-device-pairing
   #:get-device-by-code
   #:device-paired-p))

(in-package #:lisp-claw.gateway.auth)

;;; ============================================================================
;;; Global Variables
;;; ============================================================================

(defvar *auth-mode* :token
  "Authentication mode: :none, :token, or :password.")

(defvar *auth-token* nil
  "Gateway authentication token.")

(defvar *device-store* (make-hash-table :test 'equal)
  "Store of paired devices.")

(defvar *pending-pairings* (make-hash-table :test 'equal)
  "Store of pending device pairings (code -> device-info).")

;;; ============================================================================
;;; Authentication Modes
;;; ============================================================================

(defun auth-mode-p (mode)
  "Check if the given mode matches current auth mode.

  Args:
    MODE: Mode keyword (:none, :token, :password)

  Returns:
    T if mode matches"
  (eq mode *auth-mode*))

(defun set-auth-mode (mode)
  "Set the authentication mode.

  Args:
    MODE: Mode keyword

  Returns:
    T on success"
  (when (member mode '(:none :token :password))
    (setf *auth-mode* mode)
    (log-info "Auth mode set to: ~A" mode)
    t))

(defun init-auth-token (&optional token)
  "Initialize or generate auth token.

  Args:
    TOKEN: Optional token (generated if NIL)

  Returns:
    The token"
  (setf *auth-token* (or token (generate-token 32)))
  (log-info "Auth token initialized")
  *auth-token*)

;;; ============================================================================
;;; Token Verification
;;; ============================================================================

(defun verify-token (token)
  "Verify an authentication token.

  Args:
    TOKEN: Token string to verify

  Returns:
    T if valid, NIL otherwise"
  (cond
    ((eq *auth-mode* :none)
     t)
    ((null token)
     nil)
    ((string= token *auth-token*)
     t)
    (t
     (log-warn "Invalid auth token attempt")
     nil)))

;;; ============================================================================
;;; Device Pairing
;;; ============================================================================

(defun generate-pairing-code (&optional (length 6))
  "Generate a device pairing code.

  Args:
    LENGTH: Code length (default 6)

  Returns:
    Pairing code string"
  (format nil "~V,'0d" length (random (expt 10 length))))

(defun create-device-pairing (device-info &optional (valid-seconds 300))
  "Create a new pending device pairing.

  Args:
    DEVICE-INFO: Device information alist
    VALID-SECONDS: How long the pairing code is valid (default 300s)

  Returns:
    Pairing code string"
  (let ((code (generate-pairing-code)))
    (setf (gethash code *pending-pairings*)
          (list :device-info device-info
                :created-at (get-universal-time)
                :expires-at (+ (get-universal-time) valid-seconds)))
    (log-info "Created pairing code: ~A" code)
    code))

(defun approve-device-pairing (code device-id)
  "Approve a pending device pairing.

  Args:
    CODE: Pairing code
    DEVICE-ID: Device ID to approve

  Returns:
    Device token if successful, NIL otherwise"
  (let* ((pairing (gethash code *pending-pairings*))
         (device-info (plist-get pairing :device-info))
         (expires-at (plist-get pairing :expires-at)))

    (unless pairing
      (log-warn "Pairing code not found: ~A" code)
      (return-from approve-device-pairing nil))

    (when (> (get-universal-time) expires-at)
      (log-warn "Pairing code expired: ~A" code)
      (remhash code *pending-pairings*)
      (return-from approve-device-pairing nil))

    ;; Generate device token
    (let ((device-token (generate-device-token device-id)))
      ;; Store paired device
      (setf (gethash device-id *device-store*)
            (append device-info
                    `(:token ,device-token
                      :paired-at ,(get-universal-time))))

      ;; Remove pending pairing
      (remhash code *pending-pairings*)

      (log-info "Device paired: ~A" device-id)
      device-token)))

(defun generate-device-token (device-id)
  "Generate a device token.

  Args:
    DEVICE-ID: Device identifier

  Returns:
    Device token string"
  (let ((token (generate-token 64)))
    ;; Store token hash for verification
    (setf (gethash (format nil "~A-token" device-id) *device-store*)
          (hash-data token :algorithm :sha256))
    token))

(defun verify-device-signature (device-id signature challenge)
  "Verify a device's signature on a challenge.

  Args:
    DEVICE-ID: Device identifier
    SIGNATURE: Signature to verify
    CHALLENGE: Original challenge

  Returns:
    T if valid, NIL otherwise"
  (let ((device (gethash device-id *device-store*)))
    (unless device
      (return-from verify-device-signature nil))

    ;; Get device secret (would be stored securely)
    (let ((device-secret (plist-get device :secret)))
      (when device-secret
        (verify-hmac challenge device-secret signature)))))

(defun get-device-by-code (code)
  "Get device info by pairing code.

  Args:
    CODE: Pairing code

  Returns:
    Device info or NIL"
  (let ((pairing (gethash code *pending-pairings*)))
    (when pairing
      (plist-get pairing :device-info))))

(defun device-paired-p (device-id)
  "Check if a device is paired.

  Args:
    DEVICE-ID: Device identifier

  Returns:
    T if paired, NIL otherwise"
  (and (gethash device-id *device-store*) t))

(defun get-device-token (device-id)
  "Get a device's token.

  Args:
    DEVICE-ID: Device identifier

  Returns:
    Device token or NIL"
  (let ((device (gethash device-id *device-store*)))
    (when device
      (plist-get device :token))))

(defun remove-device (device-id)
  "Remove a paired device.

  Args:
    DEVICE-ID: Device identifier

  Returns:
    T on success"
  (remhash device-id *device-store*)
  (log-info "Device removed: ~A" device-id)
  t)

(defun list-paired-devices ()
  "List all paired devices.

  Returns:
    List of device info alists"
  (loop for device-id being the hash-keys of *device-store*
        using (hash-value device)
        unless (string-suffix-p device-id "-token")
        collect (list :id device-id :info device)))

;;; ============================================================================
;;; Challenge-Response Auth
;;; ============================================================================

(defun generate-auth-challenge ()
  "Generate an authentication challenge.

  Returns:
    Challenge string"
  (generate-challenge 64))

(defun verify-auth-response (challenge response secret)
  "Verify an authentication response.

  Args:
    CHALLENGE: Original challenge
    RESPONSE: Response signature
    SECRET: Shared secret

  Returns:
    T if valid, NIL otherwise"
  (verify-challenge challenge response secret))

;;; ============================================================================
;;; Connect Authentication
;;; ============================================================================

(defun authenticate-connect (params)
  "Authenticate a connect request.

  Args:
    PARAMS: Connect parameters

  Returns:
    T if authenticated, signals error otherwise"
  (let ((auth-info (json-get params :auth)))
    (cond
      ;; No auth required
      ((eq *auth-mode* :none)
       t)

      ;; Token auth
      ((eq *auth-mode* :token)
       (let ((token (json-get auth-info :token)))
         (unless (verify-token token)
           (error 'auth-failed :message "Invalid token"))))

      ;; Device auth
      ((json-get auth-info :device-token)
       (let ((device-token (json-get auth-info :device-token))
             (device-id (json-get auth-info :device-id)))
         (unless (string= device-token (get-device-token device-id))
           (error 'auth-failed :message "Invalid device token"))))

      (t
       (error 'auth-failed :message "Authentication required"))))

  t)

;;; ============================================================================
;;; Conditions
;;; ============================================================================

(define-condition auth-failed (error)
  ((message :initarg :message :reader error-message))
  (:report (lambda (condition stream)
             (format stream "Authentication Failed: ~A"
                     (error-message condition)))))
