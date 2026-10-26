#!/usr/bin/env guile
!#
;;; tools/repl-cli.scm -- the client for a running shell's back door
;;;
;;; Used by bin/scheme-toolkit for `eval', `repl' and `list'.  Kept here rather
;;; than inline in the wrapper so it is a real Scheme program: the wrapper is
;;; shell, and quoting Scheme inside shell strings goes wrong immediately.
;;;
;;; The protocol is the cooperative server's -- the same one Geiser speaks:
;;;
;;;   server:   banner, then "scheme@(...)> "
;;;   client:   one expression and a newline
;;;   server:   the value or the error, then the prompt again
;;;
;;; Two details matter and both are easy to get wrong:
;;;
;;;   - The prompt has NO newline after it, so the reader must read a CHARACTER
;;;     at a time and test the last line.  read-line would wait forever.
;;;   - An error leaves a NESTED prompt -- "scheme@(guile-user) [1]> " -- with a
;;;     bracket in it.  That is how Guile says it is in a debugger, and it is the
;;;     only reliable way to tell an error from a value that merely looks like
;;;     one: a value can end with ">" too, as #<port ...> does.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit repl))
(use-modules (ice-9 rdelim))
(use-modules (srfi srfi-13))
(use-modules (ice-9 format))

(define (die fmt . args)
  (apply format (current-error-port)
         (string-append "scheme-toolkit: " fmt "\n") args)
  (exit 2))

;;; ---------------------------------------------------------------------------
;;; Reading the server
;;; ---------------------------------------------------------------------------

(define (last-line text)
  (let loop ((i (- (string-length text) 1)))
    (cond ((< i 0) text)
          ((char=? (string-ref text i) #\newline)
           (substring text (+ i 1) (string-length text)))
          (else (loop (- i 1))))))

(define (prompt? line)
  (and (string-prefix? "scheme@" line)
       (string-suffix? "> " line)))

(define (read-to-prompt s)
  "Everything up to and including the next prompt, or #f at end of stream."
  (let loop ((out '()))
    (let ((c (read-char s)))
      (if (eof-object? c)
          #f
          (let ((out (cons c out)))
            (if (prompt? (last-line (list->string (reverse out))))
                (list->string (reverse out))
                (loop out)))))))

(define (answer-text answer)
  "ANSWER without the prompt it ends with."
  (let loop ((i (- (string-length answer) 1)))
    (cond ((< i 0) answer)
          ((char=? (string-ref answer i) #\newline)
           (string-trim-right (substring answer 0 i)))
          (else (loop (- i 1))))))

(define (answer-error? answer)
  "Whether ANSWER was an error: a nested prompt has a bracket in it."
  (let ((line (last-line answer)))
    (and (prompt? line) (string-contains line "[") #t)))

;;; ---------------------------------------------------------------------------
;;; Connecting
;;; ---------------------------------------------------------------------------

(define (connect-to instance)
  (let ((path (repl-socket-path instance)))
    (unless (file-exists? path)
      (die "no shell is listening on ~a~%  (is it running? try `scheme-toolkit list')"
           path))
    (let ((s (socket AF_UNIX SOCK_STREAM 0)))
      (catch #t
        (lambda () (connect s AF_UNIX path) s)
        (lambda (key . rest)
          (die "cannot connect to ~a: ~a~%  (stale socket from a crashed shell?)"
               path key))))))

(define (default-instance)
  (or (getenv "SCHEME_TOOLKIT_INSTANCE")
      (let ((live (live-instances)))
        ;; Exactly one running instance is unambiguous.  More than one and the
        ;; user names it, rather than being guessed at.
        (cond ((null? live) (die "no running instances (try `scheme-toolkit list')"))
              ((null? (cdr live)) (car live))
              (else (die "several shells are running: ~a~%  name one with -i"
                         (string-join live ", ")))))))

(define (parse-args args)
  "Returns (instance . expressions)."
  (let loop ((rest args) (instance #f) (exprs '()))
    (cond ((null? rest)
           (cons (or instance (default-instance)) (reverse exprs)))
          ((string=? (car rest) "-i")
           (loop (cddr rest) (cadr rest) exprs))
          (else
           (loop (cdr rest) instance (cons (car rest) exprs))))))

;;; ---------------------------------------------------------------------------
;;; The three commands
;;; ---------------------------------------------------------------------------

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
    (let ((expression (string-join exprs " "))
          (s (connect-to instance)))
      (read-to-prompt s)
      (display expression s)
      (newline s)
      (force-output s)
      (let ((answer (read-to-prompt s)))
        (close s)
        (cond
         ((not answer)
          (format (current-error-port)
                  "scheme-toolkit: the shell closed the connection\n")
          1)
         ((answer-error? answer)
          (format (current-error-port) "~a\n" (answer-text answer))
          1)
         (else
          ;; Print the value as the REPL rendered it, which is what a caller
          ;; piping this expects.
          (let ((text (answer-text answer)))
            (unless (string=? text "")
              (format #t "~a\n" text)))
          0))))))

(define (cmd-repl args)
  (let* ((parsed (parse-args args))
         (s (connect-to (car parsed))))
    (display (or (read-to-prompt s) "") (current-output-port))
    (force-output)
    ;; Two directions, two threads: both ends can be silent at once.  The
    ;; server's side is the main thread, so the server closing ends the session.
    (call-with-new-thread
     (lambda ()
       (let loop ()
         (let ((line (read-line)))
           (if (eof-object? line)
               (catch #t (lambda () (close s)) (lambda args #f))
               (begin
                 (display line s)
                 (newline s)
                 (force-output s)
                 (loop)))))))
    (let loop ()
      (let ((c (read-char s)))
        (unless (eof-object? c)
          (write-char c (current-output-port))
          (force-output)
          (loop))))
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
    (cond
     ((null? argv) (usage))
     ((string=? (car argv) "list") (cmd-list))
     ((string=? (car argv) "eval") (cmd-eval (cdr argv)))
     ((string=? (car argv) "repl") (cmd-repl (cdr argv)))
     (else (usage) 2))))

(exit (main (command-line)))
