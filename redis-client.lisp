(defpackage #:redis-client
  (:use #:cl #:cl-user)
  (:nicknames :rc :redis)
  (:export connect disconnect cmd defcmd *default-host* *default-port* *command-prefix* *connection-timeout*))
(in-package #:redis-client)

(defun now ()
  "Wrapper around get-universal-time."
  (get-universal-time))

(defclass redis-connection ()
  ((sock :accessor redis-connection-sock :initarg :sock)
   (lock :accessor redis-connection-lock :initform nil)
   (last-used :accessor redis-connection-last-used :initform (now))
   (host :accessor redis-connection-host :initarg :host)
   (port :accessor redis-connection-port :initarg :port)))

;; holds pooled connections
(defvar *connections* nil)

;; set up some connection vars
(defvar *default-host* "127.0.0.1")
(defvar *default-port* 6379)
(defvar *connection-timeout* 300)

(defun replace-newlines (str)
  "Given a format string like \"i have~%sex with~%goats\", replace all ~%
  (format's newlines) with \r\n specifically. Redis only likes these specific
  line endings. Note that this operates directly on what would be the format
  string itself."
  (loop do
        (let ((pos (search "~%" str)))
          (unless pos (return))
          (setf (elt str pos) #\return
                (elt str (1+ pos)) #\newline)))
  str)

(defun connect (&key (host *default-host*) (port *default-port*))
  "Returns a connection to redis. Defaults to localhost:6379."
  (usocket:socket-connect host port))

(defmethod lock-connection ((connection redis-connection))
  "Set a connection's locked bit. If connection is already locked, return nil."
  (unless (redis-connection-lock connection)
    (setf (redis-connection-lock connection) t)))

(defmethod unlock-connection ((connection redis-connection))
  "Unset a connection's locked bit."
  (setf (redis-connection-lock connection) nil))

(defmacro constream ()
  "Wrapper around usocket:socket-stream. Must be used in a block that has the
  variable conn defined (such as within a (with-connection ...) block."
  `(usocket:socket-stream (redis-connection-sock conn)))

(defmethod is-connection-alive ((conn redis-connection))
  "Test if a connection is alive. Currently unused, but still could be useful so
  I'm leaving it in for now. Works by sending a PING/PONG across the wire and
  seeing if the socket fails."
  (handler-case
    (progn 
      (format (constream) (replace-newlines "PING~%~%"))
      (force-output (constream))
      (parse-response (constream)))
    (error () nil)))

(defun get-time-diff (&optional (time 0))
  "Get the difference in seconds between some point in time and now."
  (- (now) time))

(defun get-connection (&key (host *default-host*) (port *default-port*))
  "Provides connection pooling. Grabs an inactive connection, and if none exist,
  creates a new one, locks it, and adds it to the list."
  ;; loop over connections, look for one that matches our criteria and is free
  (dolist (conn *connections*)
    (when (and (equal (redis-connection-host conn) host)
               (equal (redis-connection-port conn) port)
               (lock-connection conn))
      (if (<= (1- *connection-timeout*) (get-time-diff (redis-connection-last-used conn)))
          ;; connection is dead. close it, remove it, and keep looping
          (progn (usocket:socket-close (redis-connection-sock conn))
                 (setf *connections* (remove-if (lambda (c) (equal c conn)) *connections*)))
          ;; got a good, unused connection. return it and set the "last used" time
          (progn (setf (redis-connection-last-used conn) (now))
                 (return-from get-connection conn)))))
  ;; didn't get a free/matching connection, create one, lock it, add it to the
  ;; connection list and return it.
  (let ((conn (make-instance 'redis-connection :sock (connect :host host :port port) :host host :port port)))
    (lock-connection conn)
    (push conn *connections*)
    conn))

(defun release-connection (conn)
  "Release a connection lock, allowing others to use this connection."
  (unlock-connection conn))

(defmacro with-connection (host port &body body)
  "Wraps a body with connect/release connection logic."
  `(let ((conn (get-connection :host ,host :port ,port)))
     (let ((return (progn ,@body)))
       (release-connection conn)
       return)))

(defun trim-return (str)
  "Remove trailing #\return character from string."
  (if (eql (elt str (1- (length str))) #\return)
      (subseq str 0 (1- (length str)))
      str))

(defun redis-read-line (stream &optional (min-length -1) (level 0))
  "Read a line from a stream, but expecting a redis line instead of a sane line.
  This means we read a line terminated with \r\n and strip out the trailing \r."
  (let ((line (read-line stream nil nil)))
    ;(format t "~a (~a): ~a~%" line (length line) (babel:string-to-octets line))
    (let ((line (if (< (length line) min-length)
                    ;; the line we read is shorter than what we expected. this must mean the
                    ;; data has a newline in it and we need to keep reading. recurse.
                    (concatenate 'string line #(#\newline) (redis-read-line stream (- min-length (1+ (length line))) (1+ level)))
                    ;; gnar dude, got just what we need, leave.
                    line)))
      ;; only trim last \r if we're in the top level.
      (if (zerop level)
          (trim-return line)
          line))))

(defun send-command (data &key (host *default-host*) (port *default-port*))
  "Send a raw, pre-formatted command to redis and parse the response. At this
  point, a command would be something like:
  *2\r\n$3\r\nGET\r\n$5\r\nmykey\r\n"
  (with-connection host port
    (format (constream) "~a" data)
    (force-output (constream))
    (parse-response (constream))))

(defun parse-response (s)
  "Given the connection stream, read the first line and determine based on the
  first byte of the response from redis what action to take. Redis has uniform
  respons formats, so this works like a charm."
  ;; read the first line and trim the trailing \r if it exists
  (let ((first-line (redis-read-line s)))
    (case (elt first-line 0)
      (#\+ (response-single-line s first-line))
      (#\- (response-error s first-line))
      (#\: (response-integer s first-line))
      (#\$ (response-bulk s first-line))
      (#\* (response-multi-bulk s first-line)))))

(defun response-single-line (s first-line)
  "The response from redis was a single line response, just return it usually."
  (cond
    ((equal first-line "+OK") t)
    ((equal first-line "+PONG") t)
    (t (subseq first-line 1))))

(defun response-error (s first-line)
  "Response from redis was an error. Return the error message. Should most
  likely throw an error in lisp though."
  (subseq first-line 1 (1- (length first-line))))

(defun response-integer (s first-line)
  "Parse an integer from a redis response."
  (nth 0 (multiple-value-list (read-from-string (subseq first-line 1)))))

(defun response-bulk (s first-line)
  "Got a bulk response."
  (let ((num-bytes (read-from-string (subseq first-line 1))))
    (when (= num-bytes -1)
      (return-from response-bulk nil))
    (subseq (redis-read-line s num-bytes) 0 num-bytes)))

(defun response-multi-bulk (s first-line)
  "Get a multi-bulk response."
  (let ((num-pieces (read-from-string (subseq first-line 1)))
        (pieces nil))
    (when (= num-pieces 0) (return-from response-multi-bulk nil))
    (dotimes (i num-pieces)
      ;; because we programmed response-bulk so well, we can call it here to get
      ;; the bulk response we want and just add it to our "pieces."
      (push (response-bulk s (redis-read-line s)) pieces))
    (reverse pieces)))

(defun cmd (&key cmd (host *default-host*) (port *default-port*))
  "Send a command to redis. This function allows to send any command to redis in
  any format without pre-defining a bunch of commands (which CAN be done via
  defcmd). Syntax:
    (cmd :cmd '(lpush \"mylist\" \"myval\"))
  It's best to wrap it with defcmd."
  (let ((cmd (car cmd))
        (args (progn
                ;; look in the arg list for lists. these are MOST LIKELY &rest
                ;; params sent through by defcmd and need to actually be added
                ;; to the main arg list from within their sub-list (flattened,
                ;; if you will)
                (let ((args nil))
                  (dolist (arg (cdr cmd))
                    (if (listp arg)
                        (dolist (arg-r arg) (push arg-r args))
                        (push arg args)))
                  (reverse args)))))
    ;; ignore empty commands
    (unless cmd (return-from cmd nil))
    ;; build the raw string we send to redis (in universal format)
    (let ((send (with-output-to-string (s)
                  ;; define an standard output fn that wraps format strings in
                  ;; replace-newlines
                  (flet ((out (stream format &rest args)
                           (apply #'format (append (list stream (replace-newlines format)) args))))
                    ;; build the actual request to redis using the universal format
                    (out s "*~a~%" (1+ (length args)))
                    (let ((command (out nil "~:@(~a~)" cmd)))
                      (out s "$~a~%" (length command))
                      (out s "~a~%" command))
                    (dolist (arg args)
                      (let ((arg (if (stringp arg) arg (write-to-string arg))))
                        (out s "$~a~%" (length arg))
                        (out s "~a~%" arg)))
                    (out s "~%")))))
      ;; send the command off and return the parsed result
      (send-command send :host host :port port))))

(defun make-sym (&rest parts)
  "Given a bunch of pieces (string or symbol), concatenate then imto one symbol"
  (intern (string-upcase (with-output-to-string (s) (dolist (p parts) (princ p s))))))

(defvar *command-prefix* "r-")
(defmacro defcmd (name &rest args)
  "Defines a wrapper around (cmd ...) that makes the syntax a bit easier to deal
  with. For instance, instead of 
    (rc:cmd :cmd '(incr \"id\"))
  we can define the command like so
    (defcmd incr key)
  and after defining, we can forever just refer to the command by doing:
    (r-incr \"id\")
  The function r-incr is created in the package you're in when calling defcmd,
  so you don't need a package specifier unless you switch packages after
  defining the command."
  (let* ((fn-name (make-sym *command-prefix* name))
         (default-args '(&key (host redis-client:*default-host*) (port redis-client:*default-port*)))
         (fn-args (if args
                      (append args default-args)
                      default-args))
         (cmd-args (remove-if (lambda (arg) (or (equal arg '&rest) (equal arg '&optional)))
                              (if args
                                  `(list ',name ,@args)
                                  `(list ',name)))))
    `(progn
       (defun ,fn-name ,fn-args
         (redis-client:cmd :cmd ,cmd-args :host host :port port))
       (export ',fn-name))))

