#!/usr/bin/env bash
# Lisp-Claw CLI Entry Point
# Usage: lisp-claw <command> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISP_CLAW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="0.1.0"

# Default values
PORT=18789
BIND="127.0.0.1"
CONFIG_FILE=""
VERBOSE=false

show_help() {
  cat <<EOF
Lisp-Claw AI Assistant Gateway v$VERSION

Usage: lisp-claw <command> [options]

Commands:
  gateway     Start the WebSocket gateway
  repl        Start interactive REPL
  health      Check gateway health
  version     Show version information
  help        Show this help message

Gateway Options:
  --port PORT       Gateway port (default: 18789)
  --bind ADDRESS    Bind address (default: 127.0.0.1)
  --config FILE     Configuration file path
  --verbose         Enable verbose output
  --daemon          Run as daemon

Examples:
  lisp-claw gateway --port 18789 --bind 0.0.0.0
  lisp-claw gateway --config ~/.lisp-claw/config.json
  lisp-claw health --token your-token
  lisp-claw repl

Environment Variables:
  LISP_CLAW_CONFIG_DIR    Config directory (default: ~/.lisp-claw)
  LISP_CLAW_GATEWAY_TOKEN Gateway auth token
  ANTHROPIC_API_KEY       Anthropic API key
  OPENAI_API_KEY          OpenAI API key

EOF
}

show_version() {
  echo "Lisp-Claw v$VERSION"
}

run_gateway() {
  local sbcl_args=(
    "--non-interactive"
    "--load" "$HOME/quicklisp/setup.lisp"
    "--eval" "(push #p\"$LISP_CLAW_DIR/\" asdf:*central-registry*)"
    "--eval" "(ql:quickload :lisp-claw)"
  )

  local lisp_args=""

  if [[ -n "$CONFIG_FILE" ]]; then
    lisp_args="$lisp_args :config #p\"$CONFIG_FILE\""
  fi

  if [[ "$PORT" != "18789" ]]; then
    lisp_args="$lisp_args :port $PORT"
  fi

  if [[ "$BIND" != "127.0.0.1" ]]; then
    lisp_args="$lisp_args :bind \"$BIND\""
  fi

  sbcl_args+=("--eval" "(lisp-claw.main:run$lisp_args)")

  exec sbcl "${sbcl_args[@]}"
}

run_repl() {
  exec sbcl \
    "--load" "$HOME/quicklisp/setup.lisp" \
    "--eval" "(push #p\"$LISP_CLAW_DIR/\" asdf:*central-registry*)" \
    "--eval" "(ql:quickload :lisp-claw)" \
    "--eval" "(lisp-claw.main:repl)"
}

check_health() {
  local token="${LISP_CLAW_GATEWAY_TOKEN:-}"
  local endpoint="http://127.0.0.1:$PORT/healthz"

  if curl -fsS "$endpoint" >/dev/null 2>&1; then
    echo "Gateway is healthy"
    exit 0
  else
    echo "Gateway health check failed"
    exit 1
  fi
}

# Parse command
if [[ $# -lt 1 ]]; then
  show_help
  exit 1
fi

COMMAND="$1"
shift

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    --bind)
      BIND="$2"
      shift 2
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --daemon)
      DAEMON=true
      shift
      ;;
    --token)
      LISP_CLAW_GATEWAY_TOKEN="$2"
      shift 2
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    --version|-v)
      show_version
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

# Execute command
case "$COMMAND" in
  gateway)
    run_gateway
    ;;
  repl)
    run_repl
    ;;
  health)
    check_health
    ;;
  version)
    show_version
    ;;
  help)
    show_help
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    show_help
    exit 1
    ;;
esac
