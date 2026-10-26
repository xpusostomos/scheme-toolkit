;;; (scheme-toolkit service) -- authoring a shell's own observable services
;;;
;;; Every shell needs services Astal does not provide -- a night light, a screen
;;; recorder, the clipboard -- and every reference shell solves it the same way:
;;; a GObject with properties and signals.  That is what makes a service
;;; observable from the reactive core for free: a property declared here fires
;;; notify:: exactly as a built-in one does, so create-binding works on it
;;; unchanged, and a signal is just another thing to connect to.
;;;
;;; This module is mostly a macro, because G-Golf's define-class already IS the
;;; decorator layer that Gnim's gobject.ts provides for TypeScript.  What is
;;; added:
;;;
;;;   - #:signals sugar, so a signal does not need its flags spelled out;
;;;   - a memoised singleton, which is what get_default() is on an Astal service.
;;;
;;; G-Golf's own signal syntax, which this follows, from its adw-1 demo:
;;;
;;;   #:g-signal `(add-toast          ; name
;;;                none               ; return type
;;;                (,<adw-toast>)     ; parameter types
;;;                (run-first))       ; flags

(define-module (scheme-toolkit service)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:export (define-service
            service-get-default
            service-ref
            service-reset!
            service-bind))

;;; ---------------------------------------------------------------------------
;;; Signal sugar
;;; ---------------------------------------------------------------------------

