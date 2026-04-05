;;; tools/git.lisp --- Git Tool for Lisp-Claw
;;;
;;; This file implements Git version control integration:
;;; - Repository operations (clone, init, status)
;;; - Branch management
;;; - Commit operations
;;; - Remote operations (fetch, pull, push)
;;; - Diff and log
;;; - Tag management

(defpackage #:lisp-claw.tools.git
  (:nicknames #:lc.tools.git)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; Git class
   #:git-repository
   #:make-git-repository
   #:git-path
   #:git-open
   #:git-close
   ;; Repository operations
   #:git-init
   #:git-clone
   #:git-status
   #:git-info
   ;; Branch operations
   #:git-branch
   #:git-current-branch
   #:git-checkout
   #:git-create-branch
   #:git-delete-branch
   #:git-list-branches
   ;; Commit operations
   #:git-commit
   #:git-add
   #:git-add-all
   #:git-remove
   #:git-log
   #:git-show
   #:git-diff
   ;; Remote operations
   #:git-fetch
   #:git-pull
   #:git-push
   #:git-remote-add
   #:git-remote-list
   ;; Tag operations
   #:git-tag
   #:git-list-tags
   #:git-tag-info
   ;; Blame
   #:git-blame))

(in-package #:lisp-claw.tools.git)

;;; ============================================================================
;;; Git Repository Class
;;; ============================================================================

(defclass git-repository ()
  ((path :initarg :path
         :reader git-path
         :documentation "Repository path")
   (open-p :initform nil
           :accessor git-open-p
           :documentation "Whether repository is open")
   (last-error :initform nil
               :accessor git-last-error
               :documentation "Last error message")
   (last-command :initform nil
                 :accessor git-last-command
                 :documentation "Last executed command"))
  (:documentation "Git repository representation"))

(defmethod print-object ((repo git-repository) stream)
  (print-unreadable-object (repo stream :type t)
    (format t "~A [~A]"
            (git-path repo)
            (if (git-open-p repo) "open" "closed"))))

;;; ============================================================================
;;; Construction
;;; ============================================================================

(defun make-git-repository (path)
  "Create a git repository instance.

  Args:
    PATH: Repository path

  Returns:
    Git repository instance"
  (make-instance 'git-repository :path path))

(defun git-open (repo)
  "Open a git repository.

  Args:
    REPO: Git repository instance

  Returns:
    T on success"
  (let ((path (git-path repo)))
    (unless (uiop:directory-exists-p path)
      (setf (git-last-error repo) (format nil "Path does not exist: ~A" path))
      (return-from git-open nil))
    (unless (uiop:directory-exists-p (make-pathname :directory (append (pathname-directory path) '(".git"))))
      (setf (git-last-error repo) (format nil "Not a git repository: ~A" path))
      (return-from git-open nil))
    (setf (git-open-p repo) t)
    (log-info "Git repository opened: ~A" path)
    t))

(defun git-close (repo)
  "Close a git repository.

  Args:
    REPO: Git repository instance

  Returns:
    T on success"
  (setf (git-open-p repo) nil)
  (log-info "Git repository closed: ~A" (git-path repo))
  t)

;;; ============================================================================
;;; Git Command Execution
;;; ============================================================================

(defun git-run (repo command &rest args &key timeout)
  "Execute a git command.

  Args:
    REPO: Git repository instance
    COMMAND: Git subcommand
    ARGS: Command arguments
    TIMEOUT: Timeout in seconds

  Returns:
    Values: (output exit-code)"
  (let* ((cmd-args (list* "git" command
                          (loop for arg in args
                                when (keywordp arg)
                                append (list (format nil "--~A" (string-downcase (symbol-name arg))))
                                else collect (string arg))))
         (cmd-str (format nil "~{~A~^ ~}" cmd-args)))
    (setf (git-last-command repo) cmd-str)
    (handler-case
        (let ((result (uiop:run-program cmd-str
                                        :output :string
                                        :error-output :string
                                        :directory (git-path repo)
                                        :ignore-error-status t
                                        :timeout (or timeout 60))))
          (let ((output (getf result :output))
                (error (getf result :error-output))
                (exit-code (getf result :exit-code)))
            (if (zerop exit-code)
                (values output exit-code)
                (progn
                  (setf (git-last-error repo) error)
                  (log-error "Git command failed: ~A - ~A" cmd-str error)
                  (values nil exit-code)))))
      (error (e)
        (setf (git-last-error repo) (format nil "~A" e))
        (log-error "Git command error: ~A - ~A" cmd-str e)
        (values nil -1)))))

;;; ============================================================================
;;; Repository Operations
;;; ============================================================================

(defun git-init (path &key bare initial-branch)
  "Initialize a git repository.

  Args:
    PATH: Repository path
    BARE: Create bare repository
    INITIAL-BRANCH: Initial branch name

  Returns:
    Git repository instance or NIL"
  (let ((repo (make-git-repository path)))
    (multiple-value-bind (output exit-code)
        (let ((args (list "--quiet" "init")))
          (when bare (push "--bare" args))
          (when initial-branch (push (format nil "--initial-branch=~A" initial-branch) args))
          (apply #'uiop:run-program "git" args :output :string :directory path))
      (if (zerop exit-code)
          (progn
            (git-open repo)
            (log-info "Git repository initialized: ~A" path)
            repo)
          (progn
            (log-error "Git init failed: ~A" output)
            nil)))))

(defun git-clone (url path &key depth branch recursive)
  "Clone a git repository.

  Args:
    URL: Repository URL
    PATH: Target path
    DEPTH: Shallow clone depth
    BRANCH: Branch to clone
    RECURSIVE: Clone submodules

  Returns:
    Git repository instance or NIL"
  (let ((args (list "clone" "--quiet" url path)))
    (when depth (push (list "--depth" (format nil "~A" depth)) args))
    (when branch (push "--branch" args) (push branch args))
    (when recursive (push "--recursive" args))
    (handler-case
        (let ((result (apply #'uiop:run-program args :output :string :error-output :string)))
          (let ((exit-code (getf result :exit-code)))
            (if (zerop exit-code)
                (let ((repo (make-git-repository path)))
                  (git-open repo)
                  (log-info "Git repository cloned: ~A" url)
                  repo)
                (progn
                  (log-error "Git clone failed: ~A" (getf result :error-output))
                  nil))))
      (error (e)
        (log-error "Git clone error: ~A" e)
        nil))))

(defun git-status (repo)
  "Get repository status.

  Args:
    REPO: Git repository instance

  Returns:
    Status plist or NIL"
  (multiple-value-bind (output exit-code) (git-run repo "status" "--porcelain" "--branch")
    (when (and output (zerop exit-code))
      (let ((lines (split-sequence:split-sequence #\Newline output))
            (branch nil)
            (changes nil))
        (dolist (line lines)
          (cond
            ((string= "## " (subseq line 0 3))
             (setf branch (parse-status-header (subseq line 3))))
            ((plusp (length line))
             (push (parse-status-line line) changes))))
        (list :branch branch
              :changes (nreverse changes)
              :clean (null changes))))))

(defun parse-status-header (line)
  "Parse git status header line.

  Args:
    LINE: Status header line

  Returns:
    Plist with branch info"
  (let ((parts (split-sequence:split-sequence #\Space line)))
    (list :name (first parts)
          :behind (when (position "behind" parts :test #'string=)
                    (parse-integer (nth (1+ (position "behind" parts :test #'string=)) parts)))
          :ahead (when (position "ahead" parts :test #'string=)
                   (parse-integer (nth (1+ (position "ahead" parts :test #'string=)) parts))))))

(defun parse-status-line (line)
  "Parse git status line.

  Args:
    LINE: Status line

  Returns:
    Plist with file info"
  (let ((x (char line 0))
        (y (char line 1))
        (path (string-trim '(#\Space) (subseq line 3))))
    (list :path path
          :staged (if (member x '(?M ?A ?D ?R)) :staged :unstaged)
          :change (cond
                    ((char= x ?M) :modified)
                    ((char= x ?A) :added)
                    ((char= x ?D) :deleted)
                    ((char= x ?R) :renamed)
                    ((char= x ??) :untracked)
                    (t :unknown)))))

(defun git-info (repo)
  "Get repository info.

  Args:
    REPO: Git repository instance

  Returns:
    Info plist"
  (multiple-value-bind (branch _) (git-run repo "branch" "--show-current")
    (multiple-value-bind (remote _) (git-run repo "remote" "get-url" "origin")
      (multiple-value-bind (log _) (git-run repo "log" "-1" "--format=%H %s")
        (list :path (git-path repo)
              :branch (when branch (string-trim '(#\Newline #\Return) branch))
              :remote (when remote (string-trim '(#\Newline #\Return) remote))
              :head (when log (first (split-sequence:split-sequence #\Space log))))))))

;;; ============================================================================
;;; Branch Operations
;;; ============================================================================

(defun git-current-branch (repo)
  "Get current branch name.

  Args:
    REPO: Git repository instance

  Returns:
    Branch name or NIL"
  (multiple-value-bind (output _) (git-run repo "branch" "--show-current")
    (when output
      (string-trim '(#\Newline #\Return) output))))

(defun git-list-branches (repo &key remote)
  "List all branches.

  Args:
    REPO: Git repository instance
    REMOTE: List remote branches

  Returns:
    List of branch names"
  (multiple-value-bind (output _) (git-run repo "branch" (if remote "--remote" "--all"))
    (when output
      (loop for line in (split-sequence:split-sequence #\Newline output)
            when (plusp (length line))
            collect (string-trim '(#\Space #\* #\Newline #\Return) line)))))

(defun git-create-branch (repo name &key start-point)
  "Create a new branch.

  Args:
    REPO: Git repository instance
    NAME: Branch name
    START-POINT: Starting point (commit or branch)

  Returns:
    T on success"
  (multiple-value-bind (output exit-code)
      (if start-point
          (git-run repo "branch" name start-point)
          (git-run repo "branch" name))
    (when (zerop exit-code)
      (log-info "Branch created: ~A" name)
      t)))

(defun git-delete-branch (repo name &key force)
  "Delete a branch.

  Args:
    REPO: Git repository instance
    NAME: Branch name
    FORCE: Force deletion

  Returns:
    T on success"
  (multiple-value-bind (output exit-code)
      (git-run repo "branch" (if force "--delete" "--delete") name)
    (when (zerop exit-code)
      (log-info "Branch deleted: ~A" name)
      t)))

(defun git-checkout (repo branch-or-commit)
  "Checkout a branch or commit.

  Args:
    REPO: Git repository instance
    BRANCH-OR-COMMIT: Branch name or commit SHA

  Returns:
    T on success"
  (multiple-value-bind (output exit-code) (git-run repo "checkout" branch-or-commit)
    (when (zerop exit-code)
      (log-info "Checked out: ~A" branch-or-commit)
      t)))

(defun git-branch (repo name &key create checkout)
  "Branch operation (combined).

  Args:
    REPO: Git repository instance
    NAME: Branch name
    CREATE: Create if not exists
    CHECKOUT: Checkout after creation

  Returns:
    T on success"
  (when create
    (git-create-branch repo name))
  (when checkout
    (git-checkout repo name))
  t)

;;; ============================================================================
;;; Commit Operations
;;; ============================================================================

(defun git-add (repo paths)
  "Stage files for commit.

  Args:
    REPO: Git repository instance
    PATHS: File paths (list or string)

  Returns:
    T on success"
  (let ((path-list (if (listp paths) paths (list paths))))
    (multiple-value-bind (output exit-code)
        (apply #'git-run repo "add" path-list)
      (when (zerop exit-code)
        (log-info "Files staged: ~A" path-list)
        t))))

(defun git-add-all (repo)
  "Stage all changes.

  Args:
    REPO: Git repository instance

  Returns:
    T on success"
  (multiple-value-bind (output exit-code) (git-run repo "add" "--all")
    (when (zerop exit-code)
      (log-info "All changes staged")
      t)))

(defun git-remove (repo paths &key cached)
  "Remove files.

  Args:
    REPO: Git repository instance
    PATHS: File paths
    CACHED: Remove from index only

  Returns:
    T on success"
  (let ((path-list (if (listp paths) paths (list paths))))
    (multiple-value-bind (output exit-code)
        (if cached
            (apply #'git-run repo "rm" "--cached" path-list)
            (apply #'git-run repo "rm" path-list))
      (when (zerop exit-code)
        (log-info "Files removed: ~A" path-list)
        t))))

(defun git-commit (repo message &key all author no-verify)
  "Create a commit.

  Args:
    REPO: Git repository instance
    MESSAGE: Commit message
    ALL: Stage all changes before commit
    AUTHOR: Author string
    NO-VERIFY: Skip hooks

  Returns:
    Commit SHA or NIL"
  (when all
    (git-add-all repo))
  (let ((args (list "commit" "--quiet" "--message" message)))
    (when author (push "--author" args) (push author args))
    (when no-verify (push "--no-verify" args))
    (multiple-value-bind (output exit-code) (apply #'git-run repo args)
      (when (zerop exit-code)
        (let ((sha (git-run repo "rev-parse" "HEAD")))
          (log-info "Commit created: ~A" sha)
          (string-trim '(#\Newline #\Return) sha))))))

(defun git-log (repo &key count since until author grep)
  "Get commit log.

  Args:
    REPO: Git repository instance
    COUNT: Number of commits
    SINCE: Since date
    UNTIL: Until date
    AUTHOR: Filter by author
    GREP: Search in messages

  Returns:
    List of commit plists"
  (let ((args (list "log" "--format=%H|%an|%ae|%ai|%s" "--oneline")))
    (when count (push (format nil "-~A" count) args))
    (when since (push (format nil "--since=~A" since) args))
    (when until (push (format nil "--until=~A" until) args))
    (when author (push (format nil "--author=~A" author) args))
    (when grep (push (format nil "--grep=~A" grep) args))
    (multiple-value-bind (output exit-code) (apply #'git-run repo args)
      (when (and output (zerop exit-code))
        (loop for line in (split-sequence:split-sequence #\Newline output)
              when (plusp (length line))
              collect (parse-log-line line))))))

(defun parse-log-line (line)
  "Parse git log line.

  Args:
    LINE: Log line

  Returns:
    Commit plist"
  (let ((parts (split-sequence:split-sequence #\| line)))
    (if (= (length parts) 5)
        (list :sha (nth 0 parts)
              :author-name (nth 1 parts)
              :author-email (nth 2 parts)
              :date (nth 3 parts)
              :subject (nth 4 parts))
        (list :sha (first parts)
              :subject (second parts)))))

(defun git-show (repo commit)
  "Show commit details.

  Args:
    REPO: Git repository instance
    COMMIT: Commit SHA

  Returns:
    Commit details plist"
  (multiple-value-bind (output _) (git-run repo "show" "--stat" commit)
    (when output
      (list :commit commit
            :content output))))

(defun git-diff (repo &key staged path commit)
  "Show diff.

  Args:
    REPO: Git repository instance
    STAGED: Diff staged changes
    PATH: Specific file path
    COMMIT: Compare with commit

  Returns:
    Diff output or NIL"
  (let ((args (list "diff" "--color=never")))
    (when staged (push "--staged" args))
    (when commit (push commit args))
    (when path (push "--" args) (push path args))
    (multiple-value-bind (output _) (apply #'git-run repo args)
      output)))

;;; ============================================================================
;;; Remote Operations
;;; ============================================================================

(defun git-fetch (repo &key remote all)
  "Fetch from remote.

  Args:
    REPO: Git repository instance
    REMOTE: Remote name
    ALL: Fetch all remotes

  Returns:
    T on success"
  (let ((args (list "fetch" "--quiet")))
    (cond
      (all (push "--all" args))
      (remote (push remote args)))
    (multiple-value-bind (output exit-code) (apply #'git-run repo args)
      (when (zerop exit-code)
        (log-info "Fetch completed")
        t))))

(defun git-pull (repo &key remote branch rebase)
  "Pull from remote.

  Args:
    REPO: Git repository instance
    REMOTE: Remote name
    BRANCH: Branch name
    REBASE: Use rebase instead of merge

  Returns:
    T on success"
  (let ((args (list "pull" "--quiet")))
    (when rebase (push "--rebase" args))
    (when remote (push remote args))
    (when branch (push branch args))
    (multiple-value-bind (output exit-code) (apply #'git-run repo args)
      (when (zerop exit-code)
        (log-info "Pull completed")
        t))))

(defun git-push (repo &key remote branch force set-upstream)
  "Push to remote.

  Args:
    REPO: Git repository instance
    REMOTE: Remote name
    BRANCH: Branch name
    FORCE: Force push
    SET-UPSTREAM: Set upstream

  Returns:
    T on success"
  (let ((args (list "push" "--quiet")))
    (when force (push "--force" args))
    (when set-upstream (push "--set-upstream" args))
    (when remote (push remote args))
    (when branch (push branch args))
    (multiple-value-bind (output exit-code) (apply #'git-run repo args)
      (when (zerop exit-code)
        (log-info "Push completed")
        t))))

(defun git-remote-add (repo name url)
  "Add a remote.

  Args:
    REPO: Git repository instance
    NAME: Remote name
    URL: Remote URL

  Returns:
    T on success"
  (multiple-value-bind (output exit-code) (git-run repo "remote" "add" name url)
    (when (zerop exit-code)
      (log-info "Remote added: ~A -> ~A" name url)
      t)))

(defun git-remote-list (repo)
  "List remotes.

  Args:
    REPO: Git repository instance

  Returns:
    List of remote plists"
  (multiple-value-bind (output _) (git-run repo "remote" "-v")
    (when output
      (let ((remotes nil))
        (loop for line in (split-sequence:split-sequence #\Newline output)
              when (and (plusp (length line)) (search "(fetch)" line))
              do (let ((parts (split-sequence:split-sequence #\Space line)))
                   (when (>= (length parts) 3)
                     (push (list :name (first parts)
                                 :url (second parts)
                                 :type "fetch")
                           remotes))))
        (nreverse remotes)))))

;;; ============================================================================
;;; Tag Operations
;;; ============================================================================

(defun git-tag (repo name &key message commit sign)
  "Create a tag.

  Args:
    REPO: Git repository instance
    NAME: Tag name
    MESSAGE: Tag message
    COMMIT: Commit to tag
    SIGN: Sign the tag

  Returns:
    T on success"
  (let ((args (list "tag" name)))
    (when message (push "--message" args) (push message args))
    (when sign (push "--sign" args))
    (when commit (push commit args))
    (multiple-value-bind (output exit-code) (apply #'git-run repo args)
      (when (zerop exit-code)
        (log-info "Tag created: ~A" name)
        t))))

(defun git-list-tags (repo &key pattern)
  "List tags.

  Args:
    REPO: Git repository instance
    PATTERN: Tag pattern

  Returns:
    List of tag names"
  (let ((args (list "tag")))
    (when pattern (push "--list" args) (push pattern args))
    (multiple-value-bind (output _) (apply #'git-run repo args)
      (when output
        (loop for line in (split-sequence:split-sequence #\Newline output)
              when (plusp (length line))
              collect line)))))

(defun git-tag-info (repo tag)
  "Get tag info.

  Args:
    REPO: Git repository instance
    TAG: Tag name

  Returns:
    Tag info plist"
  (multiple-value-bind (output _) (git-run repo "show" tag)
    (when output
      (list :name tag
            :content output))))

;;; ============================================================================
;;; Blame
;;; ============================================================================

(defun git-blame (repo path &key line start-line end-line)
  "Get blame for a file.

  Args:
    REPO: Git repository instance
    PATH: File path
    LINE: Specific line number
    START-LINE: Start line range
    END-LINE: End line range

  Returns:
    Blame info plist"
  (let ((args (list "blame" "--line-porcelain")))
    (when line (push "-L" args) (push (format nil "~A,+1" line) args))
    (when (and start-line end-line) (push "-L" args) (push (format nil "~A,~A" start-line end-line) args))
    (push "--" args)
    (push path args)
    (multiple-value-bind (output _) (apply #'git-run repo args)
      (when output
        (parse-blame-output output)))))

(defun parse-blame-output (output)
  "Parse git blame porcelain output.

  Args:
    OUTPUT: Blame output

  Returns:
    List of blame entries"
  (let ((lines (split-sequence:split-sequence #\Newline output))
        (entries nil)
        (current nil))
    (dolist (line lines)
      (cond
        ((and (>= (length line) 40)
              (every #'alphanumericp (subseq line 0 40)))
         (when current
           (push current entries))
         (setf current (list :sha (subseq line 0 40))))
        ((search "author " line)
         (setf (getf current :author) (subseq line 7)))
        ((search "author-mail " line)
         (setf (getf current :email) (subseq line 12)))
        ((search "author-time " line)
         (setf (getf current :time) (parse-integer (subseq line 12))))
        ((search "summary " line)
         (setf (getf current :summary) (subseq line 8)))))
    (when current
      (push current entries))
    (nreverse entries)))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-git-tool ()
  "Initialize the git tool.

  Returns:
    T"
  (log-info "Git tool initialized")
  t)
