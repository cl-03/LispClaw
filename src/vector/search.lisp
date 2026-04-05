;;; vector/search.lisp --- Semantic Search Interface for Lisp-Claw
;;;
;;; This file provides semantic search and RAG functionality.

(defpackage #:lisp-claw.vector.search
  (:nicknames #:lc.vector.search)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.vector.store
        #:lisp-claw.vector.embeddings
        #:lisp-claw.advanced.memory)
  (:export
   ;; Semantic search
   #:semantic-search
   #:semantic-search-memory
   #:search-by-similarity
   ;; RAG
   #:rag-context
   #:build-rag-prompt
   #:query-knowledge-base
   ;; Knowledge base
   #:knowledge-base
   #:make-knowledge-base
   #:kb-add-document
   #:kb-add-documents-batch
   #:kb-query
   #:kb-list-documents
   #:kb-delete-document
   ;; Integration
   #:search-context-for-agent
   ;; Initialization
   #:initialize-vector-search-system
   #:initialize-vector-search
   #:*default-knowledge-base*
   #:*default-embedding-provider*
   #:*default-vector-store*))

(in-package #:lisp-claw.vector.search)

;;; ============================================================================
;; Semantic Search
;;; ============================================================================

(defun semantic-search (store collection-name query-text provider &key top-k filter)
  "Search for semantically similar items.

  Args:
    STORE: Vector store instance
    COLLECTION-NAME: Collection to search
    QUERY-TEXT: Query text (will be embedded)
    PROVIDER: Embedding provider
    TOP-K: Number of results (default: 10)
    FILTER: Optional metadata filter function

  Returns:
    List of search results with scores"
  ;; Generate query embedding
  (let ((query-vector (generate-embedding provider query-text)))
    ;; Search vectors
    (search-vectors store collection-name query-vector
                    :top-k top-k
                    :filter filter)))

(defun search-by-similarity (items query-text provider &key key-fn top-k)
  "Search items by semantic similarity.

  Args:
    ITEMS: List of items to search
    QUERY-TEXT: Query text
    PROVIDER: Embedding provider
    KEY-FN: Function to extract text from item
    TOP-K: Number of results

  Returns:
    List of (item score) sorted by similarity"
  (let ((query-vector (generate-embedding provider query-text))
        (results nil))
    (dolist (item items)
      (let* ((text (funcall (or key-fn #'identity) item))
             (item-vector (generate-embedding provider text))
             (score (cosine-similarity query-vector item-vector)))
        (push (cons item score) results)))
    ;; Sort by score descending
    (setf results (sort results #'> :key #'cdr))
    ;; Return top-k
    (subseq results 0 (min (or top-k 10) (length results)))))

;;; ============================================================================
;;; Knowledge Base
;;; ============================================================================

(defclass knowledge-base ()
  ((store :initarg :store
          :reader kb-store
          :documentation "Vector store instance")
   (embedding-provider :initarg :embedding-provider
                       :reader kb-embedding-provider
                       :documentation "Embedding provider")
   (collection :initarg :collection
               :reader kb-collection
               :documentation "Collection name")
   (documents :initform (make-hash-table :test 'equal)
              :accessor kb-documents
              :documentation "Document storage"))
  (:documentation "Knowledge base for RAG"))

(defun make-knowledge-base (store provider collection-name)
  "Create a knowledge base.

  Args:
    STORE: Vector store instance
    PROVIDER: Embedding provider
    COLLECTION-NAME: Collection name

  Returns:
    Knowledge base instance"
  (make-instance 'knowledge-base
                 :store store
                 :embedding-provider provider
                 :collection collection-name))

(defun kb-add-document (kb id text &key metadata)
  "Add a document to the knowledge base.

  Args:
    KB: Knowledge base instance
    ID: Document identifier
    TEXT: Document text
    METADATA: Optional metadata

  Returns:
    T on success"
  (let* ((provider (kb-embedding-provider kb))
         (embedding (generate-embedding provider text)))
    ;; Store document
    (setf (gethash id (kb-documents kb))
          (list :text text :metadata metadata :embedding embedding))
    ;; Store vector
    (upsert-vector (kb-store kb) (kb-collection kb) id embedding :metadata metadata)
    (log-info "Added document ~A to knowledge base" id)
    t))

(defun kb-add-documents-batch (kb documents-alist)
  "Add multiple documents to the knowledge base.

  Args:
    KB: Knowledge base instance
    DOCUMENTS-ALIST: List of (id text &key metadata) plists

  Returns:
    Number of documents added"
  (let ((count 0))
    (dolist (entry documents-alist)
      (apply #'kb-add-document kb entry)
      (incf count))
    (log-info "Added ~A documents to knowledge base" count)
    count))

(defun kb-query (kb query-text &key top-k filter)
  "Query the knowledge base.

  Args:
    KB: Knowledge base instance
    QUERY-TEXT: Query text
    TOP-K: Number of results (default: 5)
    FILTER: Optional metadata filter

  Returns:
    List of (id text score metadata)"
  (let* ((provider (kb-embedding-provider kb))
         (results (semantic-search (kb-store kb) (kb-collection kb)
                                   query-text provider
                                   :top-k (or top-k 5)
                                   :filter filter)))
    ;; Enrich results with document text
    (mapcar (lambda (result)
              (let* ((id (getf result :id))
                     (doc (gethash id (kb-documents kb))))
                (list :id id
                      :text (getf doc :text)
                      :score (getf result :score)
                      :metadata (getf result :metadata))))
            results)))

(defun kb-list-documents (kb)
  "List all documents in the knowledge base.

  Args:
    KB: Knowledge base instance

  Returns:
    List of document IDs"
  (let ((ids nil))
    (maphash (lambda (k v)
               (declare (ignore v))
               (push k ids))
             (kb-documents kb))
    ids))

(defun kb-delete-document (kb id)
  "Delete a document from the knowledge base.

  Args:
    KB: Knowledge base instance
    ID: Document ID

  Returns:
    T on success"
  (remhash id (kb-documents kb))
  (delete-vector (kb-store kb) (kb-collection kb) id)
  (log-info "Deleted document ~A from knowledge base" id)
  t)

;;; ============================================================================
;;; RAG (Retrieval Augmented Generation)
;;; ============================================================================

(defun rag-context (kb query-text &key top-k max-tokens)
  "Retrieve context for RAG.

  Args:
    KB: Knowledge base instance
    QUERY-TEXT: Query text
    TOP-K: Number of documents to retrieve (default: 5)
    MAX-TOKENS: Maximum total tokens (default: 2000)

  Returns:
    List of (text score) within token limit"
  (let* ((results (kb-query kb query-text :top-k (or top-k 5)))
         (context nil)
         (total-tokens 0)
         (max-tokens (or max-tokens 2000)))
    (dolist (result results)
      (let* ((text (getf result :text))
             (tokens (floor (* (length text) 0.75))))  ; Rough estimate
        (when (<= (+ total-tokens tokens) max-tokens)
          (push (list :text text :score (getf result :score)) context)
          (incf total-tokens tokens))))
    (nreverse context)))

(defun build-rag-prompt (query-text context &key template)
  "Build a RAG prompt with retrieved context.

  Args:
    QUERY-TEXT: Original query
    CONTEXT: List of (text score) context items
    TEMPLATE: Optional prompt template

  Returns:
    Formatted prompt string"
  (let ((template (or template
                      "Based on the following context, answer the question.

Context:
~A

Question: ~A

Answer:")))
    (let ((context-text (format nil "~{~A~^~%---~%~}"
                                (mapcar (lambda (c) (getf c :text)) context))))
      (format nil template context-text query-text))))

(defun query-knowledge-base (kb query-text &key top-k max-tokens prompt-template)
  "Query knowledge base and build RAG prompt.

  Args:
    KB: Knowledge base instance
    QUERY-TEXT: Query text
    TOP-K: Number of documents to retrieve
    MAX-TOKENS: Maximum context tokens
    PROMPT-TEMPLATE: Custom prompt template

  Returns:
    RAG prompt string"
  (let ((context (rag-context kb query-text :top-k top-k :max-tokens max-tokens)))
    (if (null context)
        query-text  ; No context, return original query
        (build-rag-prompt query-text context :template prompt-template))))

;;; ============================================================================
;;; Agent Integration
;;; ============================================================================

(defun search-context-for-agent (session-id query-text &key kb top-k)
  "Search context for agent session.

  Args:
    SESSION-ID: Agent session ID
    QUERY-TEXT: Query text
    KB: Knowledge base instance
    TOP-K: Number of results

  Returns:
    Context string for agent"
  (declare (ignore session-id))  ; Future: use session to personalize search
  (let ((results (kb-query kb query-text :top-k (or top-k 3))))
    (if (null results)
        ""
        (format nil "Relevant context:~%~{~A (score: ~,2f)~%~}"
                (mapcar (lambda (r) (getf r :text)) results)
                (mapcar (lambda (r) (getf r :score)) results)))))

;;; ============================================================================
;;; Memory Integration
;;; ============================================================================

(defun semantic-search-memory (query-text provider &key memory-store top-k)
  "Search memories by semantic similarity.

  Args:
    QUERY-TEXT: Query text
    PROVIDER: Embedding provider
    MEMORY-STORE: Memory store hash table
    TOP-K: Number of results

  Returns:
    List of (memory score) sorted by similarity"
  (let ((query-vector (generate-embedding provider query-text))
        (results nil))
    (maphash (lambda (id memory)
               (declare (ignore id))
               (let* ((content (memory-content memory))
                      (content-vector (generate-embedding provider content))
                      (score (cosine-similarity query-vector content-vector)))
                 (push (cons memory score) results)))
             memory-store)
    ;; Sort by score descending
    (setf results (sort results #'> :key #'cdr))
    ;; Return top-k
    (subseq results 0 (min (or top-k 10) (length results)))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defvar *default-knowledge-base* nil
  "Default knowledge base for vector search.")

(defvar *default-embedding-provider* nil
  "Default embedding provider.")

(defvar *default-vector-store* nil
  "Default vector store.")

(defun initialize-vector-search-system (config &key provider-type model api-key endpoint store-type collection)
  "Initialize the vector search system.

  Args:
    CONFIG: Vector configuration alist (can be NIL)
    PROVIDER-TYPE: Provider type override (openai, ollama, local)
    MODEL: Model name override
    API-KEY: API key override
    ENDPOINT: Endpoint override
    STORE-TYPE: Store type override (:local or :chroma)
    COLLECTION: Collection name override

  Returns:
    Knowledge base instance or NIL"
  (let* ((enabled (if config (cdr (assoc :enabled config)) t))
         (provider-type (or provider-type
                            (when config (cdr (assoc :provider-type config)))
                            :local))
         (collection (or collection
                         (when config (cdr (assoc :collection config)))
                         "default"))
         (api-key (or api-key
                      (when config (cdr (assoc :api-key config)))))
         (endpoint (or endpoint
                       (when config (cdr (assoc :endpoint endpoint)))))
         (dimension (case provider-type
                      ((:openai) 1536)
                      ((:ollama) 768)
                      (t 384))))
    (when enabled
      ;; Create vector store
      (setf *default-vector-store* (make-vector-store :dimension dimension))
      ;; Create embedding provider
      (setf *default-embedding-provider*
            (make-embedding-provider provider-type
                                     :model model
                                     :api-key api-key
                                     :endpoint endpoint))
      ;; Create knowledge base
      (setf *default-knowledge-base*
            (make-knowledge-base *default-vector-store*
                                 *default-embedding-provider*
                                 collection))
      (log-info "Vector search system initialized with ~A provider, collection: ~A"
                provider-type collection)
      *default-knowledge-base*)))

(defun initialize-vector-search (vector-store embedding-provider collection-name)
  "Initialize the vector search system.

  Args:
    VECTOR-STORE: Vector store instance
    EMBEDDING-PROVIDER: Embedding provider instance
    COLLECTION-NAME: Default collection name

  Returns:
    Knowledge base instance"
  (let ((kb (make-knowledge-base vector-store embedding-provider collection-name)))
    (log-info "Vector search initialized with collection: ~A" collection-name)
    kb))
