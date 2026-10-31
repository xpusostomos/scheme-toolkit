;;; (scheme-toolkit repl-client) -- this shell's side of talking to a RUNNING
;;; shell, which is what `scheme-toolkit eval', `repl' and `list' are.
;;;
;;; **IT STARTS NO SHELL.** The server half is `(scheme-toolkit repl)' - a shell
;;; opens that door during startup - and this connects to one that is already
;;; open. What is typed or sent here is evaluated *in the shell's process*, at
;;; its back door, so this needs nothing but a socket.
;;;
;;; **THE CLIENT IS NOT HERE.** It was: the socket, the prompt reading, the test
;;; for whether an answer was an error, and the two threads of an interactive
;;; session, all in `tools/repl-cli.scm' - and then schemacs' client was the same
;;; code again, so both are `(scheme-utils repl client)' now. What is left here
;;; is the toolkit's POLICY on top of it: WHICH SHELL a command with no `-i'
;;; means, and how to say that nothing is running. Its names follow schemacs'
;;; `(schemacs repl-client)' for the same reason: two programs talking to the
;;; same door should read alike.
;;;
;;; **AND THE ONE BUG THIS FILE EXISTS TO NOT REPEAT.** The client it replaces
;;; `close'd the socket when the terminal's input ended, which discards whatever
;;; the shell had already written and not yet sent - measured, a piped
;;; `scheme-toolkit repl -i NAME' lost the answer every time, printing the prompt
;;; and a bare `$'. The shared session half-closes (`shutdown') instead, so the
;;; answer on its way arrives and the shell sees the end of input. Nothing here
;;; reads or writes a socket: the session, the expression and the close all come
;;; from the shared client, which is tested there.

(define-module (scheme-toolkit repl-client)
  #:use-module ((scheme-utils repl client)
                #:select (repl-close
                          repl-connect
                          repl-eval-values
                          repl-run-session))
  ;; Which shells are RUNNING, which is what the policy below is decided on.
  #:use-module ((scheme-utils repl server) #:select (live-instances))
  ;; This shell's own door settings, and the path an instance's socket is at.
  #:use-module (scheme-toolkit repl)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-13)
  #:export (client-fail
            client-instance
            client-connect
            run-repl-client
            run-shell-expression))

;;; ---------------------------------------------------------------------------
;;; Complaining
;;; ---------------------------------------------------------------------------

(define (client-fail fmt . args)
  "Raise the complaint a COMMAND LINE has made, with the text a user needs.

**A DISTINCT KEY, AND NOT `error'.** The tool above has to tell the client's
complaints - nothing running, several running, nothing listening - from a bug in
the client, and it has to print the text as it stands. `(error ...)' packs its
message into Guile's own `misc-error' arguments, where picking it out again is
guesswork: the first argument is the *procedure*, not the message, and a handler
that assumes otherwise rethrows and the user gets a backtrace instead of the
sentence. Measured, right here."
  (throw 'client-error (apply format #f fmt args)))

;;; ---------------------------------------------------------------------------
;;; Which shell
;;; ---------------------------------------------------------------------------

(define (client-instance name)
  "The shell NAME means, or the one obvious shell, or an error.

THE ORDER IS THE POINT, and it is the same shape as `(schemacs repl-client)''s
rule for a bare `--repl': what the user NAMED, then what the launcher said
(`SCHEME_TOOLKIT_INSTANCE', which is how a shell is named from the environment
that started it), then - only when there is exactly ONE running shell - that
one. Several running and none named is an error rather than a guess: an
expression is being sent somewhere, and a coin toss about where is worse than
being asked."
  (or (let ((given (or name (getenv "SCHEME_TOOLKIT_INSTANCE"))))
        ;; **AN EMPTY SETTING IS NOT A NAME.** `SCHEME_TOOLKIT_INSTANCE=""` is
        ;; what a launcher that has nothing to say produces - an unset variable
        ;; exported by a script, `sh -c 'FOO= cmd'` - and taking it for the name
        ;; of a shell gives "no shell is listening on .../.sock", which reads as
        ;; a bug in this program rather than as `-i' being needed.
        (and given (not (string=? given "")) given))
      (let ((live (live-instances)))
        (cond ((null? live)
               (client-fail "no shells are running (try `scheme-toolkit list')"))
              ((null? (cdr live)) (car live))
              (else
               (client-fail "several shells are running: ~a~%  name one with -i"
                            (string-join live ", ")))))))

(define (client-connect instance)
  "A socket to INSTANCE's back door, or an error worth its own words.

\"no shell is listening here\" and \"something is listening and does not answer\"
are different faults with different fixes - start one, or delete the socket a
crashed shell left behind - so they are different messages."
  (let ((path (repl-socket-path instance)))
    (unless (file-exists? path)
      (client-fail "no shell is listening on ~a~%  (is it running? try `scheme-toolkit list')"
                   path))
    (or (repl-connect path)
        (client-fail "cannot connect to ~a~%  (stale socket from a crashed shell?)"
                     path))))

;;; ---------------------------------------------------------------------------
;;; The two things a caller does
;;; ---------------------------------------------------------------------------

(define (run-repl-client name)
  "Be a REPL for a running shell: `scheme-toolkit repl'.

The session is the shared client's, which is what half-closes on end of input
rather than closing - see this file's header for what a close cost."
  (repl-run-session (client-connect (client-instance name))))

(define (run-shell-expression name expression)
  "Evaluate EXPRESSION in a running shell. Answers its text and whether it was
an error, for the caller to print and to choose an exit status with.

**THE SOCKET IS CLOSED EITHER WAY, AND THAT IS NOT TIDINESS.** A shell serves
ONE client session at a time, and a session nobody closes leaves the door's
reader parked on it: the next client is accepted and then never greeted, so
`eval' reports nothing answering and a session hangs with no banner. Closed in a
`dynamic-wind' because the error path is a `throw' and a socket left open there
is the same fault."
  (let ((socket (client-connect (client-instance name))))
    (dynamic-wind
      (lambda () #f)
      (lambda () (repl-eval-values socket expression))
      (lambda () (repl-close socket)))))
