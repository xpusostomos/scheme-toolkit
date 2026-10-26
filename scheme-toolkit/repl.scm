;;; (scheme-toolkit repl) -- the back door into a running shell
;;;
;;; A running shell is controlled by evaluating Scheme in it.  That replaces
;;; AGS's four-verb D-Bus protocol: instead of `toggle-window', `quit',
;;; `inspect' and `request', the shell exports ordinary procedures and a
;;; keybinding says
;;;
;;;     scheme-toolkit eval '(toggle-window "launcher")'
;;;
;;; which is the same thing an editor, a test runner, or a person at a terminal
;;; does.
;;;
;;; THIS IS ARBITRARY CODE EXECUTION OVER A SOCKET, by design: it is the
;;; development and control back door.  It is therefore confined as tightly as
;;; it can be -- a Unix socket under $XDG_RUNTIME_DIR, which is per-user and
;;; 0700, refusing to start at all when that variable is unset rather than
;;; falling back to /tmp.  It never binds TCP.
;;;
;;; WHY THE COOPERATIVE SERVER, and never (system repl server):
;;;
;;;   - GTK is single-threaded.  The plain server runs each session in its own
;;;     thread, so any widget touched from it is a data race.
;;;   - Guile parameters are thread-local.  The reactive core's current-scope
;;;     and dependency-tracking state are parameters, so a REPL thread would
;;;     see their DEFAULT values -- an effect created from such a thread would
;;;     have no scope and never be disposed.
;;;
;;; The coop server reads in a thread but evaluates on the main thread when it
;;; is polled.  What upstream lacks is a way to know WHEN to poll; polling on a
;;; timer costs a measurable fraction of a core at idle.  The vendored
;;; coop-server.scm adds a #:notify hook, and this wires it to an idle source,
;;; so the shell wakes only when there is something to run.

(define-module (scheme-toolkit repl)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit repl coop-server)
  #:use-module (scheme-toolkit result)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  ;; The socket calls and constants: AF_UNIX, SOCK_STREAM, socket, connect.
  #:use-module ((guile) #:select (AF_UNIX SOCK_STREAM socket connect close
                                  listen bind))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((guile) #:select (resolve-module save-module-excursion
                                  set-current-module))
  ;; The coop server suppresses its banner through this flag; a shell that was
  ;; connected to is not one that was started.
  #:use-module ((system repl repl) #:select (%inhibit-welcome-message))
  ;; The Unix-socket server socket.  (system repl server) is where this lives;
  ;; it is a plain socket constructor, not the threaded server that the coop
  ;; server exists to avoid.
  #:use-module ((system repl server) #:select (make-unix-domain-server-socket))
  #:export (start-repl!
            poll-repl!
            stop-repl!
            live-instances
            socket-alive?
            repl-running?
            repl-socket-path
            socket-directory
            list-instances
            instance-name))

;;; ---------------------------------------------------------------------------
;;; Where the socket lives
;;; ---------------------------------------------------------------------------

