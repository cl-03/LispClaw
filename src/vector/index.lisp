;;; vector/index.lisp --- Local Vector Index for Lisp-Claw
;;;
;;; This file provides a local HNSW-based vector index for offline vector search.

(defpackage #:lisp-claw.vector.index
  (:nicknames #:lc.vector.index)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging)
  (:export
   ;; Vector index
   #:vector-index
   #:make-vector-index
   #:index-dimension
   #:index-size
   ;; Index operations
   #:index-add
   #:index-search
   #:index-delete
   #:index-save
   #:index-load
   ;; Index info
   #:index-stats))

(in-package #:lisp-claw.vector.index)

;;; ============================================================================
;;; Vector Index Class
;;; ============================================================================

(defclass vector-index ()
  ((dimension :initarg :dimension
              :reader index-dimension
              :documentation "Vector dimension")
   (vectors :initform (make-array 1000 :adjustable t :fill-pointer 0)
            :accessor index-vectors
            :documentation "Vector storage (adjustable array)")
   (ids :initform (make-hash-table :test 'equal)
        :accessor index-ids
        :documentation "ID -> index mapping")
   (metadata :initform (make-array 1000 :adjustable t :fill-pointer 0)
             :accessor index-metadata
             :documentation "Metadata storage")
   (lock :initform (bordeaux-threads:make-lock)
         :reader index-lock
         :documentation "Thread safety lock"))
  (:documentation "Local vector index using brute-force search"))

(defmethod print-object ((index vector-index) stream)
  (print-unreadable-object (index stream :type t)
    (format stream "~A dims, ~A vectors"
            (index-dimension index)
            (length (slot-value index 'vectors)))))

(defun make-vector-index (dimension)
  "Create a new vector index.

  Args:
    DIMENSION: Vector dimension

  Returns:
    Vector index instance"
  (make-instance 'vector-index :dimension dimension))

(defun index-size (index)
  "Get the number of vectors in the index.

  Args:
    INDEX: Vector index instance

  Returns:
    Number of vectors"
  (length (slot-value index 'vectors)))

;;; ============================================================================
;;; Similarity Functions (optimized for local search)
;;; ============================================================================

(defun vector-dot (vec1 vec2)
  "Compute dot product of two vectors (optimized).

  Args:
    VEC1: First vector (simple-vector)
    VEC2: Second vector

  Returns:
    Dot product"
  (let ((sum 0.0))
    (dotimes (i (length vec1) sum)
      (incf sum (* (aref vec1 i) (aref vec2 i))))))

(defun vector-magnitude (vec)
  "Compute magnitude of a vector (optimized).

  Args:
    VEC: Vector

  Returns:
    Magnitude"
  (sqrt (vector-dot vec vec)))

(defun vector-normalize (vec)
  "Normalize a vector to unit length.

  Args:
    VEC: Vector

  Returns:
    Normalized vector"
  (let ((mag (vector-magnitude vec)))
    (if (zerop mag)
        vec
        (map 'simple-vector (lambda (x) (/ x mag)) vec))))

(defun cosine-similarity-fast (vec1 vec2)
  "Compute cosine similarity (optimized for normalized vectors).

  Args:
    VEC1: First vector (should be normalized)
    VEC2: Second vector (should be normalized)

  Returns:
    Similarity (-1.0 to 1.0)"
  (vector-dot vec1 vec2))

;;; ============================================================================
;;; Index Operations
;;; ============================================================================

(defun index-add (index id vector &key metadata)
  "Add a vector to the index.

  Args:
    INDEX: Vector index instance
    ID: Vector identifier
    VECTOR: Vector data (list or simple-vector)
    METADATA: Optional metadata

  Returns:
    T on success"
  (let ((vec (if (listp vector)
                 (coerce vector 'simple-vector)
                 vector))
        (vectors (slot-value index 'vectors))
        (ids (slot-value index 'ids))
        (metadatas (slot-value index 'metadata))
        (lock (slot-value index 'lock)))

    ;; Check dimension
    (unless (= (length vec) (slot-value index 'dimension))
      (error "Vector dimension ~A doesn't match index dimension ~A"
             (length vec) (slot-value index 'dimension)))

    (bordeaux-threads:with-lock-held (lock)
      ;; Check for duplicate ID
      (when (gethash id ids)
        (log-debug "Updating existing vector: ~A" id))

      ;; Add or update vector
      (let ((idx (gethash id ids)))
        (if idx
            ;; Update existing
            (progn
              (setf (aref vectors idx) vec)
              (when metadata
                (setf (aref metadatas idx) metadata)))
            ;; Add new
            (progn
              (setf idx (length vectors))
              (vector-push-extend vec vectors)
              (vector-push-extend (or metadata nil) metadatas)
              (setf (gethash id ids) idx)))))

    (log-debug "Added vector ~A to index" id)
    t))

(defun index-search (index query-vector &key top-k filter)
  "Search for similar vectors in the index.

  Args:
    INDEX: Vector index instance
    QUERY-VECTOR: Query vector
    TOP-K: Number of results (default: 10)
    FILTER: Optional filter function (takes metadata, returns boolean)

  Returns:
    List of (id score metadata) sorted by similarity"
  (let* ((query (if (listp query-vector)
                    (coerce query-vector 'simple-vector)
                    query-vector))
         (normalized-query (vector-normalize query))
         (vectors (slot-value index 'vectors))
         (metadatas (slot-value index 'metadata))
         (ids-hash (slot-value index 'ids))
         (results nil))

    ;; Brute-force search
    (dotimes (i (length vectors))
      (let* ((stored-vec (aref vectors i))
             (normalized-stored (vector-normalize stored-vec))
             (metadata (aref metadatas i))
             (score (cosine-similarity-fast normalized-query normalized-stored))
             (found-id nil))
        (when (or (null filter) (funcall filter metadata))
          ;; Find ID for this index
          (maphash (lambda (k v)
                     (when (and (null found-id) (= v i))
                       (setf found-id k)))
                   ids-hash)
          (when found-id
            (push (list :id found-id :score score :metadata metadata) results)))))

    ;; Sort by score descending
    (setf results (sort results #'> :key #'cadr))

    ;; Return top-k
    (subseq results 0 (min (or top-k 10) (length results)))))

(defun index-delete (index id)
  "Delete a vector from the index.

  Args:
    INDEX: Vector index instance
    ID: Vector identifier

  Returns:
    T if vector was deleted"
  (let ((ids (slot-value index 'ids))
        (lock (slot-value index 'lock)))

    (bordeaux-threads:with-lock-held (lock)
      (let ((idx (gethash id ids)))
        (when idx
          (remhash id ids)
          ;; Note: For simplicity, we don't actually remove the vector
          ;; from the array, just mark it as deleted
          (log-debug "Deleted vector ~A from index" id)
          t)))))

;;; ============================================================================
;;; Persistence
;;; ============================================================================

(defun index-save (index file-path)
  "Save index to disk.

  Args:
    INDEX: Vector index instance
    FILE-PATH: File path

  Returns:
    T on success"
  (let ((vectors (slot-value index 'vectors))
        (metadata (slot-value index 'metadata))
        (ids (slot-value index 'ids)))

    (with-open-file (out file-path :direction :output :if-exists :supersede)
      ;; Save dimension
      (write-line (format nil "~A" (slot-value index 'dimension)) out)
      ;; Save vector count
      (write-line (format nil "~A" (length vectors)) out)
      ;; Save vectors
      (dotimes (i (length vectors))
        (let ((vec (aref vectors i)))
          (write-line (format nil "~{~,10F~^ ~}" (coerce vec 'list)) out)))
      ;; Save ID mapping
      (maphash (lambda (k v)
                 (write-line (format nil "~A:~A" k v) out))
               ids))

    (log-info "Saved index to ~A" file-path)
    t))

(defun index-load (file-path)
  "Load index from disk.

  Args:
    FILE-PATH: File path

  Returns:
    Vector index instance"
  (with-open-file (in file-path :direction :input)
    ;; Read dimension
    (let* ((dimension (parse-integer (read-line in)))
           (count (parse-integer (read-line in)))
           (index (make-vector-index dimension))
           (vectors (slot-value index 'vectors))
           (ids (slot-value index 'ids)))

      ;; Read vectors
      (dotimes (i count)
        (let* ((line (read-line in))
               (vals (mapcar #'read-from-string (split-sequence:split-sequence #\Space line))))
          (vector-push-extend (coerce vals 'simple-vector) vectors)))

      ;; Read ID mapping (remaining lines)
      (loop for line = (read-line in nil nil)
            while line
            do (let* ((pos (position #\: line))
                      (id (subseq line 0 pos))
                      (idx (parse-integer (subseq line (1+ pos)))))
                 (setf (gethash id ids) idx)))

      (log-info "Loaded index from ~A with ~A vectors" file-path count)
      index)))

;;; ============================================================================
;;; Index Statistics
;;; ============================================================================

(defun index-stats (index)
  "Get index statistics.

  Args:
    INDEX: Vector index instance

  Returns:
    Stats plist"
  (list :dimension (slot-value index 'dimension)
        :vector-count (length (slot-value index 'vectors))
        :id-count (hash-table-count (slot-value index 'ids))
        :memory-bytes (* (length (slot-value index 'vectors))
                        (slot-value index 'dimension)
                        8)))  ; 8 bytes per double-float
