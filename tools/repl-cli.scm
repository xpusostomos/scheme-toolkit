#!/usr/bin/env guile
!#
;;; tools/repl-cli.scm -- the command line for a running shell's back door
;;;
;;; Used by bin/scheme-toolkit for `eval', `repl' and `list'.  Kept here rather
;;; than inline in the wrapper so it is a real Scheme program: the wrapper is
;;; shell, and quoting Scheme inside shell strings goes wrong immediately.
;;;
;;; **WHAT IS HERE IS THE ARGUMENTS AND THE EXIT STATUS, and nothing else.**  The
;;; client - the socket, the session, the expression, the reading of an answer -
;;; is `(scheme-toolkit repl-client)', which is `(scheme-utils repl client)' plus
;;; this shell's policy about WHICH shell a command means.  This file is what a
;;; shell invokes; `bin/scheme-toolkit' is what says these verbs exist, and its
;;; `--help' is what documents them.
;;;
;;; The exit status is the contract a script uses: 0 when it worked, 1 when the
;;; shell reported an error in the expression, 2 when there was nothing to
;;; connect to or the command line was wrong.  Those are three different
;;; situations and the answer text alone cannot tell them apart.

(use-modules (scheme-toolkit repl-client))
(use-modules ((scheme-utils repl server) #:select (list-instances)))
(use-modules (ice-9 format))
(use-modules (srfi srfi-13))

(define (die fmt . args)
  (apply format (current-error-port)
         (string-append "scheme-toolkit: " fmt "\n") args)
  (exit 2))

(define (parse-args args)
  "Returns (instance-or-#f . expressions)."
  (let loop ((rest args) (instance #f) (exprs '()))
    (cond ((null? rest)
           (cons instance (reverse exprs)))
          ((string=? (car rest) "-i")
           (loop (cddr rest) (cadr rest) exprs))
          (else
           (loop (cdr rest) instance (cons (car rest) exprs))))))

(define (cmd-list)
  (list-instances)
  0)

(define (cmd-eval args)
  (let* ((parsed (parse-args args))
         (instance (car parsed))
         (exprs (cdr parsed)))
    (when (null? exprs)
      (die "eval: needs an expression"))
    ;; Joined with a space, so `eval '(+ 1 2)' and `eval "'(+ 1" "2)"' both
    ;; work -- how the shell quoted it should not matter.
    ;; **`call-with-values' AND NOT `let-values'.** The latter is
    ;; `(srfi srfi-11)'s and is not bound in this script, so `eval' died with
    ;; "Unbound variable: let-values" - the whole verb, from a form that reads
    ;; like syntax.  `check-unbound' had already said so, in as many words:
    ;; "possibly unbound variable `let-values'". That warning is worth reading.
    (call-with-values
        (lambda () (run-shell-expression instance (string-join exprs " ")))
      (lambda (text failed)
        (cond
         (failed
          (format (current-error-port) "~a\n" text)
          1)
         (else
          ;; The value as the shell rendered it, which is what a caller piping
          ;; this expects.  A value that printed nothing prints nothing here.
          (unless (string=? text "")
            (format #t "~a\n" text))
          0))))))

(define (cmd-repl args)
  (let ((parsed (parse-args args)))
    (run-repl-client (car parsed))
    0))

(define (usage)
  (format #t "scheme-toolkit eval [-i INSTANCE] EXPR...~%")
  (format #t "    evaluate EXPR in the running shell and print the value~%")
  (format #t "scheme-toolkit repl [-i INSTANCE]~%")
  (format #t "    an interactive session in the running shell~%")
  (format #t "scheme-toolkit list~%")
  (format #t "    the running shells~%")
  0)

(define (main args)
  (let ((argv (cdr args)))
    ;; **THE CLIENT'S COMPLAINTS ARE A KEY OF THEIR OWN**, and that is what this
    ;; catch is for: "no shells are running", "several are running: ... name one
    ;; with -i", "no shell is listening on ..." are things a user acts on, and
    ;; the client words them. Anything else that reaches here IS a bug and its
    ;; backtrace is worth more than a summary, so it is not caught at all.
    (catch 'client-error
      (lambda ()
        (cond ((null? argv) (usage))
              ((string=? (car argv) "list") (cmd-list))
              ((string=? (car argv) "eval") (cmd-eval (cdr argv)))
              ((string=? (car argv) "repl") (cmd-repl (cdr argv)))
              (else (usage) 2)))
      (lambda (key message) (die "~a" message)))))

(exit (main (command-line)))
