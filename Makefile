# Lisp-Claw Makefile
# Simplifies common development and deployment tasks

.PHONY: all help build test clean docker docker-build docker-run install reinstall

# Variables
IMAGE_NAME ?= lisp-claw:local
SBCL ?= sbcl
QUICKLISP_SETUP ?= $(HOME)/quicklisp/setup.lisp

# Default target
all: build

# Help target
help:
	@echo "Lisp-Claw Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  build          - Build the Lisp-Claw system"
	@echo "  test           - Run tests"
	@echo "  clean          - Clean build artifacts"
	@echo "  install        - Install Quicklisp dependencies"
	@echo "  repl           - Start interactive REPL"
	@echo "  run            - Run the gateway"
	@echo ""
	@echo "Docker targets:"
	@echo "  docker         - Build Docker image and start gateway"
	@echo "  docker-build   - Build Docker image"
	@echo "  docker-run     - Start Docker container"
	@echo "  docker-stop    - Stop Docker container"
	@echo "  docker-logs    - Show container logs"
	@echo "  docker-clean   - Remove Docker image"
	@echo ""
	@echo "Documentation targets:"
	@echo "  docs           - Generate documentation"
	@echo "  clean-docs     - Remove generated documentation"

# Build the system
build:
	$(SBCL) --non-interactive \
		--load $(QUICKLISP_SETUP) \
		--eval "(push #p\"$(shell pwd)/\" asdf:*central-registry*)" \
		--eval "(ql:quickload :lisp-claw)"

# Run tests
test:
	$(SBCL) --non-interactive \
		--load $(QUICKLISP_SETUP) \
		--eval "(push #p\"$(shell pwd)/\" asdf:*central-registry*)" \
		--eval "(ql:quickload :lisp-claw-tests)" \
		--eval "(asdf:test-system :lisp-claw)"

# Clean build artifacts
clean:
	find . -name "*.fasl" -delete
	find . -name "*.lib" -delete
	find . -name "*.core" -delete
	rm -rf .cache/
	rm -rf docs/_build/
	@echo "Cleaned build artifacts"

# Install dependencies
install:
	$(SBCL) --non-interactive \
		--load $(QUICKLISP_SETUP) \
		--eval "(ql:quickload '(clack hunchentoot dexador json-mop joni ironclad bordeaux-threads alexandria serapeum log4cl cl-ppcre local-time uuid osicat cl-dbi cl+ssl prove parachute))"

# Start REPL
repl:
	$(SBCL) --load $(QUICKLISP_SETUP) \
		--eval "(push #p\"$(shell pwd)/\" asdf:*central-registry*)" \
		--eval "(ql:quickload :lisp-claw)" \
		--eval "(lisp-claw.main:repl)"

# Run the gateway
run:
	$(SBCL) --non-interactive \
		--load $(QUICKLISP_SETUP) \
		--eval "(push #p\"$(shell pwd)/\" asdf:*central-registry*)" \
		--eval "(ql:quickload :lisp-claw)" \
		--eval "(lisp-claw.main:run :port 18789 :bind \"127.0.0.1\")"

# Docker: Build and start
docker: docker-build docker-run

# Docker: Build image
docker-build:
	docker build -t $(IMAGE_NAME) .

# Docker: Run container
docker-run:
	docker compose up -d lisp-claw-gateway

# Docker: Stop container
docker-stop:
	docker compose down

# Docker: Show logs
docker-logs:
	docker compose logs -f lisp-claw-gateway

# Docker: Clean image
docker-clean:
	docker rmi $(IMAGE_NAME) 2>/dev/null || true
	docker compose down -v

# Docker: Rebuild from scratch
docker-rebuild: docker-clean docker-build

# Documentation
docs:
	@echo "Generating documentation..."
	@mkdir -p docs/_build
	@echo "Documentation generation not yet implemented"

# Clean documentation
clean-docs:
	rm -rf docs/_build/*

# Development: Load system in development mode
dev:
	$(SBCL) --load $(QUICKLISP_SETUP) \
		--eval "(push #p\"$(shell pwd)/\" asdf:*central-registry*)" \
		--eval "(ql:quickload :lisp-claw :verbose t)"

# Check code style (if linters available)
lint:
	@echo "Running code linters..."
	@echo "Linting not yet implemented"

# Format code (if formatters available)
format:
	@echo "Formatting code..."
	@echo "Formatting not yet implemented"

# Quick start for new users
quickstart: install build
	@echo ""
	@echo "Lisp-Claw is ready!"
	@echo "Run 'make run' to start the gateway"
	@echo "Or 'make docker' to use Docker"
