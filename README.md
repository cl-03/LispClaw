# LISP-Claw

Personal AI Assistant Gateway - A Common Lisp implementation inspired by OpenClaw

## Overview

LISP-Claw is a personal AI assistant gateway that you can run on your own devices. It provides a unified WebSocket interface for multiple messaging channels and AI providers.

**Inspired by:** [OpenClaw](https://github.com/openclaw/openclaw)

## Features

- **Multi-channel support**: Connect to WhatsApp, Telegram, Discord, Slack, and more
- **AI provider integration**: Support for Anthropic, OpenAI, Ollama, and other providers
- **WebSocket gateway**: Unified API for all clients and channels
- **Web Control Panel**: Manage gateway settings and monitor status
- **Web Chat Interface**: Browser-based chat with real-time messaging
- **Extensible architecture**: Plugin-based channel and tool system
- **Local-first**: Run everything on your own hardware

### Recently Implemented

- ✅ **Full WebSocket Implementation** - Complete RFC 6455 support with handshake, frames, ping/pong
- ✅ **Telegram Channel** - Bot API integration with long polling and message handling
- ✅ **Discord Channel** - Gateway WebSocket connection and event processing
- ✅ **Web Control UI** - Dashboard for gateway management at port 18790
- ✅ **WebChat Interface** - Real-time chat interface at port 18791

## Project Structure

```
LISP-Claw/
├── lisp-claw.asd              # ASDF system definition
├── package.lisp               # Package definitions
├── README.md                  # This file
├── QUICKSTART.md              # Quick start guide
├── PROJECT_SUMMARY.md         # Detailed project summary
├── Dockerfile                 # Docker build file
├── docker-compose.yml         # Docker Compose configuration
├── Makefile                   # Build automation
├── lisp-claw.sh               # CLI entry point
├── .gitignore                 # Git ignore rules
├── src/
│   ├── main.lisp              # Main entry point
│   ├── utils/
│   │   ├── logging.lisp       # Logging system
│   │   ├── json.lisp          # JSON utilities
│   │   ├── crypto.lisp        # Cryptography utilities
│   │   └── helpers.lisp       # General helpers
│   ├── config/
│   │   ├── schema.lisp        # Configuration schema
│   │   └── loader.lisp        # Configuration loader
│   ├── gateway/
│   │   ├── protocol.lisp      # WebSocket protocol
│   │   ├── server.lisp        # WebSocket server
│   │   ├── client.lisp        # Client management
│   │   ├── auth.lisp          # Authentication
│   │   ├── events.lisp        # Event system
│   │   └── health.lisp        # Health monitoring
│   ├── agent/
│   │   ├── session.lisp       # Session management
│   │   ├── models.lisp        # Model abstraction
│   │   ├── core.lisp          # Agent core
│   │   └── providers/
│   │       ├── base.lisp      # Provider base interface
│   │       ├── anthropic.lisp # Anthropic (Claude)
│   │       ├── openai.lisp    # OpenAI (GPT)
│   │       └── ollama.lisp    # Ollama (local models)
│   └── channels/
│       ├── base.lisp          # Channel base class
│       └── registry.lisp      # Channel registry
├── config/
│   └── lisp-claw.json.example # Example configuration
├── scripts/
│   └── docker-setup.sh        # Docker setup script
├── docs/
│   ├── DOCKER.md              # Docker deployment guide
│   └── DEPLOYMENT_STATUS.md   # Deployment status summary
└── tests/
    ├── package.lisp           # Test package definition
    ├── gateway-tests.lisp     # Gateway tests
    └── protocol-tests.lisp    # Protocol tests
```

## Requirements

- Common Lisp implementation (SBCL, CCL, or ECL recommended)
- Quicklisp for package management
- The following Quicklisp packages:
  - clack
  - hunchentoot
  - dexador
  - json-mop / joni
  - ironclad
  - bordeaux-threads
  - alexandria
  - serapeum
  - log4cl

## Installation

### Option 1: Docker (Recommended)

The easiest way to run Lisp-Claw is using Docker:

```bash
# Clone the repository
cd LISP-Claw

# Run the setup script
./scripts/docker-setup.sh

# Or manually with Docker Compose
docker compose up -d
```

See [docs/DOCKER.md](docs/DOCKER.md) for detailed Docker deployment instructions.

### Option 2: Local Installation

#### 1. Install Quicklisp (if not already installed)

```lisp
;; In your Lisp REPL
(require 'sb-bsd-sockets) ; or equivalent for your implementation
(load "quicklisp.lisp")
(quicklisp-quickstart:install)
(ql:add-to-init-file)
```

#### 2. Install dependencies

```lisp
(ql:quickload '(clack hunchentoot dexador json-mop joni
                    ironclad bordeaux-threads alexandria serapeum
                    log4cl cl-ppcre local-time uuid osicat))
```

#### 3. Load the system

```lisp
;; Add the project path to ASDF
(push #p"/path/to/LISP-Claw/" asdf:*central-registry*)

;; Load the system
(asdf:load-system :lisp-claw)
```

### Option 3: Using Make

```bash
# Install dependencies
make install

# Build the system
make build

# Run the gateway
make run
```

## Usage

### Basic usage

```lisp
;; Start the gateway
(lisp-claw:run)

;; Or with custom configuration
(lisp-claw:run :config #p"/path/to/config.json"
               :port 18789
               :bind "127.0.0.1")
```

### Using Docker

```bash
# Start the gateway
docker compose up -d

# View logs
docker compose logs -f lisp-claw-gateway

# Health check
curl http://127.0.0.1:18789/healthz
```

### Using CLI

```bash
# Start gateway
./lisp-claw.sh gateway --port 18789 --bind 0.0.0.0

# Start REPL
./lisp-claw.sh repl

# Health check
./lisp-claw.sh health --token your-token
```

### Configuration

Create a configuration file at `~/.lisp-claw/lisp-claw.json`:

```json
{
  "agent": {
    "model": "anthropic/claude-opus-4-6",
    "thinkingLevel": "medium"
  },
  "gateway": {
    "port": 18789,
    "bind": "127.0.0.1",
    "auth": {
      "mode": "token",
      "token": "your-secret-token"
    }
  },
  "channels": {
    "telegram": {
      "enabled": false,
      "botToken": null
    },
    "discord": {
      "enabled": false,
      "token": null
    }
  },
  "logging": {
    "level": "info",
    "file": null
  }
}
```

### WebSocket API

Connect to the gateway at `ws://127.0.0.1:18789/`:

```javascript
// Connect
{ "type": "req", "id": "1", "method": "connect", "params": { "type": "client" } }

// Health check
{ "type": "req", "id": "2", "method": "health" }

// Send message
{ "type": "req", "id": "3", "method": "send", "params": { "to": "+1234567890", "message": "Hello" } }
```

### Web Interfaces

- **Control Panel**: http://127.0.0.1:18790 - Gateway management dashboard
- **WebChat**: http://127.0.0.1:18791 - Browser-based chat interface

### Web Interface APIs

```bash
# Health check
curl http://127.0.0.1:18789/healthz

# Gateway status
curl http://127.0.0.1:18789/health

# Control UI API
curl http://127.0.0.1:18790/api/status
curl http://127.0.0.1:18790/api/channels
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Control Plane Clients                  │
│    (macOS app / CLI / Web UI / Automation / Nodes)      │
└────────────────────┬────────────────────────────────────┘
                     │ WebSocket (127.0.0.1:18789)
                     ▼
┌─────────────────────────────────────────────────────────┐
│                    Lisp-Claw Gateway                     │
│  ┌──────────┬──────────┬──────────┬──────────────────┐  │
│  │  Auth    │  Client  │  Events  │     Health       │  │
│  │  Manager │  Manager │  System  │    Monitoring    │  │
│  └──────────┴──────────┴──────────┴──────────────────┘  │
│                     │                                    │
│  ┌──────────────────┴────────────────────────────────┐  │
│  │              Channel Registry                      │  │
│  │  ┌────────┬────────┬────────┬────────┬─────────┐  │  │
│  │  │Telegram│Discord │ Slack  │WhatsApp│  ...    │  │  │
│  │  └────────┴────────┴────────┴────────┴─────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
│                     │                                    │
│  ┌──────────────────┴────────────────────────────────┐  │
│  │                Agent Core                          │  │
│  │  ┌─────────┬─────────┬─────────┬────────────────┐ │  │
│  │  │Anthropic│ OpenAI  │ Ollama  │     Tools      │ │  │
│  │  └─────────┴─────────┴─────────┴────────────────┘ │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## Development

### Running tests

```lisp
(asdf:test-system :lisp-claw)
```

### Building documentation

```bash
# TODO: Add documentation generation
```

## Roadmap

### Phase 1: Core Infrastructure (Completed)
- [x] Project structure
- [x] Configuration system
- [x] Logging utilities
- [x] WebSocket protocol definition
- [x] Gateway server skeleton
- [x] Docker deployment
- [x] CLI tools

### Phase 2: AI Integration (In Progress)
- [x] Agent core implementation
- [x] Anthropic provider
- [x] OpenAI provider
- [x] Ollama local models
- [ ] Full WebSocket implementation
- [ ] Tool calling framework

### Phase 3: Channels (In Progress)
- [x] Channel base class
- [ ] Telegram channel
- [ ] Discord channel
- [ ] Slack channel
- [ ] WhatsApp channel
- [ ] WebChat interface

### Phase 4: Features (Planned)
- [ ] Device nodes (macOS/iOS/Android)
- [ ] Cron automation
- [ ] Webhook triggers
- [ ] Canvas/A2UI rendering
- [ ] Voice interaction

## License

MIT License - See LICENSE file for details

## Acknowledgments

- [OpenClaw](https://github.com/openclaw/openclaw) - Original project that inspired this
- [Common Lisp Community](https://lisp-lang.org/) - For the amazing ecosystem

## Links

- [docs/DOCKER.md](docs/DOCKER.md) - Docker deployment guide
- [docs/DEPLOYMENT_STATUS.md](docs/DEPLOYMENT_STATUS.md) - Deployment status
- [docs/COMPLETION_SUMMARY.md](docs/COMPLETION_SUMMARY.md) - Project completion summary
