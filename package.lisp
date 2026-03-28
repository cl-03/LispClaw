;;; package.lisp --- Lisp-Claw Package Definition
;;;
;;; This file defines the main package for the Lisp-Claw system,
;;; a Common Lisp implementation of a personal AI assistant gateway.

(defpackage #:lisp-claw
  (:nicknames #:lc)
  (:use #:cl
        #:alexandria
        #:serapeum
        #:bordeaux-threads)
  ;; Export main classes
  (:export
   ;; Gateway classes
   #:gateway
   #:gateway-config
   #:client-connection
   #:node-connection

   ;; Channel classes
   #:channel
   #:channel-registry

   ;; Agent classes
   #:agent-session
   #:agent-config
   #:model-provider

   ;; Node classes
   #:node-manager
   #:device-node

   ;; Main functions
   #:make-gateway
   #:start-gateway
   #:stop-gateway
   #:gateway-run

   ;; Config functions
   #:load-config
   #:save-config
   #:get-config
   #:set-config

   ;; Channel functions
   #:register-channel
   #:unregister-channel
   #:send-message
   #:broadcast-message

   ;; Agent functions
   #:create-session
   #:destroy-session
   #:send-to-agent
   #:get-session-history

   ;; Node functions
   #:register-node
   #:invoke-node

   ;; Events
   #:subscribe-event
   #:unsubscribe-event
   #:emit-event

   ;; Conditions
   #:lisp-claw-error
   #:gateway-error
   #:channel-error
   #:agent-error
   #:config-error
   #:auth-error)

;;; ============================================================================
;;; Gateway Package
;;; ============================================================================

(defpackage #:lisp-claw.gateway
  (:nicknames #:lc.gateway)
  (:use #:cl
        #:lisp-claw
        #:alexandria
        #:bordeaux-threads)
  (:export
   #:*gateway*
   #:*gateway-port*
   #:make-gateway-server
   #:gateway-listen
   #:handle-websocket
   #:handle-http-request))

;;; ============================================================================
;;; Protocol Package
;;; ============================================================================

(defpackage #:lisp-claw.protocol
  (:nicknames #:lc.protocol)
  (:use #:cl
        #:alexandria)
  (:export
   ;; Protocol constants
   #:protocol-version
   #:frame-types

   ;; Frame types
   #:frame-request
   #:frame-response
   #:frame-event

   ;; Request methods
   #:method-connect
   #:method-health
   #:method-agent
   #:method-send
   #:method-node-invoke

   ;; Events
   #:event-agent
   #:event-chat
   #:event-presence
   #:event-health
   #:event-heartbeat
   #:event-cron

   ;; Frame parsing
   #:parse-frame
   #:make-frame
   #:validate-frame))

;;; ============================================================================
;;; Config Package
;;; ============================================================================

(defpackage #:lisp-claw.config
  (:nicknames #:lc.config)
  (:use #:cl
        #:alexandria)
  (:export
   #:*config-path*
   #:*default-config*
   #:load-config
   #:save-config
   #:get-config-value
   #:set-config-value
   #:merge-configs
   #:validate-config))

;;; ============================================================================
;;; Agent Package
;;; ============================================================================

(defpackage #:lisp-claw.agent
  (:nicknames #:lc.agent)
  (:use #:cl
        #:lisp-claw
        #:alexandria
        #:bordeaux-threads)
  (:export
   #:*agent-sessions*
   #:make-agent-session
   #:destroy-agent-session
   #:process-agent-request
   #:send-provider-request
   #:handle-tool-call))

;;; ============================================================================
;;; Channels Package
;;; ============================================================================

(defpackage #:lisp-claw.channels
  (:nicknames #:lc.channels)
  (:use #:cl
        #:lisp-claw
        #:alexandria
        #:bordeaux-threads)
  (:export
   #:channel
   #:make-channel
   #:connect-channel
   #:disconnect-channel
   #:channel-send-message
   #:channel-receive-message
   #:register-channel-handler
   #:unregister-channel-handler))

;;; ============================================================================
;;; Utils Package
;;; ============================================================================

(defpackage #:lisp-claw.utils
  (:nicknames #:lc.utils)
  (:use #:cl
        #:alexandria
        #:serapeum)
  (:export
   ;; Logging
   #:setup-logging
   #:log-debug
   #:log-info
   #:log-warn
   #:log-error

   ;; JSON helpers
   #:parse-json
   #:stringify-json
   #:json-get

   ;; Crypto helpers
   #:generate-token
   #:hash-password
   #:verify-signature

   ;; Time helpers
   #:now
   #:timestamp
   #:parse-timestamp))
