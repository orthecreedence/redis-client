(defpackage #:redis-client
  (:use #:cl #:cl-user #:bordeaux-threads)
  (:nicknames :rc :redis)
  (:export connect disconnect cmd))
(in-package #:redis-client)

(defclass redis-connection ()
  ((sock :accessor redis-connection-sock :initarg :sock)
   (lock :accessor redis-connection-lock :initform (bt:make-lock))
   (host :accessor redis-connection-host :initarg :host)
   (port :accessor redis-connection-port :initarg :port)))

;; holds pooled connections
(defvar *connections* nil)

(defvar *default-host* "127.0.0.1")
(defvar *default-port* 6379)

(defun connect (&key (host *default-host*) (port *default-port*))
  "Returns a connection to redis. Defaults to localhost:6379."
  (usocket:socket-connect host port))

(defun get-connection (&key (host *default-host*) (port *default-port*))
  "Provides connection pooling. Grabs an inactive connection, and if none exist,
  creates a new one, locks it, and adds it to the list."
  ;; loop over connections, look for onw that matches our criteria and is free
  (dolist (conn *connections*)
    (when (and (equal (redis-connection-host conn) host)
               (equal (redis-connection-port conn) port)
               (bt:acquire-lock (redis-connection-lock conn)))
      ;; got a connection, return it
      (return-from get-connection conn)))
  ;; didn't get a free/matching connection, create one, lock it, add it to the
  ;; connection list and return it.
  (let ((conn (make-instance 'redis-connection :sock (connect :host host :port port) :host host :port port)))
    (bt:acquire-lock (redis-connection-lock conn) t)
    (push conn *connections*)
    conn))

(defun release-connection (conn)
  "Release a connection lock, allowing others to use this connection."
  (bt:release-lock (redis-connection-lock conn)))

(defmacro with-connection (host port &body body)
  "Wraps a body with connect/release connection logic."
  `(let ((conn (get-connection :host ,host :port ,port)))
     ,@body
     (release-connection conn)))

(defmacro constream ()
  "Wrapper around usocket:socket-stream. Must be used within a
  (with-connection ...) form."
  `(usocket:socket-stream (redis-connection-sock conn)))

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
  (let ((first-line (read-line s nil nil)))
    (case (elt first-line 0)
      (#\+ (response-single-line s first-line))
      (#\- (response-error s first-line))
      (#\: (response-integer s first-line))
      (#\$ (response-bulk s first-line))
      (#\* (response-multi-bulk s first-line)))))

(defun response-single-line (s first-line)
  "The response from redis was a single line response, just return it usually."
  (case first-line
    ("+OK" t)
    (otherwise (subseq first-line 1 (1- (length first-line))))))

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
    (subseq (read-line s) 0 num-bytes)))

(defun response-multi-bulk (s first-line)
  "Get a multi-bulk response."
  (let ((num-pieces (read-from-string (subseq first-line 1)))
        (pieces nil))
    (when (= num-pieces 0) (return-from response-multi-bulk nil))
    (dotimes (i num-pieces)
      ;; because we programmed response-bulk so well, we can call it here to get
      ;; the bulk response we want and just add it to our "pieces."
      (push (response-bulk s (read-line s)) pieces))
    (reverse pieces)))

(defun cmd (cmd &rest args)
  "Send a command to redis. This function allows to send any command to redis in
  any format without pre-defining a bunch of commands (which CAN be done via
  defcmd). You can use it like (cmd :command-name arg1 arg2):
    (cmd :ping)
    (cmd :set \"mykey\" \"myval\")
    (cmd :lpush \"mylist\" 45)
  etc etc. Send any command to redis generically."
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
    (send-command send :host host :port port)))

(defmacro defcmd (command &rest args)
  "Simple wrapper around cmd that allows defining of new commands:
    (defcmd lpush key val)
  and now you can do:
    (lpush \"mylist\" 6969)
  probably won't work with things like set since it's a predefined CL function,
  which is why I don't use it heavily in this client. Most commands can be, and
  are recommended to be, run by (cmd)."
  `(progn
     (defun ,command ,args
       (cmd ',command ,@args))
     (export ',command)))

