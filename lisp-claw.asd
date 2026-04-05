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
       (:file "loader")
       (:file "validator")))
     (:module "gateway"
      :serial t
      :pathname "gateway/"
      :components
      ((:file "protocol")
       (:file "auth")
       (:file "events")
       (:file "server")
       (:file "client")
       (:file "health")
       (:file "middleware")))
     (:module "agent"
      :serial t
      :pathname "agent/"
      :components
      ((:file "session")
       (:file "models")
       (:file "intents")
       (:file "workflows")
       (:file "router")
       (:module "providers"
        :serial t
        :pathname "providers/"
        :components
        ((:file "base")
         (:file "anthropic")
         (:file "openai")
         (:file "ollama")
         (:file "groq")
         (:file "xai")
         (:file "google")
         (:file "azure-openai")))
       (:file "core")))
     (:module "agents"
      :serial t
      :pathname "agents/"
      :components
      ((:file "workspace")))
     (:module "channels"
      :serial t
      :pathname "channels/"
      :components
      ((:file "base")
       (:file "registry")
       (:file "telegram")
       (:file "discord")
       (:file "slack")
       (:file "android")
       (:file "whatsapp")
       (:file "email")
       (:file "wechat")
       (:file "instant-messaging")
       (:file "im-web")))
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
       (:file "scheduler")
       (:file "webhook")
       (:file "task-queue")
       (:file "event-bus")))
     (:module "tools"
      :serial t
      :pathname "tools/"
      :components
      ((:file "registry")
       (:file "browser")
       (:file "files")
       (:file "system")
       (:file "image")
       (:file "shell")
       (:file "database")
       (:file "git")
       (:file "http-client")
       (:file "calendar")))
     (:module "advanced"
      :serial t
      :pathname "advanced/"
      :components
      ((:file "memory")
       (:file "cache")
       (:file "memory-compression")))
     (:module "security"
      :serial t
      :pathname "security/"
      :components
      ((:file "encryption")
       (:file "rate-limit")
       (:file "input-validation")
       (:file "audit")))
     (:module "voice"
      :serial t
      :pathname "voice/"
      :components
      ((:file "stt")
       (:file "tts")))
     (:module "vector"
      :serial t
      :pathname "vector/"
      :components
      ((:file "store")
       (:file "embeddings")
       (:file "chroma")
       (:file "index")
       (:file "search")
       (:file "qdrant")))
     (:module "mcp"
      :serial t
      :pathname "mcp/"
      :components
      ((:file "client")
       (:file "servers")
       (:file "tools-integration")
       (:file "server")))
     (:module "skills"
      :serial t
      :pathname "skills/"
      :components
      ((:file "registry")
       (:file "hub")))
     (:module "cli"
      :serial t
      :pathname "cli/"
      :components
      ((:file "cli")))
     (:module "agents"
      :serial t
      :pathname "agents/"
      :components
      ((:file "workspace")))
     (:module "plugins"
      :serial t
      :pathname "plugins/"
      :components
      ((:file "sdk")
       (:file "loader")))
     (:module "tui"
      :serial t
      :pathname "tui/"
      :components
      ((:file "main")))
     (:module "safety"
      :serial t
      :pathname "safety/"
      :components
      ((:file "sandbox")))
     (:module "nodes"
      :serial t
      :pathname "nodes/"
      :components
      ((:file "manager")))
     (:module "integrations"
      :serial t
      :pathname "integrations/"
      :components
      ((:file "n8n")
       (:file "cicd")
       (:file "ios")))
     (:module "monitoring"
      :serial t
      :pathname "monitoring/"
      :components
      ((:file "prometheus")))
     (:file "main")))))

(defsystem #:lisp-claw/tests
  :description "Tests for lisp-claw"
  :author "Your Name"
  :license "MIT"
  :depends-on (#:lisp-claw #:prove #:parachute)
  :pathname "tests/"
  :serial t
  :components
  ((:file "package")
   (:file "tools-tests")
   (:file "channels-tests")
   (:file "automation-tests")
   (:file "gateway-tests")
   (:file "protocol-tests")
   (:file "advanced-tests")
   (:file "security-tests")
   (:file "voice-tests")
   (:file "monitoring-tests")
   (:file "config-tests")
   (:file "vector-tests")
   (:file "task-queue-tests")
   (:file "event-bus-tests")))

;;; ============================================================================
;;; Individual Test Systems
;;; ============================================================================

(defsystem #:lisp-claw/tests/tools-tests
  :description "Tools tests for lisp-claw"
  :author "Your Name"
  :license "MIT"
  :depends-on (#:lisp-claw #:prove)
  :pathname "tests/"
  :components
  ((:file "tools-tests")))

(defsystem #:lisp-claw/tests/channels-tests
  :description "Channels tests for lisp-claw"
  :author "Your Name"
  :license "MIT"
  :depends-on (#:lisp-claw #:prove)
  :pathname "tests/"
  :components
  ((:file "channels-tests")))

(defsystem #:lisp-claw/tests/automation-tests
  :description "Automation tests for lisp-claw"
  :author "Your Name"
  :license "MIT"
  :depends-on (#:lisp-claw #:prove)
  :pathname "tests/"
  :components
  ((:file "automation-tests")))

(defsystem #:lisp-claw/tests/advanced-tests
  :description "Advanced features tests for lisp-claw"
  :author "Your Name"
  :license "MIT"
  :depends-on (#:lisp-claw #:prove)
  :pathname "tests/"
  :components
  ((:file "advanced-tests")))

(defsystem #:lisp-claw/tests/security-tests
  :description "Security features tests for lisp-claw"
  :author "Your Name"
  :license "MIT"
  :depends-on (#:lisp-claw #:prove)
  :pathname "tests/"
  :components
  ((:file "security-tests")))

(defsystem #:lisp-claw/tests/voice-tests
  :description "Voice processing tests for lisp-claw"
  :author "Your Name"
  :license "MIT"
  :depends-on (#:lisp-claw #:prove)
  :pathname "tests/"
  :components
  ((:file "voice-tests")))

