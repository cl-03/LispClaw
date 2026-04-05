;;; vector/qdrant.lisp --- Qdrant Vector Database Client for Lisp-Claw
;;;
;;; This file implements Qdrant vector database client for semantic search
;;; and vector storage, as an alternative to ChromaDB.

(defpackage #:lisp-claw.vector.qdrant
  (:nicknames #:lc.vector.qdrant)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.vector.embeddings)
  (:export
   ;; Qdrant client
   #:qdrant-client
   #:make-qdrant-client
   #:qdrant-host
   #:qdrant-port
   #:qdrant-api-key
   #:qdrant-connected-p
   ;; Collection operations
   #:qdrant-create-collection
   #:qdrant-delete-collection
   #:qdrant-list-collections
   #:qdrant-collection-info
   ;; Point operations
   #:qdrant-upsert
   #:qdrant-upsert-batch
   #:qdrant-delete
   #:qdrant-retrieve
   ;; Search operations
   #:qdrant-search
   #:qdrant-search-batch
   #:qdrant-search-with-filter
   ;; Filter operations
   #:qdrant-make-filter
   #:qdrant-make-range-filter
   #:qdrant-make-match-filter
   ;; Scroll operations
   #:qdrant-scroll
   ;; Count operation
   #:qdrant-count
   ;; Initialization
   #:initialize-qdrant-system))

(in-package #:lisp-claw.vector.qdrant)

;;; ============================================================================
;;; Qdrant Client Class
;;; ============================================================================

(defclass qdrant-client ()
  ((host :initarg :host
         :initform "localhost"
         :reader qdrant-host
         :documentation "Qdrant host")
   (port :initarg :port
         :initform 6333
         :reader qdrant-port
         :documentation "Qdrant HTTP port")
   (api-key :initarg :api-key
            :initform nil
            :reader qdrant-api-key
            :documentation "Qdrant API key")
   (https-p :initarg :https-p
            :initform nil
            :reader qdrant-https-p
            :documentation "Use HTTPS")
   (connected-p :initform nil
                :accessor qdrant-connected-p
                :documentation "Connection status")
   (timeout :initarg :timeout
            :initform 30
            :reader qdrant-timeout
            :documentation "Request timeout in seconds"))
  (:documentation "Qdrant vector database client"))

(defmethod print-object ((client qdrant-client) stream)
  (print-unreadable-object (client stream :type t)
    (format stream "~A:~A [~A]"
            (qdrant-host client)
            (qdrant-port client)
            (if (qdrant-connected-p client) "connected" "disconnected"))))

(defun make-qdrant-client (&key host port api-key https-p timeout)
  "Create a Qdrant client.

  Args:
    HOST: Qdrant host (default: localhost)
    PORT: HTTP port (default: 6333)
    API-KEY: API key (optional)
    HTTPS-P: Use HTTPS (default: NIL)
    TIMEOUT: Request timeout (default: 30)

  Returns:
    Qdrant client instance"
  (let ((client (make-instance 'qdrant-client
                               :host (or host "localhost")
                               :port (or port 6333)
                               :api-key api-key
                               :https-p (or https-p nil)
                               :timeout (or timeout 30))))
    ;; Test connection
    (when (qdrant-ping client)
      (setf (qdrant-connected-p client) t))
    client))

;;; ============================================================================
;;; HTTP Helper
;;; ============================================================================

(defun qdrant-request (client method path &key body)
  "Make HTTP request to Qdrant.

  Args:
    CLIENT: Qdrant client
    METHOD: HTTP method
    PATH: URL path
    BODY: Request body (plist)

  Returns:
    Response plist"
  (let* ((scheme (if (qdrant-https-p client) "https" "http"))
         (url (format nil "~A://~A:~A~A" scheme (qdrant-host client) (qdrant-port client) path))
         (headers (list (cons "Content-Type" "application/json")))
         (response nil))

    ;; Add API key if present
    (when (qdrant-api-key client)
      (push (cons "api-key" (qdrant-api-key client)) headers))

    ;; Make request
    (let ((response-body (case method
                           (:get (dexador:get url :headers headers))
                           (:post (dexador:post url :content (json-to-string body) :headers headers))
                           (:put (dexador:put url :content (json-to-string body) :headers headers))
                           (:delete (dexador:delete url :headers headers)))))
      (when response-body
        (setf response (parse-json response-body)))))

    response))

(defun qdrant-ping (client)
  "Ping Qdrant server.

  Args:
    CLIENT: Qdrant client

  Returns:
    T if server is reachable"
  (handler-case
      (let ((response (qdrant-request client :get "/"))
            (status (getf response :status)))
        (when (string= status "ok")
          (log-info "Connected to Qdrant at ~A:~A" (qdrant-host client) (qdrant-port client))
          t))
    (error (e)
      (log-error "Failed to connect to Qdrant: ~A" e)
      nil)))

;;; ============================================================================
;;; Collection Operations
;;; ============================================================================

(defun qdrant-create-collection (client collection-name vector-size &key distance on-disk-payload)
  "Create a new collection.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    VECTOR-SIZE: Vector dimension size
    DISTANCE: Distance metric (Cosine, Euclid, Dot, Manhattan)
    ON-DISK-PAYLOAD: Store payload on disk (default: NIL)

  Returns:
    T on success"
  (let ((body (list :collection_name collection-name
                    :vectors_config (list :size vector-size
                                          :distance (or distance "Cosine")))))
    (when on-disk-payload
      (setf body (plist-put body :on_disk_payload t)))

    (let ((response (qdrant-request client :put "/collections/~A"
                                    :body body)))
      (if (getf response :result)
          (progn
            (log-info "Created Qdrant collection: ~A" collection-name)
            t)
          nil)))))

(defun qdrant-delete-collection (client collection-name)
  "Delete a collection.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name

  Returns:
    T on success"
  (let ((response (qdrant-request client :delete "/collections/~A")))
    (if (getf response :result)
        (progn
          (log-info "Deleted Qdrant collection: ~A" collection-name)
          t)
        nil))))

(defun qdrant-list-collections (client)
  "List all collections.

  Args:
    CLIENT: Qdrant client

  Returns:
    List of collection names"
  (let ((response (qdrant-request client :get "/collections")))
    (let ((collections (getf response :result)))
      (mapcar (lambda (c) (getf c :name)) collections))))

(defun qdrant-collection-info (client collection-name)
  "Get collection information.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name

  Returns:
    Collection info plist"
  (let ((response (qdrant-request client :get "/collections/~A")))
    (getf response :result)))

;;; ============================================================================
;;; Point Operations
;;; ============================================================================

(defun qdrant-upsert (client collection-name id vector &key payload)
  "Upsert a single point.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    ID: Point ID
    VECTOR: Vector (list of floats)
    PAYLOAD: Optional payload (plist)

  Returns:
    T on success"
  (let ((body (list :collection_name collection-name
                    :points (vector (list :id id
                                          :vector vector
                                          :payload (or payload (make-hash-table :test 'equal)))))))
    (let ((response (qdrant-request client :put "/collections/~A/points"
                                    :body body)))
      (if (getf response :result)
          t
          nil)))))

(defun qdrant-upsert-batch (client collection-name points)
  "Upsert multiple points.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    POINTS: List of plists (:id :vector :payload)

  Returns:
    T on success"
  (let ((points-data (mapcar (lambda (p)
                               (list :id (getf p :id)
                                     :vector (getf p :vector)
                                     :payload (or (getf p :payload) (make-hash-table :test 'equal))))
                             points))
        (body (list :collection_name collection-name
                    :points points-data)))
    (let ((response (qdrant-request client :put "/collections/~A/points"
                                    :body body)))
      (if (getf response :result)
          t
          nil)))))

(defun qdrant-delete (client collection-name ids)
  "Delete points by IDs.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    IDS: List of point IDs to delete

  Returns:
    T on success"
  (let ((body (list :collection_name collection-name
                    :points ids)))
    (let ((response (qdrant-request client :post "/collections/~A/points/delete"
                                    :body body)))
      (if (getf response :result)
          t
          nil)))))

(defun qdrant-retrieve (client collection-name ids &key with-vector with-payload)
  "Retrieve points by IDs.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    IDS: List of point IDs
    WITH-VECTOR: Include vectors (default: T)
    WITH-PAYLOAD: Include payload (default: T)

  Returns:
    List of points"
  (let ((body (list :collection_name collection-name
                    :ids ids
                    :with_vector (if with-vector t nil)
                    :with_payload (if with-payload t nil))))
    (let ((response (qdrant-request client :post "/collections/~A/points/retrieve"
                                    :body body)))
      (getf response :result)))))

;;; ============================================================================
;;; Search Operations
;;; ============================================================================

(defun qdrant-search (client collection-name query-vector &key limit with-payload score-threshold)
  "Search for similar vectors.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    QUERY-VECTOR: Query vector (list of floats)
    LIMIT: Max results (default: 10)
    WITH-PAYLOAD: Include payload (default: T)
    SCORE-THRESHOLD: Minimum score threshold

  Returns:
    List of search results"
  (let ((body (list :collection_name collection-name
                    :vector query-vector
                    :limit (or limit 10)
                    :with_payload (if with-payload t nil))))
    (when score-threshold
      (setf body (plist-put body :score_threshold score-threshold)))

    (let ((response (qdrant-request client :post "/collections/~A/points/search"
                                    :body body)))
      (getf response :result)))))

(defun qdrant-search-batch (client collection-name query-vectors &key limit)
  "Search for multiple query vectors.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    QUERY-VECTORS: List of query vectors
    LIMIT: Max results per query (default: 10)

  Returns:
    List of search result lists"
  (let ((search-requests (mapcar (lambda (v)
                                   (list :vector v :limit (or limit 10)))
                                 query-vectors))
        (body (list :collection_name collection-name
                    :search_requests search-requests)))
    (let ((response (qdrant-request client :post "/collections/~A/points/search/batch"
                                    :body body)))
      (getf response :result)))))

(defun qdrant-search-with-filter (client collection-name query-vector filter &key limit)
  "Search with filter.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    QUERY-VECTOR: Query vector
    FILTER: Filter plist
    LIMIT: Max results (default: 10)

  Returns:
    List of search results"
  (let ((body (list :collection_name collection-name
                    :vector query-vector
                    :filter filter
                    :limit (or limit 10))))
    (let ((response (qdrant-request client :post "/collections/~A/points/search"
                                    :body body)))
      (getf response :result)))))

;;; ============================================================================
;;; Filter Operations
;;; ============================================================================

(defun qdrant-make-filter (&key must must-not should)
  "Create a filter.

  Args:
    MUST: Conditions that must match
    MUST-NOT: Conditions that must not match
    SHOULD: Conditions that should match

  Returns:
    Filter plist"
  (let ((filter (make-hash-table :test 'equal)))
    (when must
      (setf (gethash "must" filter) must))
    (when must-not
      (setf (gethash "must_not" filter) must-not))
    (when should
      (setf (gethash "should" filter) should))
    filter))

(defun qdrant-make-range-filter (key &key gte gt lte lt)
  "Create a range filter.

  Args:
    KEY: Payload key
    GTE: Greater than or equal
    GT: Greater than
    LTE: Less than or equal
    LT: Less than

  Returns:
    Range filter plist"
  (let ((range (make-hash-table :test 'equal)))
    (when gte (setf (gethash "gte" range) gte))
    (when gt (setf (gethash "gt" range) gt))
    (when lte (setf (gethash "lte" range) lte))
    (when lt (setf (gethash "lt" range) lt))
    (list :key key :range range)))

(defun qdrant-make-match-filter (key value)
  "Create a match filter.

  Args:
    KEY: Payload key
    VALUE: Value to match

  Returns:
    Match filter plist"
  (list :key key :match (list :value value)))

;;; ============================================================================
;;; Scroll and Count Operations
;;; ============================================================================

(defun qdrant-scroll (client collection-name &key limit offset with-payload filter)
  "Scroll through points.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    LIMIT: Max results (default: 10)
    OFFSET: Start offset
    WITH-PAYLOAD: Include payload (default: T)
    FILTER: Optional filter

  Returns:
    Scroll result plist"
  (let ((body (list :collection_name collection-name
                    :limit (or limit 10)
                    :with_payload (if with-payload t nil))))
    (when offset
      (setf body (plist-put body :offset offset)))
    (when filter
      (setf body (plist-put body :filter filter)))

    (let ((response (qdrant-request client :post "/collections/~A/points/scroll"
                                    :body body)))
      (getf response :result)))))

(defun qdrant-count (client collection-name &key filter)
  "Count points in collection.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    FILTER: Optional filter

  Returns:
    Count plist"
  (let ((body (list :collection_name collection-name)))
    (when filter
      (setf body (plist-put body :filter filter)))

    (let ((response (qdrant-request client :post "/collections/~A/points/count"
                                    :body body)))
      (getf response :result)))))

;;; ============================================================================
;;; Integration with Embeddings
;;; ============================================================================

(defun qdrant-store-with-embedding (client collection-name text id &key embedding-provider metadata)
  "Store text with embedding.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    TEXT: Text to embed and store
    ID: Point ID
    EMBEDDING-PROVIDER: Embedding provider instance
    METADATA: Optional metadata

  Returns:
    T on success"
  (when embedding-provider
    (let ((vector (generate-embedding embedding-provider text)))
      (let ((payload (or metadata (make-hash-table :test 'equal))))
        (setf (gethash "text" payload) text)
        (qdrant-upsert client collection-name id vector :payload payload)))))

(defun qdrant-search-with-embedding (client collection-name query-text embedding-provider &key limit)
  "Search by query text.

  Args:
    CLIENT: Qdrant client
    COLLECTION-NAME: Collection name
    QUERY-TEXT: Query text
    EMBEDDING-PROVIDER: Embedding provider instance
    LIMIT: Max results

  Returns:
    List of search results"
  (when embedding-provider
    (let ((vector (generate-embedding embedding-provider query-text)))
      (qdrant-search client collection-name vector :limit limit))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defvar *default-qdrant-client* nil
  "Default Qdrant client instance.")

(defun initialize-qdrant-system (&key host port api-key)
  "Initialize Qdrant system.

  Args:
    HOST: Qdrant host (default: localhost)
    PORT: Qdrant port (default: 6333)
    API-KEY: API key (optional)

  Returns:
    Qdrant client instance"
  (setf *default-qdrant-client* (make-qdrant-client
                                 :host (or host "localhost")
                                 :port (or port 6333)
                                 :api-key api-key))
  (log-info "Qdrant system initialized")
  *default-qdrant-client*)
