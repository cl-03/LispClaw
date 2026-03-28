#!/bin/bash
# Lisp-Claw Test Runner
# This script runs the Lisp-Claw test suite

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

echo "========================================"
echo "Lisp-Claw Test Suite"
echo "========================================"
echo ""

# Check if SBCL is available
if ! command -v sbcl &> /dev/null; then
    echo "ERROR: SBCL is not installed or not in PATH"
    exit 1
fi

echo "SBCL Version:"
sbcl --version
echo ""

# Check if Quicklisp is installed
QUICKLISP_SETUP="$HOME/quicklisp/setup.lisp"
if [ ! -f "$QUICKLISP_SETUP" ]; then
    echo "WARNING: Quicklisp not found at $QUICKLISP_SETUP"
    echo "Installing Quicklisp..."

    # Download Quicklisp
    curl -o /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp

    # Install Quicklisp
    sbcl --non-interactive \
         --load /tmp/quicklisp.lisp \
         --eval '(quicklisp-quickstart:install)' \
         --eval '(quit)'

    QUICKLISP_SETUP="$HOME/quicklisp/setup.lisp"
fi

echo "Running tests..."
echo ""

# Run tests
sbcl --non-interactive \
     --load "$QUICKLISP_SETUP" \
     --eval "(push #p\"$PROJECT_DIR/\" asdf:*central-registry*)" \
     --eval "(ql:quickload :lisp-claw-tests :verbose t)" \
     --eval "(asdf:test-system :lisp-claw)" \
     --eval "(quit)"

echo ""
echo "========================================"
echo "Tests Complete"
echo "========================================"
