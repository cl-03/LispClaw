;;; vector/chroma.lisp --- ChromaDB Client for Lisp-Claw
;;;
;;; This file provides ChromaDB integration for vector storage.

(defpackage #:lisp-claw.vector.chroma
  (:nicknames #:lc.vector.chroma)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; Chroma client
   #:chroma-client
   #:make-chroma-client
   #:chroma-client-host
   #:chroma-client-port
   ;; Collection operations
   #:chroma-create-collection
   #:chroma-get-collection
   #:chroma-delete-collection
   #:chroma-list-collections
   ;; Document operations
   #:chroma-add-documents
   #:chroma-query-documents
   #:chroma-get-documents
   #:chroma-delete-documents
   ;; Utility
   #:chroma-heartbeat
   #:chroma-version))

(in-package #:lisp-claw.vector.chroma)

;;; ============================================================================
;;; Chroma Client
;;; ============================================================================

(defclass chroma-client ()
  ((host :initarg :host
         :initform "localhost"
         :reader chroma-client-host
         :documentation "ChromaDB host")
   (port :initarg :port
         :initform 8000
         :reader chroma-client-port
         :documentation "ChromaDB port")
   (tenant :initarg :tenant
           :initform "default_tenant"
           :accessor chroma-client-tenant
           :documentation "ChromaDB tenant")
   (database :initarg :database
             :initform "default_database"
             :accessor chroma-client-database
             :documentation "ChromaDB database"))
  (:documentation "ChromaDB client"))

(defmethod print-object ((client chroma-client) stream)
  (print-unreadable-object (client stream :type t)
    (format stream "~A:~A"
            (chroma-client-host client)
            (chroma-client-port client))))

(defun make-chroma-client (&key (host "localhost") (port 8000) tenant database)
  "Create a ChromaDB client.

  Args:
    HOST: ChromaDB host (default: localhost)
    PORT: ChromaDB port (default: 8000)
    TENANT: Tenant name (default: default_tenant)
    DATABASE: Database name (default: default_database)

  Returns:
    Chroma client instance"
  (make-instance 'chroma-client
                 :host host
                 :port port
                 :tenant (or tenant "default_tenant")
                 :database (or database "default_database")))

;;; ============================================================================
;;; HTTP Helper
;;; ============================================================================

(defun chroma-request (client method path &key body)
  "Make HTTP request to ChromaDB.

  Args:
    CLIENT: Chroma client
    METHOD: HTTP method
    PATH: API path
    BODY: Optional request body (plist)

  Returns:
    Response plist"
  (let ((url (format nil "http://~A:~A/api/v1~A"
                     (chroma-client-host client)
                     (chroma-client-port client)
                     path)))
    (handler-case
        (let ((response (dex:request url
                                     :method method
                                     :content (when body (stringify-json body))
                                     :content-type "application/json"
                                     :accept "application/json")))
          (parse-json response))
      (error (e)
        (log-error "Chroma request failed: ~A" e)
        nil))))

;;; ============================================================================
;;; Health & Version
;;; ============================================================================

(defun chroma-heartbeat (client)
  "Get ChromaDB heartbeat.

  Args:
    CLIENT: Chroma client

  Returns:
    Heartbeat plist or NIL"
  (chroma-request client :get "/heartbeat"))

(defun chroma-version (client)
  "Get ChromaDB version.

  Args:
    CLIENT: Chroma client

  Returns:
    Version string"
  (chroma-request client :get "/version"))

;;; ============================================================================
;;; Collection Operations
;;; ============================================================================

(defun chroma-create-collection (client name &key metadata get-or-create)
  "Create a ChromaDB collection.

  Args:
    CLIENT: Chroma client
    NAME: Collection name
    METADATA: Optional metadata
    GET-OR-CREATE: If T, return existing collection if exists

  Returns:
    Collection plist or NIL"
  (if get-or-create
      (chroma-request client :post "/collections"
                      :body `(:name ,name
                              :metadata ,(or metadata '())
                              :get-or-create ,get-or-create))
      (chroma-request client :post "/collections"
                      :body `(:name ,name
                              :metadata ,(or metadata '())))))

(defun chroma-get-collection (client name)
  "Get a ChromaDB collection.

  Args:
    CLIENT: Chroma client
    NAME: Collection name

  Returns:
    Collection plist or NIL"
  (chroma-request client :get (format nil "/collections/~A" name)))

(defun chroma-delete-collection (client name)
  "Delete a ChromaDB collection.

  Args:
    CLIENT: Chroma client
    NAME: Collection name

  Returns:
    T on success"
  (chroma-request client :delete (format nil "/collections/~A" name)))

(defun chroma-list-collections (client)
  "List all ChromaDB collections.

  Args:
    CLIENT: Chroma client

  Returns:
    List of collection names"
  (chroma-request client :get "/collections"))

;;; ============================================================================
;;; Document Operations
;;; ============================================================================

(defun chroma-add-documents (client collection-name ids texts
                             &key metadatas embeddings)
  "Add documents to a ChromaDB collection.

  Args:
    CLIENT: Chroma client
    COLLECTION-NAME: Collection name
    IDS: List of document IDs
    TEXTS: List of document texts
    METADATAS: Optional list of metadata plists
    EMBEDDINGS: Optional list of embeddings (generated by Chroma if NIL)

  Returns:
    T on success"
  (let ((body `(:ids ,ids
              :documents ,texts
              ,@(when metadatas `(:metadatas ,metadatas))
              ,@(when embeddings `(:embeddings ,embeddings)))))
    (chroma-request client :post
                    (format nil "/collections/~A/add" collection-name)
                    :body body)))

(defun chroma-query-documents (client collection-name query-text
                               &key n-results where where-document)
  "Query documents in a ChromaDB collection.

  Args:
    CLIENT: Chroma client
    COLLECTION-NAME: Collection name
    QUERY-TEXT: Query text
    N-RESULTS: Number of results (default: 10)
    WHERE: Optional metadata filter
    WHERE-DOCUMENT: Optional document content filter

  Returns:
    Query results plist"
  (chroma-request client :post
                  (format nil "/collections/~A/query" collection-name)
                  :body `(:query-texts ,(list query-text)
                            :n-results ,(or n-results 10)
                            ,@(when where `(:where ,where))
                            ,@(when where-document `(:where-document ,where-document)))))

(defun chroma-get-documents (client collection-name &key ids where include)
  "Get documents from a ChromaDB collection.

  Args:
    CLIENT: Chroma client
    COLLECTION-NAME: Collection name
    IDS: Optional list of IDs to retrieve
    WHERE: Optional metadata filter
    INCLUDE: Optional list of fields to include (:metadatas, :documents, :embeddings)

  Returns:
    Documents plist"
  (chroma-request client :post
                  (format nil "/collections/~A/get" collection-name)
                  :body `(,@(when ids `(:ids ,ids))
                          ,@(when where `(:where ,where))
                          ,@(when include `(:include ,include)))))

(defun chroma-delete-documents (client collection-name &key ids where)
  "Delete documents from a ChromaDB collection.

  Args:
    CLIENT: Chroma client
    COLLECTION-NAME: Collection name
    IDS: Optional list of IDs to delete
    WHERE: Optional metadata filter

  Returns:
    List of deleted IDs"
  (chroma-request client :post
                  (format nil "/collections/~A/delete" collection-name)
                  :body `(,@(when ids `(:ids ,ids))
                          ,@(when where `(:where ,where)))))

;;; ============================================================================
;;; Utility Functions
;;; ============================================================================

(defun chroma-collection-count (client collection-name)
  "Get the number of documents in a collection.

  Args:
    CLIENT: Chroma client
    COLLECTION-NAME: Collection name

  Returns:
    Document count"
  (chroma-request client :get
                  (format nil "/collections/~A/count" collection-name)))

(defun chroma-update-documents (client collection-name ids &key documents metadatas embeddings)
  "Update documents in a ChromaDB collection.

  Args:
    CLIENT: Chroma client
    COLLECTION-NAME: Collection name
    IDS: List of document IDs
    DOCUMENTS: Optional new documents
    METADATAS: Optional new metadatas
    EMBEDDINGS: Optional new embeddings

  Returns:
    T on success"
  (chroma-request client :post
                  (format nil "/collections/~A/update" collection-name)
                  :body `(:ids ,ids
                          ,@(when documents `(:documents ,documents))
                          ,@(when metadatas `(:metadatas ,metadatas))
                          ,@(when embeddings `(:embeddings ,embeddings)))))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-chroma-client (&key host port)
  "Initialize a ChromaDB client.

  Args:
    HOST: ChromaDB host (default: localhost)
    PORT: ChromaDB port (default: 8000)

  Returns:
    Chroma client instance"
  (let ((client (make-chroma-client :host host :port port)))
    (let ((heartbeat (chroma-heartbeat client)))
      (if heartbeat
          (progn
            (log-info "Connected to ChromaDB at ~A:~A" host port)
            client)
          (progn
            (log-error "Failed to connect to ChromaDB at ~A:~A" host port)
            nil)))))