;; A Unix socket named by instance, not a TCP port written to a file: no port
;; hunting, `scheme-toolkit list` is a directory listing, and the runtime
;; directory is already per-user 0700.
(define (socket-directory)
  (let ((runtime (getenv "XDG_RUNTIME_DIR")))
    (unless (and runtime (not (string=? runtime "")))
      (error (string-append
              "scheme-toolkit: XDG_RUNTIME_DIR is unset, so there is nowhere "
              "safe to put a code-execution socket.  Refusing to fall back to "
              "/tmp, which is world-writable.")))
    (let ((dir (string-append runtime "/scheme-toolkit")))
      (unless (file-exists? dir)
        (mkdir dir #o700))
      dir)))

(define* (repl-socket-path #:optional (instance (instance-name)))
  (string-append (socket-directory) "/" instance ".sock"))

(define (instance-name)
  (let ((name (getenv "SCHEME_TOOLKIT_INSTANCE")))
    (unless (and name (not (string=? name "")))
      (error (string-append
              "scheme-toolkit: SCHEME_TOOLKIT_INSTANCE is unset.  "
              "bin/scheme-toolkit sets it from the shell's directory name.")))
    name))

;;; ---------------------------------------------------------------------------
;;; The server
;;; ---------------------------------------------------------------------------

;; The module every expression is read and evaluated in.
;;
;; PINNED, and that is not decoration.  poll-repl! is reached from wherever the
;; main thread happened to be waiting -- a signal handler, a command's own
;; nested prompt -- so without this, what a name means at the back door would
;; depend on how deep the shell happened to be nested.  A shell exports its
;; vocabulary into (guile-user) by importing it there, so that is the default.
(define %repl-module '(guile-user))

;; Whether to let Guile's welcome banner through.  A shell is connected to, not
;; started, so the answer is normally no.  Kept as a plain flag and applied with
;; parameterize at poll time -- see start-repl!.
(define %show-banner? #f)

(define %repl #f)              ; the coop server, or #f
(define %repl-socket #f)       ; its socket path, for removal on shutdown
(define %wake-source #f)       ; idle source id while a wake is pending
(define %wake-mutex (make-mutex))

;; Drain the WHOLE queue, not one operation.
;;
;; The wake is level-triggered: an idle source says "there is work", not "there
;; is one item of work".  A single poll could therefore leave operations queued
;; with no further wake coming, and the client would hang.
(define (drain-and-reschedule)
  (set! %wake-source #f)
  ;; save-module-excursion + set-current-module + %inhibit-welcome-message,
  ;; which is exactly what the reference implementation does and for the same
  ;; reasons: the first two make an expression mean the same thing wherever the
  ;; shell was when it arrived, and the third keeps the copyright banner off a
  ;; session the user connected to rather than started.
  (save-module-excursion
   (lambda ()
     (set-current-module (resolve-module %repl-module))
     (parameterize ((%inhibit-welcome-message (not %show-banner?)))
       (let loop ()
         (when (poll-coop-repl-server %repl)
           (loop))))))
  ;; #f removes the idle source; see wake!.
  #f)

(define (wake! server)
  ;; Called from the reader thread, possibly several times at once, so the
  ;; check-and-set is guarded.  Queueing an idle source per wake would leak one
  ;; per keystroke a client sends.
  (lock-mutex %wake-mutex)
  (unless %wake-source
    (set! %wake-source (g-idle-add drain-and-reschedule)))
  (unlock-mutex %wake-mutex))

;;; ---------------------------------------------------------------------------
;;; Client-facing helpers
;;; ---------------------------------------------------------------------------

(define (socket-alive? path)
  "Whether something is actually listening on PATH.

A stale socket file left by a crashed shell looks identical to a live one on
disk, so this is settled by connecting."
  (catch #t
    (lambda ()
      (let ((s (socket AF_UNIX SOCK_STREAM 0)))
        (catch #t
          (lambda () (connect s AF_UNIX path) (close s) #t)
          (lambda args (catch #t (lambda () (close s)) (lambda a #f)) #f))))
    (lambda args #f)))

(define (basename path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) path)
          ((char=? (string-ref path i) #\/)
           (substring path (+ i 1) (string-length path)))
          (else (loop (- i 1))))))

(define (socket-files)
  "Every .sock file in the socket directory, newest last."
  (let ((dir (catch #t socket-directory (lambda args #f))))
    (if (not dir)
        '()
        (sort (catch #t
                (lambda ()
                  (filter (lambda (f) (string-suffix? ".sock" f))
                          (map basename (scandir dir))))
                (lambda args '()))
              string<?))))

(define (live-instances)
  "The instance names whose REPL answers, in order.

This is the one to use programmatically: a socket file left by a crashed shell
looks exactly like a live one on disk, so liveness is settled by connecting."
  (let ((dir (catch #t socket-directory (lambda args #f))))
    (if (not dir)
        '()
        (filter (lambda (name)
                  ;; ".sock" has to go back on: socket-files returns FILE names,
                  ;; and the map below strips the extension.
                  (socket-alive? (string-append dir "/" name ".sock")))
                (map (lambda (f) (string-drop-right f 5)) (socket-files))))))

(define* (list-instances #:optional (port (current-output-port)))
  "Print the instances, marking any that are stale.  Returns the count of LIVE
ones, so a caller can branch on it."
  (let ((dir (catch #t socket-directory (lambda args #f))))
    (if (not dir)
        (begin (format port "no XDG_RUNTIME_DIR, so no instances~%") 0)
        (let ((files (socket-files)))
          (if (null? files)
              (begin (format port "no running instances~%") 0)
              (let ((live (live-instances)))
                (for-each (lambda (f)
                            (let ((name (string-drop-right f 5)))
                              (format port "~a~a~%"
                                      name
                                      (if (member name live) "" "  (stale)"))))
                          files)
                (length live)))))))

;;; ---------------------------------------------------------------------------
;;; Starting and stopping
;;; ---------------------------------------------------------------------------

(define* (start-repl! #:key (instance #f) (module #f) (welcome? #f))
  "Open the back door on $XDG_RUNTIME_DIR/scheme-toolkit/INSTANCE.sock.

Returns the socket path.

MODULE, when given, is pinned current before each evaluation: the main thread
may be arbitrarily deep in a signal handler with some other module current, and
an expression typed at the REPL should mean what it means at the shell's top
level.  (The cooperative server does the pinning; this records what to pin.)"
  (when %repl
    (error "scheme-toolkit: the REPL is already running on" %repl-socket))
  (let ((path (repl-socket-path (or instance (instance-name)))))
    ;; A socket left behind by a crashed shell would make bind fail.  A live one
    ;; answers a connection; a dead one does not.
    (when (file-exists? path)
      (if (socket-alive? path)
          (error "scheme-toolkit: another shell is already listening on" path)
          (delete-file path)))
    (let ((sock (make-unix-domain-server-socket #:path path)))
      ;; listen() is REQUIRED and Guile's make-unix-domain-server-socket does
      ;; not do it.  It creates the socket, sets SO_REUSEADDR and binds -- and
      ;; stops, so the path exists and is a socket, but nothing ever accepts and
      ;; every client gets "Connection refused".
      ;;
      ;; The stock TCP REPL server gets away with the same omission because
      ;; something further down the path listens; over Unix, nothing does.
      (listen sock 16)
      (set! %repl (spawn-coop-repl-server sock #:notify wake!)))
    (set! %repl-socket path)
    (when module (set! %repl-module module))
    ;; The banner is suppressed around each poll, in drain-and-reschedule,
    ;; NOT here.  %inhibit-welcome-message is a PARAMETER, and `set!' on a
    ;; parameter replaces the binding itself -- after which `parameterize' on it
    ;; fails with "Not a parameter", which is exactly what it did.
    (set! %show-banner? welcome?)
    path))

(define (poll-repl!)
  "Run everything the back door has queued, on the calling thread.

This is what the idle source calls, and what the main loop must therefore run
for a client to get an answer: the cooperative server reads in a thread but
evaluates here.  A shell gets this for free from its main loop; a test has to
arrange it."
  (when %repl (drain-and-reschedule)))

(define (repl-running?) (and %repl #t))

(define (stop-repl!)
  "Close the back door and remove the socket, so `scheme-toolkit list' stops
offering it.  A stale socket left behind makes the next start look like a crash."
  (when %repl
    (set! %repl #f)
    (when (and %repl-socket (file-exists? %repl-socket))
      (catch #t (lambda () (delete-file %repl-socket)) (lambda args #f)))
    (set! %repl-socket #f)
    (set! %wake-source #f))
  #t)
