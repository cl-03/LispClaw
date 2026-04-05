;;; channels-tests.lisp --- Channels Tests for Lisp-Claw
;;;
;;; This file contains tests for the Lisp-Claw channels system.

(defpackage #:lisp-claw-tests.channels
  (:nicknames #:lc-tests.channels)
  (:use #:cl
        #:prove
        #:lisp-claw.channels.base
        #:lisp-claw.channels.registry
        #:lisp-claw.channels.telegram
        #:lisp-claw.channels.discord
        #:lisp-claw.channels.slack))

(in-package #:lisp-claw-tests.channels)

(defsuite test-channels "Channels tests")

;;; ============================================================================
;;; Channel Base Tests
;;; ============================================================================

(deftest test-channel-base-class "Channel base class"
  (let ((channel (make-instance 'channel :name "test-channel")))
    (ok channel)
    (is (string= (channel-name channel) "test-channel"))
    (is (eq (channel-status channel) :disconnected))
    (ok (not (channel-connected-p channel)))))

(deftest test-channel-connect-disconnect "Channel connect/disconnect"
  (let ((channel (make-instance 'channel :name "test-connect")))
    ;; Test connect
    (ok (channel-connect channel))
    (is (eq (channel-status channel) :connected))
    (ok (channel-connected-p channel))

    ;; Test disconnect
    (ok (channel-disconnect channel))
    (is (eq (channel-status channel) :disconnected))
    (ok (not (channel-connected-p channel)))))

;;; ============================================================================
;;; Channel Registry Tests
;;; ============================================================================

(deftest test-channel-registry "Channel registry operations"
  ;; Clear any existing channels
  (setf *channel-registry* (make-hash-table :test 'equal))

  (let ((channel (make-instance 'channel :name "registry-test")))
    ;; Register channel
    (ok (register-channel channel))

    ;; Get channel
    (is (eq (get-channel "registry-test") channel))

    ;; List channels
    (is (= (length (list-channels)) 1))

    ;; Unregister channel
    (ok (unregister-channel "registry-test"))
    (ok (not (get-channel "registry-test")))))

;;; ============================================================================
;;; Telegram Channel Tests
;;; ============================================================================

(deftest test-telegram-channel-creation "Telegram channel creation"
  (let ((channel (make-telegram-channel :name "test-telegram" :bot-token "test-token")))
    (ok channel)
    (is (typep channel 'telegram-channel))
    (is (string= (telegram-bot-token channel) "test-token"))))

;;; ============================================================================
;;; Discord Channel Tests
;;; ============================================================================

(deftest test-discord-channel-creation "Discord channel creation"
  (let ((channel (make-discord-channel :name "test-discord" :token "test-token")))
    (ok channel)
    (is (typep channel 'discord-channel))
    (is (string= (discord-token channel) "test-token"))))

;;; ============================================================================
;;; Slack Channel Tests
;;; ============================================================================

(deftest test-slack-channel-creation "Slack channel creation"
  (let ((channel (make-slack-channel :name "test-slack"
                                     :bot-token "xoxb-test-token"
                                     :app-token "xapp-test-token")))
    (ok channel)
    (is (typep channel 'slack-channel))
    (is (string= (slack-bot-token channel) "xoxb-test-token"))
    (is (string= (slack-app-token channel) "xapp-test-token"))))

;;; ============================================================================
;;; Run Channels Tests
;;; ============================================================================

(defun run-channels-tests ()
  "Run all channels tests.

  Returns:
    Test results"
  (prove:run #'test-channels))
