;;; (scheme-toolkit result) -- ok/err at the fallible boundaries
;;;
;;; Ported from ags2-shell's lib/result.ts, which is used at 119 `attempt',
;;; 73 `attempt_async' and 13 `unwrap_or' sites.  The point of the pattern is
;;; that a shell has a great many boundaries that can fail for reasons it
;;; cannot fix -- a missing `ddcutil', a compositor that does not answer, a
;;; config file that is not there -- and a shell that dies or throws at any of
;;; them is a shell that is not running.
;;;
;;; The distinguishing feature to keep is `unwrap-or' with a tag: it LOGS the
;;; failure and returns the fallback, so a widget shows a degraded value and
;;; the reason is in the journal.  A bare default would hide the failure; a
;;; throw would take the shell down.
;;;
;;; Guile has exceptions, so `attempt' is a wrapper over
;;; with-exception-handler rather than the JS `try' idiom -- but the shape at
;;; the call site is the same.

(define-module (scheme-toolkit result)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-9)
  #:export (ok err
            result? result-ok? result-value result-error
            unwrap unwrap-or unwrap-or-else
            attempt attempt-async
            log-error log-warning))

(define-record-type <result>
  (make-result ok? value)
  result?
  (ok? result-ok?)
  (value result-value))

(define (ok value) (make-result #t value))
(define (err error) (make-result #f error))

(define (result-error r)
  "The error of a failed result.  Raises if R succeeded -- use result-ok? first."
  (unless (result? r) (error "result-error: not a result" r))
  (when (result-ok? r)
    (error "result-error: the result is ok, not an error" (result-value r)))
  (result-value r))

(define (unwrap r)
  "The value of a successful result; raises the error of a failed one."
  (unless (result? r) (error "unwrap: not a result" r))
  (if (result-ok? r)
      (result-value r)
      (error "unwrap: the result is an error" (result-value r))))

(define* (unwrap-or r fallback #:optional (tag #f))
  "The value of R if it succeeded, otherwise FALLBACK.

A failure is LOGGED with TAG and then degraded, rather than thrown or silently
swallowed.  That combination is the whole reason this exists: the shell keeps
running with a sensible value, and the journal says what went wrong."
  (unless (result? r) (error "unwrap-or: not a result" r))
  (if (result-ok? r)
      (result-value r)
      (begin
        (log-error (result-value r)
                   (if tag (format #f "~a: using fallback" tag) "using fallback"))
        fallback)))

(define* (unwrap-or-else r thunk #:optional (tag #f))
  "Like unwrap-or, but the fallback is computed only when it is needed."
  (if (result-ok? r)
      (result-value r)
      (begin
        (when tag
          (log-error (result-value r)
                     (format #f "~a: computing a fallback" tag)))
        (thunk))))

(define (attempt thunk)
  "Run THUNK and capture any exception as an error result.

  (unwrap-or (attempt (lambda () (read-file path))) "" \"config\")"
  (catch #t
    (lambda () (ok (thunk)))
    (lambda (key . args)
      (err (if (null? args) key (cons key args))))))

(define (attempt-async thunk)
  "Like attempt, for a THUNK that returns immediately and does its work later.

Guile's exceptions do not cross a callback boundary, so a failure inside an
async operation cannot be captured here; the caller's callback must use
`attempt' itself.  What this does provide is a uniform shape at the call site,
and a guard around the *initiation*, which is where most of these fail (a
missing binary, a bad argument)."
  (attempt thunk))

(define* (log-error error #:optional (context ""))
  (format (current-error-port) "scheme-toolkit: error: ~a~@[ (~a)~]~%"
          (describe-error error)
          (and (string? context) (not (string=? context "")) context)))

(define* (log-warning message #:optional (context ""))
  (format (current-error-port) "scheme-toolkit: warning: ~a~@[ (~a)~]~%"
          message
          (and (string? context) (not (string=? context "")) context)))

(define (describe-error error)
  "A one-line rendering of whatever `catch' handed us.

A caught exception arrives as (KEY . ARGS), and the useful part -- a message
string, an offending value -- is usually near the front.  Not always, and the
loudest exception in the toolkit is Guile's own `error':

  (error \"900 is not valid\")   ->   (misc-error #f \"~A\" (\"900 is not valid\") #f)

THE MESSAGE IS A FORMAT STRING PLUS THE ARGUMENTS IT WANTS, which is why looking
for a string in the first two positions finds nothing -- `(car args)' is #f and
`(cadr args)' is the format \"~A\", not the text.  Nearly every `error' in Scheme
has this shape, so it is recognised here rather than printed as a list: a log
line reading

  error: misc-error (#f \"~A\" (\"900 is not valid\") #f)

is a log line nobody reads."
  (cond
   ((string? error) error)
   ((and (pair? error) (string? (car error))) (car error))
   ;; Guile's `error': (KEY #f FORMAT ARGS #f).  FORMAT is at index 2 and ARGS at
   ;; index 3 -- `error' keeps the format and its arguments apart and puts #f in
   ;; front of them, so a lookup that starts at the front finds nothing and this
   ;; case has to count.  Rendered through `format' so the arguments are
   ;; substituted; if the format is one this cannot apply, the format string
   ;; itself is still better than the whole list.
   ((and (pair? error) (pair? (cdr error)) (pair? (cddr error))
         (pair? (cdddr error))
         (string? (caddr error)) (list? (cadddr error)))
    (catch #t
      (lambda () (apply format #f (caddr error) (cadddr error)))
      (lambda args (caddr error))))
   ((and (pair? error) (pair? (cdr error)) (string? (cadr error))) (cadr error))
   ((pair? error) (format #f "~a ~s" (car error) (cdr error)))
   (else (format #f "~s" error))))
