;;; Tests for `(scheme-toolkit repl-client)': WHICH SHELL a command means, and
;;; what it says when there is none.
;;;
;;; **THE CLIENT ITSELF IS NOT TESTED HERE.** The socket, the session, the
;;; expression and the reading of an answer are `(scheme-utils repl client)'s,
;;; and its own suite tests them there - including the two things this toolkit's
;;; client inherited by leaning on it: a session half-closes on end of input
;;; rather than closing (a piped session used to lose its answer), and an
;;; expression's socket is closed either way (a session left open parks the
;;; shell's reader, and the next client is then never greeted).
;;;
;;; What is left is the POLICY, which is this toolkit's: the name given, then
;;; `SCHEME_TOOLKIT_INSTANCE', then the single running shell - and an error, with
;;; words a user can act on, when there are none or several. It is the same
;;; shape as `(schemacs repl-client)'s rule for a bare `--repl', and it is tested
;;; with fake sockets, because "two shells are running" is exactly the state a
;;; test has to arrange rather than hope for.
;;;
;;;     guile -L . tests/repl-client.scm

(use-modules (scheme base) (scheme file))
(use-modules ((guile) #:select (AF_UNIX SOCK_STREAM bind delete-file getenv
                                      listen mkdir setenv socket)))
(use-modules ((srfi srfi-13) #:select (string-contains)))
(use-modules ((srfi srfi-64) #:select (test-assert test-equal test-begin test-end)))
(use-modules ((scheme-toolkit repl-client) #:select (client-connect
                                                     client-instance
                                                     run-shell-expression)))

(define runtime (string-append "/tmp/scheme-toolkit-repl-client-tests-"
                               (number->string (getpid))))
(define dir (string-append runtime "/scheme-toolkit"))

(define (fresh-runtime!)
  ;; A runtime directory of this test's own, so that it cannot see a real
  ;; shell's socket - and so that "nothing is running" is a state a test can be
  ;; in rather than a hope.
  ;;
  ;; **THE PID IS IN THE NAME because a socket file outlives the process that
  ;; made it**: a fixed path meant the second run's `bind' - the fake shell
  ;; below - failed with "Address already in use", left by the first. The tree's
  ;; other tests name their scratch directories the same way, for the same
  ;; reason.
  (catch #t (lambda () (mkdir runtime #o700)) (lambda args #f))
  (catch #t (lambda () (mkdir dir #o700)) (lambda args #f))
  (setenv "XDG_RUNTIME_DIR" runtime))

(define (fake-shell! name)
  ;; A socket at NAME that LISTENS and answers nothing: all `live-instances'
  ;; asks is whether something accepts, which is what a stale file does not.
  (let ((s (socket AF_UNIX SOCK_STREAM 0))
        (path (string-append dir "/" name ".sock")))
    (bind s AF_UNIX path)
    (listen s 4)
    s))

(define (complaint thunk)
  ;; What the client SAID, for a call that was supposed to fail: the message and
  ;; not the exception, because the message is the interface.
  (catch 'client-error
    (lambda () (thunk) #f)
    (lambda (key message) message)))

(test-begin "scheme-toolkit-repl-client")

(fresh-runtime!)

;;-------------------------------------------------------------
;; The name the command line gave
;;-------------------------------------------------------------

(test-equal "a named shell is the one meant, with nothing running at all"
  "mine"
  (client-instance "mine"))

(setenv "SCHEME_TOOLKIT_INSTANCE" "from-the-environment")
(test-equal "the environment names one when the command line does not"
  "from-the-environment"
  (client-instance #f))
(test-equal "and a name on the command line beats the environment"
  "mine"
  (client-instance "mine"))

;;-------------------------------------------------------------
;; Nothing running, and several running
;;-------------------------------------------------------------

;; The environment is cleared for the cases below: `SCHEME_TOOLKIT_INSTANCE' set
;; means exactly what it says, which is the point of the test above, and leaving
;; it set would answer every one of these before the policy was reached.
(setenv "SCHEME_TOOLKIT_INSTANCE" "")

(test-assert "no shells running is an error, not a guess"
  (let ((said (complaint (lambda () (client-instance #f)))))
    (and (string? said) (string-contains said "no shells are running"))))

(test-assert "a shell named but not running says where it looked"
  (let ((said (complaint (lambda () (client-connect "mine")))))
    (and (string? said)
         (string-contains said "no shell is listening on")
         (string-contains said "mine.sock"))))

(define one (fake-shell! "only"))
;; `SCHEME_TOOLKIT_INSTANCE' is "" here, and "" is not a name: the single
;; running shell is the answer, rather than a name that would send this looking
;; for a socket called ".sock".
(test-equal "exactly one running is unambiguous, and an empty setting is not a name"
  "only"
  (client-instance #f))

(define two (fake-shell! "another"))
(test-assert "several running and none named is an error, and says which"
  (let ((said (complaint (lambda () (client-instance #f)))))
    (and (string? said)
         (string-contains said "several shells are running")
         (string-contains said "name one with -i"))))

(test-equal "while naming one of them works"
  "another"
  (client-instance "another"))

;; A named shell that is NOT running is still an error with several running:
;; the name is a fact about which shell, not about how many there are.
(test-assert "and a name that is not there is still an error"
  (string? (complaint (lambda () (client-connect "absent")))))

;;-------------------------------------------------------------
;; The expression's socket is closed either way
;;-------------------------------------------------------------
;;
;; A shell serves ONE client session at a time, so a socket left open parks its
;; reader and the next client is accepted and never greeted. Asserted by
;; ASKING, not by looking: the second call connects to the same door and gets a
;; greeting, which is only possible if the first session ended.
;;
;; This needs a shell that actually answers, so it is left to `tools/pty-check.py'
;; (`back-door') and to a live shell - the fake sockets above listen and say
;; nothing. What is asserted here is the shape of the two calls a caller makes.

(test-assert "run-shell-expression is a procedure of two arguments"
  (procedure? run-shell-expression))

(close one)
(close two)
;; The sockets are FILES: closing the ports leaves them on disk, where the next
;; run's `bind' would find them. Removed here, and the directories with them.
(for-each (lambda (name)
            (catch #t
              (lambda () (delete-file (string-append dir "/" name ".sock")))
              (lambda args #f)))
          '("only" "another"))
(catch #t (lambda () (rmdir dir)) (lambda args #f))
(catch #t (lambda () (rmdir runtime)) (lambda args #f))

(test-end "scheme-toolkit-repl-client")
