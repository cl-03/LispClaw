;;; vector/store.lisp --- Vector Store Interface for Lisp-Claw
;;;
;;; This file provides abstract vector store interface for semantic search and RAG.

(defpackage #:lisp-claw.vector.store
  (:nicknames #:lc.vector.store)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging)
  (:export
   ;; Vector store class
   #:vector-store
   #:make-vector-store
   #:vector-store-id
   #:vector-store-dimension
   #:vector-store-count
   ;; Vector operations
   #:upsert-vector
   #:search-vectors
   #:delete-vector
   #:get-vector
   ;; Batch operations
   #:upsert-vectors-batch
   #:search-vectors-batch
   ;; Store management
   #:list-collections
   #:create-collection
   #:delete-collection
   ;; Similarity functions
   #:cosine-similarity
   #:dot-product
   #:euclidean-distance))

(in-package #:lisp-claw.vector.store)

;;; ============================================================================
;;; Vector Store Class
;;; ============================================================================

(defclass vector-store ()
  ((id :initarg :id
       :reader vector-store-id
       :documentation "Unique store identifier")
   (dimension :initarg :dimension
              :reader vector-store-dimension
              :documentation "Vector dimension")
   (collections :initform (make-hash-table :test 'equal)
                :reader vector-store-collections
       :documentation "Hash table of collections")
   (metadata :initform nil
             :accessor vector-store-metadata
             :documentation "Store metadata")))

(defmethod print-object ((store vector-store) stream)
  (print-unreadable-object (store stream :type t)
    (format stream "~A [~A dims]"
            (vector-store-id store)
            (vector-store-dimension store))))

(defun make-vector-store (&key id dimension metadata)
  "Create a new vector store.

  Args:
    ID: Store identifier (generated if NIL)
    DIMENSION: Vector dimension (e.g., 1536 for OpenAI embeddings)
    METADATA: Optional metadata

  Returns:
    Vector store instance"
  (make-instance 'vector-store
                 :id (or id (format nil "store-~A" (get-universal-time)))
                 :dimension dimension
                 :metadata metadata))

;;; ============================================================================
;;; Collection Class
;;; ============================================================================

(defclass vector-collection ()
  ((name :initarg :name
         :reader collection-name
         :documentation "Collection name")
   (vectors :initform (make-hash-table :test 'equal)
            :accessor collection-vectors
            :documentation "Hash table of id -> vector")
   (metadata :initform nil
             :accessor collection-metadata
             :documentation "Collection metadata")
   (created-at :initform (get-universal-time)
               :reader collection-created-at
       :documentation "Creation timestamp")))

(defmethod print-object ((collection vector-collection) stream)
  (print-unreadable-object (collection stream :type t)
    (format stream "~A [~A vectors]"
            (collection-name collection)
            (hash-table-count (slot-value collection 'vectors)))))

;;; ============================================================================
;;; Collection Management
;;; ============================================================================

(defun create-collection (store name &key metadata)
  "Create a new collection in the store.

  Args:
    STORE: Vector store instance
    NAME: Collection name
    METADATA: Optional metadata

  Returns:
    Collection instance"
  (let ((collections (slot-value store 'collections)))
    (unless (gethash name collections)
      (let ((collection (make-instance 'vector-collection
                                       :name name
                                       :metadata metadata)))
        (setf (gethash name collections) collection)
        (log-info "Created collection: ~A in store ~A" name (vector-store-id store))
        collection))))

(defun delete-collection (store name)
  "Delete a collection from the store.

  Args:
    STORE: Vector store instance
    NAME: Collection name

  Returns:
    T on success"
  (let ((collections (slot-value store 'collections)))
    (when (gethash name collections)
      (remhash name collections)
      (log-info "Deleted collection: ~A" name)
      t)))

(defun list-collections (store)
  "List all collections in the store.

  Args:
    STORE: Vector store instance

  Returns:
    List of collection names"
  (let ((names nil))
    (maphash (lambda (k v)
               (declare (ignore v))
               (push k names))
             (slot-value store 'collections))
    names))

(defun get-collection (store name)
  "Get a collection by name.

  Args:
    STORE: Vector store instance
    NAME: Collection name

  Returns:
    Collection instance or NIL"
  (gethash name (slot-value store 'collections)))

;;; ============================================================================
;;; Vector Operations
;;; ============================================================================

(defun upsert-vector (store collection-name id vector &key metadata)
  "Insert or update a vector in a collection.

  Args:
    STORE: Vector store instance
    COLLECTION-NAME: Target collection
    ID: Vector identifier
    VECTOR: Vector data (list of floats)
    METADATA: Optional metadata

  Returns:
    T on success"
  (let ((collection (get-collection store collection-name)))
    (unless collection
      (setf collection (create-collection store collection-name)))

    (setf (gethash id (collection-vectors collection))
          (list :vector vector :metadata metadata :updated-at (get-universal-time)))
    (log-debug "Upserted vector ~A in collection ~A" id collection-name)
    t))

(defun get-vector (store collection-name id)
  "Get a vector by ID.

  Args:
    STORE: Vector store instance
    COLLECTION-NAME: Collection name
    ID: Vector identifier

  Returns:
    Vector plist or NIL"
  (let ((collection (get-collection store collection-name)))
    (when collection
      (gethash id (collection-vectors collection)))))

(defun delete-vector (store collection-name id)
  "Delete a vector from a collection.

  Args:
    STORE: Vector store instance
    COLLECTION-NAME: Collection name
    ID: Vector identifier

  Returns:
    T if vector was deleted"
  (let ((collection (get-collection store collection-name)))
    (when collection
      (when (gethash id (collection-vectors collection))
        (remhash id (collection-vectors collection))
        (log-debug "Deleted vector ~A from ~A" id collection-name)
        t))))

(defun vector-count (store collection-name)
  "Get the number of vectors in a collection.

  Args:
    STORE: Vector store instance
    COLLECTION-NAME: Collection name

  Returns:
    Number of vectors"
  (let ((collection (get-collection store collection-name)))
    (if collection
        (hash-table-count (collection-vectors collection))
        0)))

;;; ============================================================================
;;; Similarity Functions
;;; ============================================================================

(defun dot-product (vec1 vec2)
  "Compute dot product of two vectors.

  Args:
    VEC1: First vector (list of floats)
    VEC2: Second vector

  Returns:
    Dot product value"
  (reduce #'+ (mapcar #'* vec1 vec2)))

(defun magnitude (vec)
  "Compute magnitude (L2 norm) of a vector.

  Args:
    VEC: Vector (list of floats)

  Returns:
    Magnitude value"
  (sqrt (reduce #'+ (mapcar (lambda (x) (* x x)) vec))))

(defun cosine-similarity (vec1 vec2)
  "Compute cosine similarity between two vectors.

  Args:
    VEC1: First vector
    VEC2: Second vector

  Returns:
    Similarity value (-1.0 to 1.0)"
  (let ((dot (dot-product vec1 vec2))
        (mag1 (magnitude vec1))
        (mag2 (magnitude vec2)))
    (if (or (zerop mag1) (zerop mag2))
        0.0
        (/ dot (* mag1 mag2)))))

(defun euclidean-distance (vec1 vec2)
  "Compute Euclidean distance between two vectors.

  Args:
    VEC1: First vector
    VEC2: Second vector

  Returns:
    Distance value"
  (sqrt (reduce #'+ (mapcar (lambda (a b) (expt (- a b) 2)) vec1 vec2))))

;;; ============================================================================
;;; Search Operations
;;; ============================================================================

(defun search-vectors (store collection-name query-vector &key top-k filter)
  "Search for similar vectors in a collection.

  Args:
    STORE: Vector store instance
    COLLECTION-NAME: Collection to search
    QUERY-VECTOR: Query vector
    TOP-K: Number of results to return (default: 10)
    FILTER: Optional filter function (takes metadata, returns boolean)

  Returns:
    List of (id score metadata) sorted by similarity"
  (let ((collection (get-collection store collection-name)))
    (unless collection
      (return-from search-vectors nil))

    (let ((results nil))
      (maphash (lambda (id entry)
                 (let* ((metadata (getf entry :metadata))
                        (vector (getf entry :vector)))
                   (when (or (null filter) (funcall filter metadata))
                     (let ((score (cosine-similarity query-vector vector)))
                       (push (list :id id :score score :metadata metadata) results)))))
               (collection-vectors collection))

      ;; Sort by score descending
      (setf results (sort results #'> :key #'cadr))

      ;; Return top-k
      (subseq results 0 (min (or top-k 10) (length results))))))

;;; ============================================================================
;;; Batch Operations
;;; ============================================================================

(defun upsert-vectors-batch (store collection-name vectors-alist)
  "Insert or update multiple vectors.

  Args:
    STORE: Vector store instance
    COLLECTION-NAME: Target collection
    VECTORS-ALIST: List of (id vector &key metadata) plists

  Returns:
    Number of vectors inserted"
  (let ((count 0))
    (dolist (entry vectors-alist)
      (apply #'upsert-vector store collection-name entry)
      (incf count))
    (log-info "Batch upserted ~A vectors into ~A" count collection-name)
    count))

(defun search-vectors-batch (store collection-name query-vectors &key top-k filter)
  "Search with multiple query vectors.

  Args:
    STORE: Vector store instance
    COLLECTION-NAME: Collection to search
    QUERY-VECTORS: List of query vectors
    TOP-K: Results per query
    FILTER: Optional filter function

  Returns:
    List of result lists (one per query)"
  (mapcar (lambda (qv)
            (search-vectors store collection-name qv :top-k top-k :filter filter))
          query-vectors))
