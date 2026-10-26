;;; tests/repl.scm -- the back door, end to end
;;;
;;; The shape of this test IS the architecture, so it is worth reading: the
;;; cooperative server reads a client's expression in a thread but EVALUATES it
;;; on the main thread, when something polls it.  So the client cannot simply
;;; connect and block on the answer -- nothing would be polling, and it would
;;; hang forever.  A shell gets the polling free from its main loop (the wake
;;; hook adds an idle source); a test has to run a main loop itself.
;;;
;;; That is exactly what this does, which means it exercises the real
;;; mechanism rather than a stand-in for it.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit repl))
(use-modules (oop goops))
(use-modules (ice-9 threads))
(use-modules ((guile) #:select (AF_UNIX SOCK_STREAM socket connect close)))
(use-modules (srfi srfi-64))

(define-gi-imports "Gtk" "init")
(gtk-bootstrap!)

;; A distinct instance name, so this never collides with a running shell.
(setenv "SCHEME_TOOLKIT_INSTANCE" "stk-test-repl")

(define (read-to-prompt s)
  "Everything the server writes up to and including the next prompt.

Read a CHARACTER at a time: the prompt ends with \"> \" and has no newline after
it, so a line-based reader would wait forever for one."
  (let loop ((out '()))
    (let ((c (read-char s)))
      (if (eof-object? c)
          (list->string (reverse out))
          (let* ((out (cons c out))
                 (line (list->string (reverse out))))
            (if (string-suffix? "> " line)
                line
                (loop out)))))))

(define* (ask path expression #:key (timeout-ms 5000))
  "Send EXPRESSION to the shell at PATH and return its answer, driving the main
loop so the cooperative server gets polled."
  (let ((answer #f)
        (loop (g-main-loop-new #f #f)))

    ;; The client runs in its own thread: the main thread has a main loop to run.
    (call-with-new-thread
     (lambda ()
       (catch #t
         (lambda ()
           (let ((s (socket AF_UNIX SOCK_STREAM 0)))
             (connect s AF_UNIX path)
             (read-to-prompt s)                 ; the greeting
             (display expression s)
             (newline s)
             (force-output s)
             (set! answer (read-to-prompt s))
             (close s)))
         (lambda (key . rest)
           (set! answer (format #f "CLIENT-ERROR ~a" key))))
       (g-main-loop-quit loop)))

    ;; A safety net, so a bug in the server does not hang the suite.
    (g-timeout-add timeout-ms (lambda () (g-main-loop-quit loop) #f))
    (g-main-loop-run loop)
    answer))

(test-begin "repl")

(test-group "socket path"
  (test-assert "under XDG_RUNTIME_DIR"
    (string-prefix? (getenv "XDG_RUNTIME_DIR") (repl-socket-path)))
  (test-assert "named by instance"
    (string-suffix? "stk-test-repl.sock" (repl-socket-path)))
  (test-assert "in a scheme-toolkit directory"
    (string-contains (repl-socket-path) "/scheme-toolkit/")))

(test-group "start, evaluate, stop"
  (test-assert "not running to begin with" (not (repl-running?)))
  (let ((path (start-repl!)))
    (test-assert "running" (repl-running?))
    (test-assert "the socket exists" (file-exists? path))

    (let ((answer (ask path "(+ 40 2)")))
      (test-assert "the expression was evaluated in the shell"
        (and (string? answer) (string-contains answer "42"))))

    ;; The whole reason for the cooperative server: evaluation happens on the
    ;; MAIN thread.  If it did not, the reactive core's parameters would be
    ;; thread defaults and an effect created here would have no scope.
    ;;
    ;; Asserted by IDENTITY rather than by the thread's name: the name Guile
    ;; gives the main thread is not guaranteed to contain anything in
    ;; particular, and what actually matters is that it is the same thread
    ;; across evaluations -- and the same one that would run signal handlers.
    (ask path "(define stk-main-thread (current-thread))")
    (let ((answer (ask path "(eq? stk-main-thread (current-thread))")))
      (test-assert "it evaluated on one and the same thread"
        (and (string? answer) (string-contains answer "#t"))))

    ;; A definition persists, which is what makes the REPL useful for poking a
    ;; running shell rather than only for one-off expressions.
    (ask path "(define stk-probe 7)")
    (let ((answer (ask path "(* stk-probe 6)")))
      (test-assert "state persists between connections"
        (and (string? answer) (string-contains answer "42"))))

    (stop-repl!)
    (test-assert "stopped" (not (repl-running?)))
    (test-assert "the socket was removed" (not (file-exists? path)))))

(test-group "a stale socket does not block a restart"
  ;; A crashed shell leaves the socket file behind.  Starting again must take
  ;; the path over rather than failing, or the shell would need a manual rm
  ;; after every crash.
  (let ((path (repl-socket-path)))
    (call-with-output-file path (lambda (p) (display "left by a dead shell" p)))
    (test-assert "a leftover file at the path does not stop start-repl!"
      (catch #t (lambda () (start-repl!) #t) (lambda args #f)))
    (test-assert "and the REPL answers on it"
      (let ((answer (ask path "(+ 1 1)")))
        (and (string? answer) (string-contains answer "2"))))
    (stop-repl!)))

(test-end "repl")
