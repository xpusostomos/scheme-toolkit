;;; (scheme-toolkit time) -- interval, timeout, idle, and create-poll
;;;
;;; Built on AstalIO.Time, which is what AGS's lib/time.ts was a port of, so
;;; the shape matches the reference shells.  AstalIO.Time gives cancellable
;;; timer objects with `now' and `cancelled' signals; these procedures wrap
;;; them and add the one thing a widget actually wants, `create-poll'.
;;;
;;; `create-poll' returns a COLD accessor: it runs the command only while
;;; something is subscribed.  A clock widget that is not on screen therefore
;;; costs nothing -- no subprocess, no timer -- which is the same discipline
;;; create-computed follows for its sources.
;;;
;;; These need a running GLib main loop to fire, so they are inert until the
;;; application runs.

(define-module (scheme-toolkit time)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-13)

  #:export (interval timeout idle
            timer-cancel
            create-poll))

;; Constructors on the AstalIO.Time class, as G-Golf names them.
(eval-when (expand load eval)
  (use-modules (g-golf))
  (g-irepository-require "AstalIO" #:version "0.1")
  (gi-import-by-name "AstalIO" "Time"))

(define* (interval ms proc #:key (name 'interval) (immediate #f))
  "Call PROC every MS milliseconds.  Returns a timer; `timer-cancel' stops it.

The AstalIO.Time constructor runs the callback immediately as well as on each
tick, which is usually what a widget wants -- a clock should not show a blank
for its first second."
  (astal-io-time-interval ms (lambda (self) (proc))))

(define* (timeout ms proc #:key (name 'timeout))
  "Call PROC once after MS milliseconds."
  (astal-io-time-timeout ms (lambda (self) (proc))))

(define* (idle proc #:key (name 'idle))
  "Call PROC once, as soon as the main loop is idle."
  (astal-io-time-idle (lambda (self) (proc))))

(define (timer-cancel timer)
  "Stop TIMER.  Idempotent, and safe to call from a cleanup."
  (catch #t
    (lambda () (astal-io-time-cancel timer))
    (lambda args #f))
  timer)

;;; ---------------------------------------------------------------------------
;;; create-poll
;;; ---------------------------------------------------------------------------

(define* (create-poll initial-ms command #:key (transform #f) (name 'poll))
  "An accessor whose value is COMMAND's output, refreshed every INITIAL-MS.

COMMAND is either a procedure of no arguments, or a list to run as a program.
The timer runs only while the accessor has a subscriber, so a poll whose widget
is off screen costs nothing.

  (define clock (create-poll 1000 '(\"date\" \"+%H:%M\")))
  (label #:label clock)

TRANSFORM, when given, is applied to the raw string before it becomes the
value -- which is where a clock turns `date' output into the format it wants."
  (let ((value "")
        (timer #f)
        (subs (make-hash-table)))

    (define (run)
      (let ((out (attempt (lambda ()
                            (if (procedure? command)
                                (command)
                                (run-command-capture command))))))
        (set! value (if (result-ok? out)
                        (let ((v (result-value out)))
                          (if transform (transform v) v))
                        ;; A failed poll keeps the last good value rather than
                        ;; blanking the widget; the error is logged once by
                        ;; unwrap-or's caller-facing path.
                        (begin (log-error (result-value out) (format #f "~a" name))
                               value)))
        (for-each (lambda (thunk) (thunk))
                  (hash-map->list (lambda (k v) k) subs))))

    (define (start!)
      (unless timer
        (set! timer (interval initial-ms run))))

    (define (stop!)
      (when timer
        (timer-cancel timer)
        (set! timer #f)))

    (let ((acc (create-accessor (lambda () value) name
                              #:subscribe-fn
                              (lambda (thunk)
                                (hashq-set! subs thunk #t)
                                (when (= 1 (hash-count (const #t) subs))
                                  (start!)
                                  ;; Give the first read a value at once rather
                                  ;; than after a full interval.
                                  (run))
                                (lambda ()
                                  (hashq-remove! subs thunk)
                                  (when (zero? (hash-count (const #t) subs))
                                    (stop!)))))))
      acc)))

;;; ---------------------------------------------------------------------------
;;; A minimal command runner
;;; ---------------------------------------------------------------------------

;; Kept here rather than in (scheme-toolkit process) so that `time' does not
;; depend on it; process is a bigger module with its own concerns.  This is the
;; one-line form: run, collect stdout, strip the trailing newline.
(define (run-command-capture command)
  (let* ((port (apply open-pipe* OPEN_READ command))
         (out (read-string port)))
    (close-pipe port)
    (if (string? out)
        (string-trim-right out #\newline)
        "")))
