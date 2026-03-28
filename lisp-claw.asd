;;; lisp-claw.asd --- Personal AI Assistant Gateway
;;;
;;; Follows the architecture of OpenClaw but implemented in pure Common Lisp.
;;; Provides a WebSocket gateway for multi-channel AI assistant.

(defsystem #:lisp-claw
  :description "Personal AI Assistant Gateway - A Common Lisp implementation of an AI assistant similar to OpenClaw"
  :author "Your Name"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#:clack
               #:hunchentoot
               #:dexador
               #:json-mop
               #:ironclad
               #:cl+ssl
               #:cl-dbi
               #:bordeaux-threads
               #:alexandria
               #:serapeum
               #:log4cl
               #:cl-ppcre
               #:local-time
               #:uuid
               #:uiop
               #:split-sequence
               #:babel)
  :serial t
  :pathname #p"D:/Claude/LISP-Claw/LISP-Claw/"
  :components
  ((:file "package")
   (:module "src"
    :serial t
    :pathname "src/"
    :components
    ((:module "utils"
      :serial t
      :pathname "utils/"
      :components
      ((:file "logging")
       (:file "json")
       (:file "crypto")
       (:file "helpers")))
     (:module "config"
      :serial t
      :pathname "config/"
      :components
      ((:file "schema")
       (:file "loader")))
     (:module "gateway"
      :serial t
      :pathname "gateway/"
      :components
      ((:file "protocol")
       (:file "server")
       (:file "client")
       (:file "auth")
       (:file "events")
       (:file "health")))
     (:module "agent"
      :serial t
      :pathname "agent/"
      :components
      ((:file "session")
       (:file "models")
       (:file "core")
       (:module "providers"
        :serial t
        :pathname "providers/"
        :components
        ((:file "base")
         (:file "anthropic")
         (:file "openai")
         (:file "ollama")))))
     (:module "channels"
      :serial t
      :pathname "channels/"
      :components
      ((:file "base")
       (:file "registry")
       (:file "telegram")
       (:file "discord")))
     (:module "nodes"
      :serial t
      :pathname "nodes/"
      :components
      ((:file "manager")))
     (:module "web"
      :serial t
      :pathname "web/"
      :components
      ((:file "control-ui")
       (:file "webchat")))
     (:module "automation"
      :serial t
      :pathname "automation/"
      :components
      ((:file "cron")
       (:file "webhook")))))
   (:file "main")))

(defsystem #:lisp-claw-tests
  :description "Tests for lisp-claw"
  :author "Your Name"
  :license "MIT"
  :depends-on (#:lisp-claw #:prove #:parachute)
  :pathname "tests/"
  :components
  ((:file "package")
   (:file "gateway-tests")
   (:file "protocol-tests")))
