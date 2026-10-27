;;; (scheme-toolkit process) -- subprocesses, streaming and one-shot
;;;
;;; AstalIO.Process is what AGS's lib/process.ts was a port of, and its shape is
;;; not the one you would guess, so it is worth stating:
;;;
;;;   astal_io_process_execv(argv)          SYNCHRONOUS, returns stdout
;;;   astal_io_process_subprocessv(argv)    async, returns a Process whose
;;;                                         signals carry the output one line
;;;                                         at a time: `stdout', `stderr',
;;;                                         `exit' (with the exit code)
;;
;;; There is no callback argument and no fire-and-forget constructor.  So:
;;;
;;;   (run-command '("brightnessctl" "get"))     blocks, returns the string
;;;   (subprocess '("swaybg" "-i" "w.jpg")       streams, does not block
;;;      #:stdout (lambda (line) ...))
;;;
;;; `exec-async' is the third case -- start it and do not wait -- and it is
;;; implemented by forking with Guile's own open-pipe rather than by Astal,
;;; because execv blocks and blocking in a keybinding handler is exactly the
;;; bug this module exists to prevent.

(define-module (scheme-toolkit process)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  ;; get-string-all is (ice-9 textual-ports) in Guile 3, and its absence was
  ;; hidden by a catch: exec-async silently read nothing.
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-13)

  #:export (exec exec-async
            subprocess
            run-command
            create-subprocess))

;; The AstalIO.Process functions, as G-Golf names them.  Kept in one place
;; because the spellings are not guessable.
(eval-when (expand load eval)
  (use-modules (g-golf))
  (g-irepository-require "AstalIO" #:version "0.1")
  (gi-import-by-name "AstalIO" "Process"))

(define (argv-strings command)
  (map (lambda (x) (if (string? x) x (format #f "~a" x))) command))

;;; ---------------------------------------------------------------------------
;;; Fire and forget
;;; ---------------------------------------------------------------------------

(define (exec-async command)
  "Start COMMAND and return at once, without waiting for it or keeping a handle.

Guile's own pipe, not AstalIO's execv: execv is synchronous, and a keybinding
handler that blocks on `hyprctl' is a bar that stutters.  The child is
reaped on a separate thread so that a long-lived process does not accumulate
zombies.

Returns #t if it was started, #f if it could not be -- a missing binary logs
and returns #f rather than taking the shell down."
  (let ((r (attempt (lambda ()
                      ;; open-pipe* is variadic: the program and each argument
                      ;; are separate arguments, so the list is applied.
                      (apply open-pipe* OPEN_READ (argv-strings command))))))
    (if (result-ok? r)
        (begin
          ;; open-pipe* returns a pipe; read it to EOF on another thread so the
          ;; child is reaped without blocking the main loop.
          (let ((port (result-value r)))
            (catch #t
              (lambda ()
                (call-with-new-thread
                 (lambda ()
                   (catch #t
                     (lambda () (get-string-all port) (close-pipe port))
                     (lambda args #f)))))
              (lambda args #f)))
          #t)
        (begin
          (log-error (result-value r) (format #f "exec-async ~a" command))
          #f))))

(define (exec command)
  "Alias for exec-async, kept because the reference shells spell it `exec'."
  (exec-async command))

;;; ---------------------------------------------------------------------------
;;; Streaming
;;; ---------------------------------------------------------------------------

(define* (subprocess command #:key stdout stderr on-exit)
  "Start COMMAND and call STDOUT with each line of its output, STDERR with each
line of its errors, and ON-EXIT with the exit code.

Returns at once with the Process; the callbacks arrive later, on the main
thread, so they may touch widgets.  Kill it with `astal-io-process-kill'.

  (subprocess '(\"wl-paste\" \"--watch\" \"cliphist\" \"store\")
    #:stdout (lambda (line) ...))"
  (let ((proc (astal-io-process-subprocessv (argv-strings command))))
    (when stdout (connect proc 'stdout (lambda (p line) (stdout line))))
    (when stderr (connect proc 'stderr (lambda (p line) (stderr line))))
    (when on-exit (connect proc 'exit (lambda (p code) (on-exit code))))
    proc))

;;; ---------------------------------------------------------------------------
;;; One-shot capture
;;; ---------------------------------------------------------------------------

(define* (run-command command #:key (transform #f))
  "Run COMMAND, wait for it, and return its stdout (trailing newline stripped),
or #f if it could not be run.

This BLOCKS.  It is for the cases where a widget genuinely needs the value
before it can be built -- a monitor list at startup -- or for a command that
finishes quickly.  Anything that repeats wants create-subprocess or
create-poll, which do not block the loop.

A non-zero exit is not treated as failure: many useful commands (grep among
them) signal with their status and still print the answer on stdout."
  (let ((r (attempt (lambda ()
                      (string-trim-right
                       (astal-io-process-execv (argv-strings command))
                       #\newline)))))
    (if (result-ok? r)
        (let ((v (result-value r)))
          (if transform (transform v) v))
        (begin
          (log-error (result-value r) (format #f "run-command ~a" command))
          #f))))

;;; ---------------------------------------------------------------------------
;;; create-subprocess
;;; ---------------------------------------------------------------------------

(define* (create-subprocess initial command #:key (transform #f) (name 'subprocess))
  "A cold accessor over a command that streams output.

The command runs only while the accessor has a subscriber, which is what makes
a watching subprocess free when its widget is off screen.  Each line it prints
becomes the accessor's value: a widget bound to it shows the latest line, not
the accumulated output.

  (define brightness
    (create-subprocess \"\" '(\"brightnessctl\" \"-m\") #:transform parse-m))
  (label #:label brightness)"
  (let ((value initial)
        (proc #f)
        (subs (make-hash-table)))

    (define (emit! line)
      (set! value (if transform (transform line) line))
      (for-each (lambda (thunk) (thunk))
                (hash-map->list (lambda (k v) k) subs)))

    (define (start!)
      (unless proc
        (set! proc
              (subprocess command
                          #:stdout emit!
                          #:stderr (lambda (line)
                                     (log-error line (format #f "~a stderr" name)))))))

    (define (stop!)
      (when proc
        (catch #t (lambda () (astal-io-process-kill proc)) (lambda args #f))
        (set! proc #f)))

    (create-accessor
     (lambda () value)
     name
     #:subscribe-fn
     (lambda (thunk)
       (hashq-set! subs thunk #t)
       (when (= 1 (hash-count (const #t) subs)) (start!))
       (lambda ()
         (hashq-remove! subs thunk)
         (when (zero? (hash-count (const #t) subs)) (stop!)))))))