;; A shell's own signals always return nothing and run their handlers in
;; registration order; only the name and parameter types are worth writing.
;;
;;   (changed)              =>  '(changed none () (run-first))
;;   (moved <workspace>)    =>  '(moved none (<workspace>) (run-first))
;;
;; QUOTED, and that matters.  The class options are evaluated, so a bare
;; (changed none () (run-first)) would be read as calls to `changed' and
;; `run-first'.  G-Golf's own example writes a backquote for the same reason.
(define (expand-signal spec)
  (let ((name (car spec))
        (params (cdr spec)))
    `(quote (,name none ,params (run-first)))))

(define (expand-signals specs)
  (map expand-signal specs))

;; Walk the class options, turning #:signals into one #:g-signal per entry.
;;
;; Three shapes have to be told apart, which is what makes this fiddly:
;;
;;   (enabled #:g-param '(...) #:accessor !enabled)   a SLOT, passed through
;;   #:g-type-name "StNightLight"                     a keyword option
;;   #:signals ((changed))                            ours, to expand
;;
;; A slot is a list; a keyword option starts a keyword; #:signals is a keyword
;; whose value is a list of signal specs.
;;
;; The expansion happens at EXPAND time, so define-class never sees #:signals --
;; it has no such option and would reject it.
;; G-Golf's define-class requires the SLOTS FIRST and every keyword option
;; after them.
;;
;; `class'''s parser reads slots until it meets the first keyword, and then
;; insists the rest of the list is keyword/value pairs.  An option written before
;; a slot therefore makes it try to read the slots as keywords and fail -- and
;; the error shows only the REMAINING arguments, so it looks like the slots are
;; the problem when the real problem is something earlier that should not have
;; been there.  This cost a long detour.
;;
;; So the options are grouped explicitly rather than passed through in source
;; order: slots, then keyword options, then #:g-signal last.
;;
;; And exactly ONE #:g-signal.  Two make it fail the same way -- also a parser
;; limitation, not a design one, since install-signals happily loops over
;; several.  One is enough for the shape these services take: a single
;; "changed", which is what a widget binds to.
(define (rewrite-options options)
  (let loop ((rest options) (slots '()) (kwargs '()) (signal #f))
    (cond ((null? rest)
           (append (reverse! slots)
                   (reverse! kwargs)
                   (if signal (list #:g-signal signal) '())))
          ((eq? (car rest) #:signals)
           (unless (pair? (cdr rest))
             (error "define-service: #:signals needs a list of signal specs"))
           (let ((specs (cadr rest)))
             (when (> (length specs) 1)
               (error (string-append
                       "define-service: G-Golf's define-class accepts one "
                       "#:g-signal, so #:signals takes at most one entry -- got "
                       (number->string (length specs)) ".  Register extras with "
                       "g-signal-newv, or define the class with define-class.")))
             (loop (cddr rest) slots kwargs
                   (and (pair? specs) (expand-signal (car specs))))))
          ;; A slot form is a list; G-Golf wants these before any keyword.
          ((pair? (car rest))
           (loop (cdr rest) (cons (car rest) slots) kwargs signal))
          ;; A keyword option, as a (keyword value) pair.
          (else
           (loop (cddr rest) slots
                 (cons (cadr rest) (cons (car rest) kwargs))
                 signal)))))

(define-syntax define-service
  (lambda (stx)
    "Syntax: (define-service <class> OPTION ...)

Define a GObject service, and a memoised singleton constructor for it.

  (define-service <night-light>
    #:g-type-name \"StNightLight\"
    (enabled     #:g-param '(boolean #:default #f) #:accessor !enabled)
    (temperature #:g-param '(uint #:default 4000)  #:accessor !temperature)
    #:signals ((changed)))

SLOT forms are G-Golf's own, so #:g-param and #:accessor mean what they mean
there -- and #:g-param is the syntax that actually registers a property, which
G-Golf's own docs are vague about.

There is deliberately no #:init.  G-Golf initialises a GObject subclass through
an `initialize' method, not a class option:

  (define-method (initialize (self <night-light>) initargs)
    (next-method)
    (setup! self))

Defines two things: the class CLASS, and a nullary constructor named after it
with the angle brackets stripped and -default appended, so <night-light> gives
night-light-default.  That constructor is the get_default() of this service: one
instance, made on first use."
    (syntax-case stx ()
      ((_ class-name option ...)
       (let* ((name (syntax->datum #'class-name))
              ;; <night-light> => night-light-default
              (base (let ((s (symbol->string name)))
                      (if (and (string-prefix? "<" s) (string-suffix? ">" s))
                          (substring s 1 (1- (string-length s)))
                          s)))
              (ctor (string->symbol (string-append base "-default")))
              (opts (rewrite-options (syntax->datum #'(option ...))))
              ;; The WHOLE form is built as a datum and given the caller's
              ;; context.  A template cannot splice `opts' -- it is one value
              ;; holding a list, not a syntax list -- and unquote-splicing a
              ;; datum into syntax does not work either.  Building the form and
              ;; wrapping it once avoids both.
              (form `(begin
                       (define-class ,name (<gobject>) ,@opts)
                       (define (,ctor) (service-get-default ,name)))))
         (datum->syntax #'class-name form))))))

;;; ---------------------------------------------------------------------------
;;; Singletons
;;; ---------------------------------------------------------------------------

;; Keys are classes, so eq? hashing; and every operation on it is a
;; hashq-* one.  Mixing hashq-set! with hash-remove! on the same table
;; does not work -- the table's own hash function is fixed at creation --
;; and the symptom is a reset that silently does nothing.
(define %services (make-hash-table))

(define (service-get-default class)
  "The singleton instance of CLASS, created on first use.

Memoised, so repeated calls from a widget's build path do not allocate.  A
service needing constructor arguments cannot use this; make it directly."
  (or (hashq-ref %services class)
      (let ((instance (make class)))
        (hashq-set! %services class instance)
        instance)))

(define (service-reset! class)
  "Forget CLASS's singleton, so the next service-get-default makes a fresh one.
For tests, and for a service that must be rebuilt after a failure."
  (hashq-remove! %services class)
  #t)

(define (service-ref class)
  "The singleton for CLASS if one exists, without creating it."
  (hashq-ref %services class))

;;; ---------------------------------------------------------------------------
;;; Access
;;; ---------------------------------------------------------------------------

(define* (service-bind service prop #:optional (name 'service))
  "A reactive accessor over one of SERVICE's properties.

The point of declaring properties with #:g-param is that this works with no
further plumbing."
  (create-binding service (if (string? prop) prop (symbol->string prop)) name))
