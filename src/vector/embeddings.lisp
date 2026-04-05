;;; vector/embeddings.lisp --- Embedding Generation for Lisp-Claw
;;;
;;; This file provides embedding generation using various providers.

(defpackage #:lisp-claw.vector.embeddings
  (:nicknames #:lc.vector.embeddings)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; Embedding provider
   #:embedding-provider
   #:make-embedding-provider
   #:embedding-provider-type
   #:embedding-provider-model
   #:embedding-provider-dimension
   ;; Embedding generation
   #:generate-embedding
   #:generate-embeddings-batch
   ;; Provider implementations
   #:openai-embeddings
   #:ollama-embeddings
   #:local-embeddings
   ;; Cache
   #:*embedding-cache*
   #:cache-embedding
   #:get-cached-embedding
   #:clear-embedding-cache))

(in-package #:lisp-claw.vector.embeddings)

;;; ============================================================================
;;; Embedding Provider
;;; ============================================================================

(defclass embedding-provider ()
  ((type :initarg :type
         :reader embedding-provider-type
         :documentation "Provider type: openai, ollama, local")
   (model :initarg :model
          :accessor embedding-provider-model
          :documentation "Model name")
   (dimension :initarg :dimension
              :reader embedding-provider-dimension
              :documentation "Embedding dimension")
   (api-key :initarg :api-key
            :accessor embedding-provider-api-key
            :documentation "API key (for remote providers)")
   (endpoint :initarg :endpoint
             :accessor embedding-provider-endpoint
             :documentation "API endpoint (for remote providers)"))
  (:documentation "Embedding generation provider"))

(defmethod print-object ((provider embedding-provider) stream)
  (print-unreadable-object (provider stream :type t)
    (format stream "~A (~A)"
            (embedding-provider-type provider)
            (embedding-provider-model provider))))

(defun make-embedding-provider (type &key model api-key endpoint dimension)
  "Create an embedding provider.

  Args:
    TYPE: Provider type (openai, ollama, local)
    MODEL: Model name
    API-KEY: API key (for remote providers)
    ENDPOINT: API endpoint (for remote providers)
    DIMENSION: Embedding dimension

  Returns:
    Embedding provider instance"
  (let ((default-dimension (case type
                             ((:openai) 1536)  ; text-embedding-ada-002
                             ((:ollama) 768)   ; nomic-embed-text
                             ((:local) 384)    ; default local model
                             (t 768))))
    (make-instance 'embedding-provider
                   :type type
                   :model (or model (case type
                                      ((:openai) "text-embedding-ada-002")
                                      ((:ollama) "nomic-embed-text")
                                      ((:local) "local-model")
                                      (t "default")))
                   :api-key api-key
                   :endpoint endpoint
                   :dimension (or dimension default-dimension))))

;;; ============================================================================
;;; Embedding Cache
;;; ============================================================================

(defvar *embedding-cache* (make-hash-table :test 'equal)
  "Cache of text -> embedding.")

(defvar *embedding-cache-size* 10000
  "Maximum cache size.")

(defun cache-embedding (text embedding)
  "Cache an embedding.

  Args:
    TEXT: Text that was embedded
    EMBEDDING: Embedding vector

  Returns:
    T on success"
  (when (>= (hash-table-count *embedding-cache*) *embedding-cache-size*)
    ;; Simple cache eviction: clear half the cache
    (let ((count 0))
      (maphash (lambda (k v)
                 (declare (ignore v))
                 (when (< count (/ *embedding-cache-size* 2))
                   (remhash k *embedding-cache*)
                   (incf count)))
               *embedding-cache*)))
  (setf (gethash text *embedding-cache*) embedding)
  (log-debug "Cached embedding for text: ~A..." (subseq text 0 (min 20 (length text))))
  t)

(defun get-cached-embedding (text)
  "Get a cached embedding.

  Args:
    TEXT: Text to look up

  Returns:
    Embedding vector or NIL"
  (gethash text *embedding-cache*))

(defun clear-embedding-cache ()
  "Clear the embedding cache.

  Returns:
    T"
  (clrhash *embedding-cache*)
  (log-info "Embedding cache cleared")
  t)

;;; ============================================================================
;;; OpenAI Embeddings
;;; ============================================================================

(defun generate-embedding-with-openai (provider text &key model)
  "Generate embedding using OpenAI.

  Args:
    PROVIDER: OpenAI embedding provider
    TEXT: Text to embed
    MODEL: Optional model override

  Returns:
    Embedding vector (list of floats)"
  (let ((model-name (or model (slot-value provider 'model)))
        (api-key (slot-value provider 'api-key)))
    (unless api-key
      (error "OpenAI API key required"))

    ;; Placeholder - actual implementation would call OpenAI API
    (log-info "Requesting OpenAI embedding for: ~A..." (subseq text 0 (min 30 (length text))))

    ;; Simulated embedding (remove in real implementation)
    (make-list (slot-value provider 'dimension) :initial-element 0.0)))

;;; ============================================================================
;;; Ollama Embeddings
;;; ============================================================================

(defun generate-embedding-with-ollama (provider text &key model host)
  "Generate embedding using Ollama.

  Args:
    PROVIDER: Ollama embedding provider
    TEXT: Text to embed
    MODEL: Optional model override
    HOST: Optional Ollama host (default: http://localhost:11434)

  Returns:
    Embedding vector (list of floats)"
  (let ((model-name (or model (slot-value provider 'model)))
        (endpoint (or host (slot-value provider 'endpoint) "http://localhost:11434")))
    ;; Placeholder - actual implementation would call Ollama API
    (log-info "Requesting Ollama embedding (~A) for: ~A..." model-name (subseq text 0 (min 30 (length text))))

    ;; Simulated embedding (remove in real implementation)
    (make-list (slot-value provider 'dimension) :initial-element 0.0)))

;;; ============================================================================
;;; Local Embeddings
;;; ============================================================================

(defun generate-embedding-with-local (provider text)
  "Generate embedding using local model.

  Args:
    PROVIDER: Local embedding provider
    TEXT: Text to embed

  Returns:
    Embedding vector (list of floats)"
  ;; Placeholder - actual implementation would use a local embedding library
  ;; Options include:
  ;; - CL-TRANSFORMERS for HuggingFace models
  ;; - Foreign function interface to C/C++ libraries
  (log-info "Generating local embedding for: ~A..." (subseq text 0 (min 30 (length text))))

  ;; Simulated embedding using text hash (deterministic but not semantically meaningful)
  ;; This is a placeholder for demonstration purposes
  (let ((dim (slot-value provider 'dimension))
        (hash (sxhash text)))
    (loop for i below dim
          collect (sin (+ hash (* i 0.1))))))

;;; ============================================================================
;;; Main Embedding Interface
;;; ============================================================================

(defun generate-embedding (provider text &key use-cache)
  "Generate embedding for text.

  Args:
    PROVIDER: Embedding provider instance
    TEXT: Text to embed
    USE-CACHE: Whether to use cache (default: T)

  Returns:
    Embedding vector (list of floats)"
  (when (or use-cache (null use-cache))
    (let ((cached (get-cached-embedding text)))
      (when cached
        (log-debug "Cache hit for embedding")
        (return-from generate-embedding cached))))

  (let ((embedding (case (embedding-provider-type provider)
                     ((:openai) (generate-embedding-with-openai provider text))
                     ((:ollama) (generate-embedding-with-ollama provider text))
                     ((:local) (generate-embedding-with-local provider text))
                     (otherwise (error "Unknown embedding provider type: ~A" otherwise)))))
    ;; Cache the result
    (cache-embedding text embedding)
    embedding))

(defun generate-embeddings-batch (provider texts &key use-cache)
  "Generate embeddings for multiple texts.

  Args:
    PROVIDER: Embedding provider instance
    TEXTS: List of texts to embed
    USE-CACHE: Whether to use cache (default: T)

  Returns:
    List of embedding vectors"
  (mapcar (lambda (text)
            (generate-embedding provider text :use-cache use-cache))
          texts))

;;; ============================================================================
;;; Text Preprocessing
;;; ============================================================================

(defun normalize-text-for-embedding (text)
  "Normalize text for embedding.

  Args:
    TEXT: Input text

  Returns:
    Normalized text"
  ;; Remove extra whitespace, normalize case, etc.
  (string-trim '(#\Space #\Tab #\Newline #\Return) text))

(defun chunk-text (text &key max-length overlap)
  "Chunk text for embedding of long documents.

  Args:
    TEXT: Input text
    MAX-LENGTH: Maximum chunk length (default: 500)
    OVERLAP: Overlap between chunks (default: 50)

  Returns:
    List of text chunks"
  (let ((max-len (or max-length 500))
        (overlap-len (or overlap 50))
        (chunks nil)
        (start 0)
        (len (length text)))
    (loop while (< start len)
          do (let* ((end (min len (+ start max-len)))
                    (chunk (subseq text start end)))
               (push chunk chunks)
               (setf start (- end overlap-len))))
    (nreverse chunks)))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-embedding-system (&key provider-type model api-key endpoint)
  "Initialize the embedding system.

  Args:
    PROVIDER-TYPE: Provider type (openai, ollama, local)
    MODEL: Model name
    API-KEY: API key
    ENDPOINT: API endpoint

  Returns:
    Embedding provider instance"
  (let ((provider (make-embedding-provider (or provider-type :local)
                                           :model model
                                           :api-key api-key
                                           :endpoint endpoint)))
    (log-info "Embedding system initialized with ~A provider" provider-type)
    provider))
