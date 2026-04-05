;;; advanced/memory-compression.lisp --- Memory Compression and Summarization
;;;
;;; This file provides memory compression for long conversation summarization
;;; and memory consolidation to reduce token usage while preserving key information.

(defpackage #:lisp-claw.advanced.memory-compression
  (:nicknames #:lc.adv.memory-compression)
  (:use #:cl
        #:alexandria
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json
        #:lisp-claw.advanced.memory)
  (:export
   ;; Compression configuration
   #:*compression-threshold*
   #:*compression-target-ratio*
   #:*summarization-provider*
   ;; Memory compression
   #:compress-memory
   #:compress-memories-by-type
   #:compress-memories-by-age
   #:merge-similar-memories
   ;; Conversation summarization
   #:summarize-conversation
   #:summarize-memories
   #:extract-key-points
   #:create-memory-abstract
   ;; Key information extraction
   #:extract-key-entities
   #:extract-key-topics
   #:extract-action-items
   ;; Batch operations
   #:run-memory-compaction
   #:get-compression-stats
   ;; Initialization
   #:initialize-memory-compression-system))

(in-package #:lisp-claw.advanced.memory-compression)

;;; ============================================================================
;;; Configuration
;;; ============================================================================

(defvar *compression-threshold* 100
  "Number of memories triggering automatic compression.")

(defvar *compression-target-ratio* 0.3
  "Target compression ratio (0.3 = reduce to 30% of original).")

(defvar *summarization-provider* nil
  "AI provider for summarization (set by agent.core).")

(defvar *max-summary-length* 2000
  "Maximum length for generated summaries.")

(defvar *compression-stats*
  (list :compressions 0
        :summaries 0
        :memories-merged 0
        :tokens-saved 0)
  "Statistics for compression operations.")

;;; ============================================================================
;;; Utility Functions
;;; ============================================================================

(defun estimate-token-count (text)
  "Estimate token count for text.

  Args:
    TEXT: Input text

  Returns:
    Estimated token count (rough approximation: 1 token ≈ 4 characters)"
  (ceiling (length text) 4))

(defun calculate-similarity (text1 text2)
  "Calculate text similarity score.

  Args:
    TEXT1: First text
    TEXT2: Second text

  Returns:
    Similarity score 0.0-1.0"
  (let* ((words1 (remove-if-not #'alpha-char-p (string-downcase text1)))
         (words2 (remove-if-not #'alpha-char-p (string-downcase text2)))
         (set1 (remove-duplicates (coerce words1 'list)))
         (set2 (remove-duplicates (coerce words2 'list))))
    (if (or (null set1) (null set2))
        0.0
        (let ((intersection (length (intersection set1 set2 :test #'char=)))
              (union (length (union set1 set2 :test #'char=))))
          (if (zerop union)
              0.0
              (/ intersection union))))))

;;; ============================================================================
;;; Memory Compression
;;; ============================================================================

(defun compress-memory (memory &optional summarizer-fn)
  "Compress a single memory.

  Args:
    MEMORY: Memory instance to compress
    SUMMARIZER-FN: Optional summarization function (default: internal)

  Returns:
    Compressed memory instance"
  (let* ((original-content (memory-content memory))
         (original-tokens (estimate-token-count original-content))
         (compressed-content (if summarizer-fn
                                 (funcall summarizer-fn original-content)
                                 (summarize-text-baseline original-content)))
         (compressed-tokens (estimate-token-count compressed-content))
         (saved-tokens (- original-tokens compressed-tokens)))

    ;; Update memory with compressed content
    (setf (memory-content memory) compressed-content)

    ;; Update stats
    (incf (getf *compression-stats* :compressions))
    (incf (getf *compression-stats* :tokens-saved) saved-tokens)

    (log-info "Compressed memory: ~A -> ~A tokens (~A% reduction)"
              original-tokens
              compressed-tokens
              (floor (* 100 (/ (- original-tokens compressed-tokens)
                               (max 1 original-tokens)))))

    memory))

(defun compress-memories-by-type (type &key limit summarizer-fn)
  "Compress memories of a specific type.

  Args:
    TYPE: Memory type to compress
    LIMIT: Maximum number of memories to compress
    SUMMARIZER-FN: Optional summarization function

  Returns:
    Number of memories compressed"
  (let* ((memories (lisp-claw.advanced.memory::list-memories type))
         (sorted (sort (copy-list memories) #'>
                       :key #'memory-timestamp))
         (to-compress (if limit
                          (subseq sorted 0 (min limit (length sorted)))
                          sorted))
         (count 0))

    (dolist (memory to-compress)
      (when (>= (length (memory-content memory)) 200)  ; Only compress if substantial
        (compress-memory memory summarizer-fn)
        (incf count)))

    (log-info "Compressed ~A memories of type ~A" count type)
    count))

(defun compress-memories-by-age (&key (max-age 86400) summarizer-fn)
  "Compress memories older than specified age.

  Args:
    MAX-AGE: Maximum age in seconds (default: 1 day)
    SUMMARIZER-FN: Optional summarization function

  Returns:
    Number of memories compressed"
  (let ((now (get-universal-time))
        (count 0))

    (lisp-claw.advanced.memory::maphash (lambda (id memory)
                                          (declare (ignore id))
                                          (when (>= (- now (memory-timestamp memory)) max-age)
                                            (compress-memory memory summarizer-fn)
                                            (incf count)))
                                        lisp-claw.advanced.memory::*memory-store*))

    (log-info "Compressed ~A memories older than ~A seconds" count max-age)
    count))

(defun merge-similar-memories (&key (similarity-threshold 0.7) summarizer-fn)
  "Merge similar memories to reduce redundancy.

  Args:
    SIMILARITY-THRESHOLD: Minimum similarity to merge (0.0-1.0)
    SUMMARIZER-FN: Optional summarization function

  Returns:
    Number of merges performed"
  (let ((memories (lisp-claw.advanced.memory::list-memories))
        (merged-count 0)
        (processed (make-hash-table :test 'equal)))

    ;; Group by type first
    (let ((by-type (make-hash-table :test 'equal)))
      (dolist (memory memories)
        (let ((type (memory-type memory)))
          (push memory (gethash type by-type (list)))))

      ;; Process each type
      (maphash (lambda (type type-memories)
                 (let ((remaining type-memories))
                   (loop while remaining do
                     (let* ((current (first remaining))
                            (similar (remove-if
                                      (lambda (m)
                                        (< (calculate-similarity
                                            (memory-content current)
                                            (memory-content m))
                                           similarity-threshold))
                                      (rest remaining))))
                       (when similar
                         ;; Merge similar memories
                         (let* ((contents (mapcar #'memory-content (cons current similar)))
                                (merged-content (merge-texts contents summarizer-fn))
                                (new-memory (lisp-claw.advanced.memory::make-memory
                                             type merged-content
                                             :priority (apply #'max (mapcar #'memory-priority (cons current similar)))
                                             :tags (remove-duplicates
                                                    (mapcan #'memory-tags (cons current similar))
                                                    :test #'string=))))
                           ;; Store merged memory
                           (lisp-claw.advanced.memory::store-memory new-memory)
                           ;; Delete originals
                           (dolist (m (cons current similar))
                             (lisp-claw.advanced.memory::forget-memory (memory-id m)))
                           (incf merged-count)
                           (incf (getf *compression-stats* :memories-merged)))
                         (setf remaining (set-difference remaining (cons current similar) :test #'eq))
                         (setf remaining (rest remaining)))
                       (when (null similar)
                         (setf remaining (rest remaining)))))))
               by-type))

    (log-info "Merged ~A groups of similar memories" merged-count)
    merged-count))

;;; ============================================================================
;; Text Summarization Helpers
;;; ============================================================================

(defun summarize-text-baseline (text)
  "Baseline summarization using text extraction.

  Args:
    TEXT: Input text

  Returns:
    Summarized text"
  (let ((sentences (split-sentences text)))
    (cond
      ;; Too short to summarize
      ((<= (length sentences) 2) text)

      ;; Extract first and last sentences (common pattern for key info)
      (t (let ((summary (format nil "~A. ~A"
                                (first sentences)
                                (car (last sentences)))))
           (if (<= (length summary) *max-summary-length*)
               summary
               (subseq summary 0 *max-summary-length*)))))))

(defun split-sentences (text)
  "Split text into sentences.

  Args:
    TEXT: Input text

  Returns:
    List of sentences"
  (let ((sentences nil)
        (start 0)
        (len (length text)))
    (loop for i from 0 below len
          when (find (char text i) ".!?")
          do (progn
               (let ((sentence (string-trim '(#\Space) (subseq text start (1+ i)))))
                 (when (plusp (length sentence))
                   (push sentence sentences)))
               (setf start (1+ i))))
    ;; Add remaining text
    (when (< start len)
      (let ((sentence (string-trim '(#\Space) (subseq text start))))
        (when (plusp (length sentence))
          (push sentence sentences))))
    (nreverse sentences)))

(defun merge-texts (texts summarizer-fn)
  "Merge multiple texts into a summary.

  Args:
    TEXTS: List of texts to merge
    SUMMARIZER-FN: Optional summarization function

  Returns:
    Merged/summarized text"
  (let ((combined (format nil "~{~A~^ ~}" texts)))
    (if summarizer-fn
        (funcall summarizer-fn combined)
        (summarize-text-baseline combined))))

;;; ============================================================================
;;; Conversation Summarization
;;; ============================================================================

(defun summarize-conversation (messages &key provider max-summary-length)
  "Summarize a conversation.

  Args:
    MESSAGES: List of message plists (:role . :content)
    PROVIDER: AI provider for summarization
    MAX-SUMMARY-LENGTH: Maximum summary length

  Returns:
    Summary text and extracted key points"
  (let ((max-len (or max-summary-length *max-summary-length*))
        (summary nil)
        (key-points nil))

    ;; If provider available, use AI summarization
    (if provider
        (progn
          ;; TODO: Implement AI-based summarization when provider is available
          (log-info "Using AI provider for conversation summarization")
          (setf summary (ai-summarize-conversation messages provider max-len)))
        ;; Fallback to baseline extraction
        (progn
          (log-info "Using baseline summarization")
          (setf summary (baseline-summarize-conversation messages max-len))))

    ;; Extract key points
    (setf key-points (extract-key-points messages))

    ;; Update stats
    (incf (getf *compression-stats* :summaries))

    (list :summary summary
          :key-points key-points
          :message-count (length messages))))

(defun baseline-summarize-conversation (messages max-length)
  "Baseline conversation summarization without AI.

  Args:
    MESSAGES: List of message plists
    MAX-LENGTH: Maximum summary length

  Returns:
    Summary text"
  (let* ((contents (mapcar (lambda (msg) (getf msg :content)) messages))
         (combined (format nil "~{~A~^ ~}" contents))
         (sentences (split-sentences combined))
         (summary ""))

    ;; Take first, middle, and last sentences
    (let ((first-sent (first sentences))
          (mid-idx (floor (length sentences) 2))
          (last-sent (car (last sentences))))

      (setf summary (format nil "~A~@[. ~A~]~@[. ~A~]"
                            first-sent
                            (when (and mid-idx (> (length sentences) 2))
                              (nth mid-idx sentences))
                            last-sent))

      ;; Truncate if needed
      (when (> (length summary) max-length)
        (setf summary (subseq summary 0 max-length))))

    summary))

(defun ai-summarize-conversation (messages provider max-length)
  "AI-based conversation summarization.

  Args:
    MESSAGES: List of message plists
    PROVIDER: AI provider
    MAX-LENGTH: Maximum summary length

  Returns:
    Summary text"
  ;; Placeholder for AI-based summarization
  ;; This would call the provider's completion API with a summarization prompt
  (let ((prompt (format nil "Summarize the following conversation in ~A characters or less.
Focus on key decisions, action items, and important facts:

~{~A: ~A~%~}"
                        max-length
                        (mapcan (lambda (msg)
                                  (list (string-upcase (getf msg :role))
                                        (getf msg :content)))
                                messages))))
    ;; TODO: Call AI provider
    (declare (ignore provider))
    (log-info "AI summarization prompt: ~A..." (subseq prompt 0 (min 50 (length prompt))))
    "AI summarization placeholder - integrate with agent provider"))

(defun summarize-memories (memories &key summarizer-fn)
  "Summarize a list of memories.

  Args:
    MEMORIES: List of memories to summarize
    SUMMARIZER-FN: Optional summarization function

  Returns:
    Summary plist"
  (let ((contents (mapcar #'memory-content memories))
        (combined (format nil "~{~A~^~%~}" contents)))

    (list :summary (if summarizer-fn
                       (funcall summarizer-fn combined)
                       (summarize-text-baseline combined))
          :source-count (length memories)
          :source-types (remove-duplicates (mapcar #'memory-type memories))
          :timestamp (get-universal-time))))

(defun extract-key-points (messages)
  "Extract key points from conversation.

  Args:
    MESSAGES: List of message plists

  Returns:
    List of key points"
  (let ((key-points nil))

    ;; Look for patterns indicating important information
    (dolist (msg messages)
      (let ((content (getf msg :content))
            (role (getf msg :role)))

        ;; Extract action items
        (when (or (search "TODO" content :test #'string=)
                  (search "need to" content :test #'string=)
                  (search "should" content :test #'string=))
          (push (list :type :action-item
                      :content content
                      :role role)
                key-points))

        ;; Extract decisions
        (when (or (search "decided" content :test #'string=)
                  (search "conclusion" content :test #'string=)
                  (search "agreed" content :test #'string=))
          (push (list :type :decision
                      :content content
                      :role role)
                key-points))

        ;; Extract facts/definitions
        (when (or (search "is" content :test #'string=)
                  (search "means" content :test #'string=)
                  (search "defined" content :test #'string=))
          (push (list :type :fact
                      :content content
                      :role role)
                key-points))))

    key-points))

;;; ============================================================================
;;; Key Information Extraction
;;; ============================================================================

(defun extract-key-entities (text)
  "Extract key entities from text.

  Args:
    TEXT: Input text

  Returns:
    List of extracted entities"
  (let ((entities nil))

    ;; Extract potential named entities (capitalized words, numbers, etc.)
    (let ((words (split-sequence:split-sequence #\Space text)))
      (dolist (word words)
        (let ((clean (string-trim '(#\Space #\Tab #\Newline #\. #\, #\; #\:) word)))
          (when (and (> (length clean) 1)
                     (char-upper-case-p (char clean 0)))
            (push clean entities)))))

    (remove-duplicates entities :test #'string=)))

(defun extract-key-topics (text)
  "Extract key topics from text.

  Args:
    TEXT: Input text

  Returns:
    List of topics"
  (let ((topics nil)
        ;; Common topic indicators
        (indicators '("about" "regarding" "concerning" "topic" "subject" "theme")))

    (let ((sentences (split-sentences text)))
      (dolist (sentence sentences)
        (dolist (indicator indicators)
          (when (search indicator sentence :test #'string=)
            (push sentence topics)))))

    topics))

(defun extract-action-items (text)
  "Extract action items from text.

  Args:
    TEXT: Input text

  Returns:
    List of action items with metadata"
  (let ((items nil)
        (patterns '("TODO" "FIXME" "XXX" "need to" "should" "must" "have to")))

    (let ((sentences (split-sentences text)))
      (dolist (sentence sentences)
        (dolist (pattern patterns)
          (when (search pattern sentence :test #'string=)
            (push (list :text sentence
                        :priority (cond
                                    ((search "must" sentence) :high)
                                    ((search "should" sentence) :medium)
                                    (t :low)))
                  items)))))

    items))

;;; ============================================================================
;;; Batch Operations
;;; ============================================================================

(defun run-memory-compaction (&key compress-old merge-similar summarize-long)
  "Run comprehensive memory compaction.

  Args:
    COMPRESS-OLD: Compress old memories (default: T)
    MERGE-SIMILAR: Merge similar memories (default: T)
    SUMMARIZE-LONG: Summarize long conversations (default: T)

  Returns:
    Compaction results plist"
  (let ((results nil)
        (start-time (get-universal-time)))

    (log-info "Starting memory compaction...")

    ;; Compress old memories
    (when compress-old
      (let ((count (compress-memories-by-age)))
        (setf results (plist-put results :compressed-old count))))

    ;; Merge similar memories
    (when merge-similar
      (let ((count (merge-similar-memories)))
        (setf results (plist-put results :merged-similar count))))

    ;; Get final stats
    (setf results (plist-put results :stats *compression-stats*))
    (setf results (plist-put results :duration (- (get-universal-time) start-time)))

    (log-info "Memory compaction completed in ~A seconds" (plist-get results :duration))

    results))

(defun get-compression-stats ()
  "Get compression statistics.

  Returns:
    Stats plist"
  (let ((memory-stats (lisp-claw.advanced.memory::get-memory-stats)))
    (list :compression-stats *compression-stats*
          :memory-stats memory-stats
          :compression-ratio (if (plusp (getf memory-stats :total))
                                 (float (/ (getf *compression-stats* :tokens-saved)
                                           (* (getf memory-stats :total) 100)))
                                 0))))

;;; ============================================================================
;;; Session History Compression
;;; ============================================================================

(defun compress-session-history (session max-age compress-threshold)
  "Compress a session's conversation history.

  Args:
    SESSION: Session instance
    MAX-AGE: Age threshold for compression
    COMPRESS-THRESHOLD: Length threshold for compression

  Returns:
    Number of messages compressed"
  ;; This would integrate with session.lisp
  ;; Placeholder for future integration
  (log-info "Session history compression not yet integrated with session.lisp")
  0)

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-memory-compression-system (&key provider)
  "Initialize the memory compression system.

  Args:
    PROVIDER: Optional AI provider for summarization

  Returns:
    T"
  (setf *summarization-provider* provider)
  (log-info "Memory compression system initialized")
  t)
