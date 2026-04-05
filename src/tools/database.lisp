;;; tools/database.lisp --- Database Tool for Lisp-Claw
;;;
;;; This file implements database operations tool:
;;; - SQLite support (built-in)
;;; - PostgreSQL support
;;; - MySQL support
;;; - Connection pooling
;;; - Query building helpers

(defpackage #:lisp-claw.tools.database
  (:nicknames #:lc.tools.db)
  (:use #:cl
        #:alexandria
        #:bordeaux-threads
        #:lisp-claw.utils.logging
        #:lisp-claw.utils.json)
  (:export
   ;; Database classes
   #:database
   #:sqlite-database
   #:postgresql-database
   #:mysql-database
   ;; Connection
   #:db-connect
   #:db-disconnect
   #:db-connected-p
   #:db-with-connection
   ;; Query execution
   #:db-execute
   #:db-query
   #:db-query-one
   #:db-query-column
   #:db-query-value
   ;; Transaction
   #:db-with-transaction
   #:db-begin
   #:db-commit
   #:db-rollback
   ;; Table operations
   #:db-list-tables
   #:db-describe-table
   #:db-table-exists-p
   ;; Connection management
   #:db-pool-connect
   #:db-pool-disconnect
   #:db-pool-status
   ;; Utilities
   #:db-escape-identifier
   #:db-escape-string
   #:db-format-in))

(in-package #:lisp-claw.tools.database)

;;; ============================================================================
;;; Database Base Class
;;; ============================================================================

(defclass database ()
  ((connection :initform nil
               :accessor db-connection
               :documentation "Database connection")
   (:documentation "Base database class")))

(defgeneric db-connect (db &key host port database user password)
  (:documentation "Connect to database"))

(defgeneric db-disconnect (db)
  (:documentation "Disconnect from database"))

(defgeneric db-connected-p (db)
  (:documentation "Check if connected"))

(defgeneric db-execute (db sql &rest params)
  (:documentation "Execute SQL statement"))

(defgeneric db-query (db sql &rest params)
  (:documentation "Execute SELECT query"))

;;; ============================================================================
;;; SQLite Database
;;; ============================================================================

(defclass sqlite-database (database)
  ((database-file :initarg :database-file
                  :reader sqlite-database-file
                  :documentation "SQLite database file path"))
  (:documentation "SQLite database"))

(defmethod print-object ((db sqlite-database) stream)
  (print-unreadable-object (db stream :type t)
    (format t "~A" (sqlite-database-file db))))

(defun make-sqlite-database (database-file)
  "Create a SQLite database connection.

  Args:
    DATABASE-FILE: Path to SQLite file

  Returns:
    SQLite database instance"
  (make-instance 'sqlite-database :database-file database-file))

(defmethod db-connect ((db sqlite-database) &key host port database user password)
  "Connect to SQLite database.

  Args:
    DB: SQLite database instance
    HOST, PORT, DATABASE, USER, PASSWORD: Ignored for SQLite

  Returns:
    T on success"
  (declare (ignore host port database user password))
  (handler-case
      (progn
        ;; Use CL-DBI for database connection
        (let ((conn (dbi:connect :sqlite3
                                 :database-name (sqlite-database-file db))))
          (setf (db-connection db) conn)
          (log-info "SQLite connected: ~A" (sqlite-database-file db))
          t))
    (error (e)
      (log-error "SQLite connection failed: ~A - ~A" (sqlite-database-file db) e)
      nil)))

(defmethod db-disconnect ((db sqlite-database))
  "Disconnect from SQLite database.

  Args:
    DB: SQLite database instance

  Returns:
    T on success"
  (when (db-connection db)
    (dbi:disconnect (db-connection db))
    (setf (db-connection db) nil)
    (log-info "SQLite disconnected: ~A" (sqlite-database-file db)))
  t)

(defmethod db-connected-p ((db sqlite-database))
  "Check if SQLite is connected.

  Args:
    DB: SQLite database instance

  Returns:
    T if connected"
  (and (db-connection db) t))

(defmethod db-execute ((db sqlite-database) sql &rest params)
  "Execute SQL statement on SQLite.

  Args:
    DB: SQLite database instance
    SQL: SQL statement
    PARAMS: Query parameters

  Returns:
    Number of affected rows"
  (unless (db-connected-p db)
    (error "Database not connected"))
  (handler-case
      (let ((conn (db-connection db))
            (stmt (dbi:prepare conn sql)))
        (apply #'dbi:execute stmt params)
        (dbi:affected-rows conn))
    (error (e)
      (log-error "SQLite execute failed: ~A - ~A" sql e)
      (error "Database error: ~A" e))))

(defmethod db-query ((db sqlite-database) sql &rest params)
  "Execute SELECT query on SQLite.

  Args:
    DB: SQLite database instance
    SQL: SQL query
    PARAMS: Query parameters

  Returns:
    List of result rows (each row is a plist)"
  (unless (db-connected-p db)
    (error "Database not connected"))
  (handler-case
      (let ((conn (db-connection db))
            (rows nil))
        (dbi:do-query conn sql params
                      (lambda (row)
                        (push (dbi-row-to-plist row conn) rows)))
        (nreverse rows))
    (error (e)
      (log-error "SQLite query failed: ~A - ~A" sql e)
      nil)))

(defmethod db-query-one ((db sqlite-database) sql &rest params)
  "Execute query and return first result.

  Args:
    DB: SQLite database instance
    SQL: SQL query
    PARAMS: Query parameters

  Returns:
    First result plist or NIL"
  (car (apply #'db-query db sql params)))

(defmethod db-query-column ((db sqlite-database) sql column &rest params)
  "Execute query and return single column.

  Args:
    DB: SQLite database instance
    SQL: SQL query
    COLUMN: Column name or index
    PARAMS: Query parameters

  Returns:
    List of column values"
  (let ((rows (apply #'db-query db sql params)))
    (if (stringp column)
        (mapcar (lambda (row) (getf row (keywordize column))) rows)
        (mapcar (lambda (row) (nth column row)) rows))))

(defmethod db-query-value ((db sqlite-database) sql &rest params)
  "Execute query and return single value.

  Args:
    DB: SQLite database instance
    SQL: SQL query
    PARAMS: Query parameters

  Returns:
    Single value or NIL"
  (let ((row (apply #'db-query-one db sql params)))
    (if row
        (cdr (second row))
        nil)))

;;; ============================================================================
;;; PostgreSQL Database
;;; ============================================================================

(defclass postgresql-database (database)
  ((host :initarg :host :initform "localhost" :reader pg-host)
   (port :initarg :port :initform 5432 :reader pg-port)
   (database :initarg :database :reader pg-database)
   (user :initarg :user :reader pg-user)
   (password :initarg :password :reader pg-password))
  (:documentation "PostgreSQL database"))

(defmethod print-object ((db postgresql-database) stream)
  (print-unreadable-object (db stream :type t)
    (format t "~A@~A:~A" (pg-user db) (pg-host db) (pg-database db))))

(defun make-postgresql-database (host port database user password)
  "Create a PostgreSQL database instance.

  Args:
    HOST: Database host
    PORT: Database port
    DATABASE: Database name
    USER: Database user
    PASSWORD: Database password

  Returns:
    PostgreSQL database instance"
  (make-instance 'postgresql-database
                 :host host
                 :port port
                 :database database
                 :user user
                 :password password))

(defmethod db-connect ((db postgresql-database) &key host port database user password)
  "Connect to PostgreSQL database.

  Args:
    DB: PostgreSQL database instance
    HOST, PORT, DATABASE, USER, PASSWORD: Optional overrides

  Returns:
    T on success"
  (handler-case
      (let ((conn (dbi:connect :postgres
                               :host (or host (pg-host db))
                               :port (or port (pg-port db))
                               :database (or database (pg-database db))
                               :user (or user (pg-user db))
                               :password (or password (pg-password db)))))
        (setf (db-connection db) conn)
        (log-info "PostgreSQL connected: ~A@~A:~A" (pg-user db) (pg-host db) (pg-port db))
        t)
    (error (e)
      (log-error "PostgreSQL connection failed: ~A - ~A" (pg-database db) e)
      nil)))

(defmethod db-disconnect ((db postgresql-database))
  "Disconnect from PostgreSQL.

  Args:
    DB: PostgreSQL database instance

  Returns:
    T on success"
  (when (db-connection db)
    (dbi:disconnect (db-connection db))
    (setf (db-connection db) nil)
    (log-info "PostgreSQL disconnected"))
  t)

(defmethod db-connected-p ((db postgresql-database))
  "Check if PostgreSQL is connected.

  Args:
    DB: PostgreSQL database instance

  Returns:
    T if connected"
  (and (db-connection db) t))

(defmethod db-execute ((db postgresql-database) sql &rest params)
  "Execute SQL on PostgreSQL.

  Args:
    DB: PostgreSQL database instance
    SQL: SQL statement
    PARAMS: Query parameters

  Returns:
    Number of affected rows"
  (unless (db-connected-p db)
    (error "Database not connected"))
  (handler-case
      (let ((conn (db-connection db)))
        (dbi:execute (dbi:prepare conn sql) params)
        (dbi:affected-rows conn))
    (error (e)
      (log-error "PostgreSQL execute failed: ~A" e)
      (error "Database error: ~A" e))))

(defmethod db-query ((db postgresql-database) sql &rest params)
  "Execute SELECT on PostgreSQL.

  Args:
    DB: PostgreSQL database instance
    SQL: SQL query
    PARAMS: Query parameters

  Returns:
    List of result rows"
  (unless (db-connected-p db)
    (error "Database not connected"))
  (handler-case
      (let ((conn (db-connection db))
            (rows nil))
        (dbi:do-query conn sql params
                      (lambda (row)
                        (push (dbi-row-to-plist row conn) rows)))
        (nreverse rows))
    (error (e)
      (log-error "PostgreSQL query failed: ~A" e)
      nil)))

;;; ============================================================================
;;; MySQL Database
;;; ============================================================================

(defclass mysql-database (database)
  ((host :initarg :host :initform "localhost" :reader mysql-host)
   (port :initarg :port :initform 3306 :reader mysql-port)
   (database :initarg :database :reader mysql-database)
   (user :initarg :user :reader mysql-user)
   (password :initarg :password :reader mysql-password))
  (:documentation "MySQL database"))

(defmethod print-object ((db mysql-database) stream)
  (print-unreadable-object (db stream :type t)
    (format t "~A@~A:~A" (mysql-user db) (mysql-host db) (mysql-database db))))

(defun make-mysql-database (host port database user password)
  "Create a MySQL database instance.

  Args:
    HOST: Database host
    PORT: Database port
    DATABASE: Database name
    USER: Database user
    PASSWORD: Database password

  Returns:
    MySQL database instance"
  (make-instance 'mysql-database
                 :host host
                 :port port
                 :database database
                 :user user
                 :password password))

(defmethod db-connect ((db mysql-database) &key host port database user password)
  "Connect to MySQL database.

  Args:
    DB: MySQL database instance
    HOST, PORT, DATABASE, USER, PASSWORD: Optional overrides

  Returns:
    T on success"
  (handler-case
      (let ((conn (dbi:connect :mysql
                               :host (or host (mysql-host db))
                               :port (or port (mysql-port db))
                               :database (or database (mysql-database db))
                               :user (or user (mysql-user db))
                               :password (or password (mysql-password db)))))
        (setf (db-connection db) conn)
        (log-info "MySQL connected: ~A@~A:~A" (mysql-user db) (mysql-host db) (mysql-port db))
        t)
    (error (e)
      (log-error "MySQL connection failed: ~A" e)
      nil)))

(defmethod db-disconnect ((db mysql-database))
  "Disconnect from MySQL.

  Args:
    DB: MySQL database instance

  Returns:
    T on success"
  (when (db-connection db)
    (dbi:disconnect (db-connection db))
    (setf (db-connection db) nil)
    (log-info "MySQL disconnected"))
  t)

(defmethod db-connected-p ((db mysql-database))
  "Check if MySQL is connected.

  Args:
    DB: MySQL database instance

  Returns:
    T if connected"
  (and (db-connection db) t))

(defmethod db-execute ((db mysql-database) sql &rest params)
  "Execute SQL on MySQL.

  Args:
    DB: MySQL database instance
    SQL: SQL statement
    PARAMS: Query parameters

  Returns:
    Number of affected rows"
  (unless (db-connected-p db)
    (error "Database not connected"))
  (handler-case
      (let ((conn (db-connection db)))
        (dbi:execute (dbi:prepare conn sql) params)
        (dbi:affected-rows conn))
    (error (e)
      (log-error "MySQL execute failed: ~A" e)
      (error "Database error: ~A" e))))

(defmethod db-query ((db mysql-database) sql &rest params)
  "Execute SELECT on MySQL.

  Args:
    DB: MySQL database instance
    SQL: SQL query
    PARAMS: Query parameters

  Returns:
    List of result rows"
  (unless (db-connected-p db)
    (error "Database not connected"))
  (handler-case
      (let ((conn (db-connection db))
            (rows nil))
        (dbi:do-query conn sql params
                      (lambda (row)
                        (push (dbi-row-to-plist row conn) rows)))
        (nreverse rows))
    (error (e)
      (log-error "MySQL query failed: ~A" e)
      nil)))

;;; ============================================================================
;;; Helper Functions
;;; ============================================================================

(defun dbi-row-to-plist (row connection)
  "Convert DBI row to plist.

  Args:
    ROW: DBI row vector
    CONNECTION: Database connection

  Returns:
    Plist with keyword keys"
  (let ((columns (dbi:column-names connection))
        (result nil))
    (loop for col in columns
          for val across row
          do (push (keywordize col) result)
             (push val result))
    (nreverse result)))

(defun db-with-connection (db fn)
  "Execute function with database connection.

  Args:
    DB: Database instance
    FN: Function to call

  Returns:
    Function result"
  (let ((connected (db-connected-p db)))
    (unwind-protect
        (progn
          (unless connected
            (db-connect db))
          (funcall fn db))
      (unless connected
        (db-disconnect db)))))

(defun db-with-transaction (db fn)
  "Execute function within a transaction.

  Args:
    DB: Database instance
    FN: Function to call

  Returns:
    Function result"
  (unwind-protect
      (progn
        (db-begin db)
        (let ((result (funcall fn db)))
          (db-commit db)
          result))
    (error (e)
      (db-rollback db)
      (log-error "Transaction failed: ~A" e)
      (error e))))

(defun db-begin (db)
  "Begin a transaction.

  Args:
    DB: Database instance

  Returns:
    T"
  (db-execute db "BEGIN")
  t)

(defun db-commit (db)
  "Commit a transaction.

  Args:
    DB: Database instance

  Returns:
    T"
  (db-execute db "COMMIT")
  t)

(defun db-rollback (db)
  "Rollback a transaction.

  Args:
    DB: Database instance

  Returns:
    T"
  (db-execute db "ROLLBACK")
  t)

(defun db-list-tables (db)
  "List all tables in database.

  Args:
    DB: Database instance

  Returns:
    List of table names"
  (let ((sql (typecase db
               (sqlite-database
                "SELECT name FROM sqlite_master WHERE type='table'")
               (postgresql-database
                "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'")
               (mysql-database
                "SHOW TABLES"))))
    (db-query-column db sql 0)))

(defun db-table-exists-p (db table-name)
  "Check if a table exists.

  Args:
    DB: Database instance
    TABLE-NAME: Table name

  Returns:
    T if exists"
  (member table-name (db-list-tables db) :test #'string=))

(defun db-describe-table (db table-name)
  "Describe a table structure.

  Args:
    DB: Database instance
    TABLE-NAME: Table name

  Returns:
    List of column descriptions"
  (let ((sql (typecase db
               (sqlite-database
                (format nil "PRAGMA table_info(~A)" table-name))
               (postgresql-database
                (format nil "SELECT * FROM information_schema.columns WHERE table_name = '~A'" table-name))
               (mysql-database
                (format nil "DESCRIBE ~A" table-name))))))
    (db-query db sql)))

;;; ============================================================================
;;; Connection Pooling
;;; ============================================================================

(defclass db-pool ()
  ((database :initarg :database :reader pool-database)
   (connections :initform nil :accessor pool-connections)
   (max-size :initarg :max-size :initform 10 :reader pool-max-size)
   (lock :initform (bt:make-lock "db-pool-lock") :reader pool-lock))
  (:documentation "Database connection pool"))

(defun make-db-pool (database &key max-size)
  "Create a database connection pool.

  Args:
    DATABASE: Database instance
    MAX-SIZE: Maximum pool size

  Returns:
    DB pool instance"
  (make-instance 'db-pool :database database :max-size (or max-size 10)))

(defun db-pool-connect (pool)
  "Get a connection from pool.

  Args:
    POOL: DB pool instance

  Returns:
    Database connection"
  (bt:with-lock-held ((pool-lock pool))
    (let ((conn (pop (pool-connections pool))))
      (if conn
          conn
          (let ((db (pool-database pool)))
            (db-connect db)
            db)))))

(defun db-pool-disconnect (pool db)
  "Return a connection to pool.

  Args:
    POOL: DB pool instance
    DB: Database instance"
  (bt:with-lock-held ((pool-lock pool))
    (if (< (length (pool-connections pool)) (pool-max-size pool))
        (push db (pool-connections pool))
        (db-disconnect db))))

(defun db-pool-status (pool)
  "Get pool status.

  Args:
    POOL: DB pool instance

  Returns:
    Status plist"
  (list :size (length (pool-connections pool))
        :max (pool-max-size pool)))

;;; ============================================================================
;;; Utilities
;;; ============================================================================

(defun db-escape-identifier (identifier)
  "Escape a SQL identifier.

  Args:
    IDENTIFIER: Identifier string

  Returns:
    Escaped identifier"
  (format nil "\"~A\"" (substitute #\" #\" identifier :test #'char=)))

(defun db-escape-string (string)
  "Escape a string for SQL.

  Args:
    STRING: String to escape

  Returns:
    Escaped string"
  (substitute "'" "''" string))

(defun db-format-in (values)
  "Format values for IN clause.

  Args:
    VALUES: List of values

  Returns:
    Formatted string"
  (format nil "(~{~A~^, ~})"
          (mapcar (lambda (v)
                    (if (stringp v)
                        (format nil "'~A'" (db-escape-string v))
                        (format nil "~A" v)))
                  values)))

;;; ============================================================================
;;; Initialization
;;; ============================================================================

(defun initialize-database-tool ()
  "Initialize the database tool.

  Returns:
    T"
  (log-info "Database tool initialized (SQLite, PostgreSQL, MySQL)")
  t)
