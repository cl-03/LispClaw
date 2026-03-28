# syntax=docker/dockerfile:1.7
# Lisp-Claw Dockerfile - Multi-stage build for minimal runtime image

ARG SBCL_VERSION="2.4.11"
ARG DEBIAN_VERSION="bookworm"

# ── Stage 1: Build ──────────────────────────────────────────────
FROM debian:${DEBIAN_VERSION} AS build

ARG SBCL_VERSION
ARG DEBIAN_VERSION

# Install build dependencies
RUN --mount=type=cache,id=lisp-claw-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=lisp-claw-apt-lists,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        sbcl \
        make \
        git \
        curl \
        ca-certificates \
        gnupg2 \
        && rm -rf /var/lib/apt/lists/*

# Install Quicklisp
RUN curl -o /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp && \
    sbcl --non-interactive \
         --load /tmp/quicklisp.lisp \
         --eval '(quicklisp-quickstart:install :path "/root/quicklisp")' && \
    rm /tmp/quicklisp.lisp

ENV PATH="/root/quicklisp:${PATH}"
ENV QL_SETUP="/root/quicklisp/setup.lisp"

WORKDIR /build

# Copy Lisp source files
COPY lisp-claw.asd ./
COPY package.lisp ./
COPY src/ ./src/
COPY tests/ ./tests/
COPY config/ ./config/

# Install Quicklisp dependencies and build fasls
RUN sbcl --non-interactive \
         --load /root/quicklisp/setup.lisp \
         --eval '(ql:quickload :lisp-claw :verbose t)' \
         --eval '(quit)'

# ── Stage 2: Runtime ────────────────────────────────────────────
FROM debian:${DEBIAN_VERSION}

# Install runtime dependencies
RUN --mount=type=cache,id=lisp-claw-rt-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=lisp-claw-rt-apt-lists,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        sbcl \
        curl \
        ca-certificates \
        procps \
        hostname \
        && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd -m -s /bin/bash lisp-claw && \
    chown -R lisp-claw:lisp-claw /home/lisp-claw

WORKDIR /app

# Copy Quicklisp from build stage
COPY --from=build /root/quicklisp /home/lisp-claw/quicklisp

# Copy built system from build stage
COPY --from=build /root/.cache/common-lisp/ /home/lisp-claw/.cache/common-lisp/
COPY --chown=lisp-claw:lisp-claw lisp-claw.asd ./
COPY --chown=lisp-claw:lisp-claw package.lisp ./
COPY --chown=lisp-claw:lisp-claw src/ ./src/
COPY --chown=lisp-claw:lisp-claw config/ ./config/

# Set up environment
ENV HOME=/home/lisp-claw
ENV QL_SETUP=/home/lisp-claw/quicklisp/setup.lisp
ENV PATH="/home/lisp-claw/quicklisp:${PATH}"

# Create config directory
RUN mkdir -p /home/lisp-claw/.lisp-claw && \
    chown lisp-claw:lisp-claw /home/lisp-claw/.lisp-claw

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -fsS http://127.0.0.1:18789/healthz || exit 1

USER lisp-claw

EXPOSE 18789

# Default command - start the gateway
CMD ["sbcl", "--non-interactive", \
     "--load", "/home/lisp-claw/quicklisp/setup.lisp", \
     "--eval", "(push #p\"/app/\" asdf:*central-registry*)", \
     "--eval", "(ql:quickload :lisp-claw)", \
     "--eval", "(lisp-claw.main:start :port 18789 :bind \"0.0.0.0\")"]
