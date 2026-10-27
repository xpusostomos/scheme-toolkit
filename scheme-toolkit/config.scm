;;; (scheme-toolkit config) -- typed, validated, persisted, live-reloading options
;;;
;;; The engine.  A shell declares its options and gets, for each one, an
;;; ACCESSOR that widgets bind to directly:
;;;
;;;   (define-config <desktop-config>
;;;     #:file "config.scm"
;;;     (clock-format  "%H:%M"  string?)
;;;     (bar-position  top      (lambda (v) (memq v '(top bottom)))))
;;;
;;;   (label #:label (config-ref 'clock-format))   ; updates when it changes
;;;
;;; Three decisions worth stating, because each has a cost:
;;;
;;; S-EXPRESSIONS, not JSON.  Guile reads and writes them natively, they allow
;;; comments, they carry proper types rather than strings, and a config can embed
;;; a computed value.  Every reference shell uses JSON because in JavaScript that
;;; is a one-liner; that reason does not transfer.  (HyprPanel's author lists the
;;; "JSON mess" as a motivating pain point.)
;;;
;;; ATOMIC WRITES, debounced.  A half-written config is worse than a stale one,
;;; so the write goes to a temporary file and is renamed into place.  Writes are
;;; debounced because dragging a slider would otherwise write on every frame.
;;;
;;; CORRUPT FILE RECOVERY.  A config that fails to parse is renamed .bad and
;;; regenerated from defaults, rather than stopping the shell.  A shell that will
;;; not start because of a typo in its own config is a shell you cannot fix
;;; without a terminal.

(define-module (scheme-toolkit config)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit result)
  #:use-module (scheme-toolkit file)
  #:use-module (scheme-toolkit time)
  #:use-module (oop goops)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:export (define-config
            config-ref
            config-set!
            config-value
            config-reset!
            config-save!
            config-reload!
            config-file
            config-options
            config-live?))

;;; ---------------------------------------------------------------------------
;;; A config object
;;; ---------------------------------------------------------------------------

;; One create-state per option, so the accessor a widget binds to is an ordinary
;; accessor and the write path is the ordinary setter.  A config option is not a
;; special kind of value; it is a state with a file behind it.
(define-record-type <config>
  (make-config-record options file accessors setters validators dirty?)
  config?
  (options    config-options)     ; ((name default validate) ...)
  (file       config-file set-config-file!)
  (accessors  config-accessors)   ; name -> accessor
  (setters    config-setters)     ; name -> setter
  (validators config-validators)  ; name -> validate
  (dirty?     config-dirty? set-config-dirty?!))

(define %configs (make-hash-table))
(define %save-handles (make-hash-table))

(define (register-config! name config)
  (hashq-set! %configs name config))

(define (config-for name)
  (or (hashq-ref %configs name)
      (error "config-ref: no config named" name)))

;;; ---------------------------------------------------------------------------
;;; Reading and writing the file
;;; ---------------------------------------------------------------------------

(define (write-config-file! config)
  "Write CONFIG atomically: a temporary file, then a rename.

The rename is what makes it atomic -- a reader either sees the old file or the
new one, never a half-written line."
  (let* ((path (config-file config))
         (tmp (string-append path ".tmp"))
         (pairs (map (lambda (opt)
                       ;; Read the accessor directly.  config-value takes the
                       ;; config's NAME, not the record, so passing the record
                       ;; fails the lookup and every value would be written as
                       ;; #f -- a config that saves itself empty.
                       (cons (car opt)
                             (catch #t
                               (lambda ()
                                 (st-peek (hashq-ref (config-accessors config)
                                                     (car opt))))
                               (lambda args #f))))
                     (config-options config))))
    (write-file tmp
                (with-output-to-string
                  (lambda ()
                    (display ";; scheme-toolkit config.  S-expressions: comments\n")
                    (display ";; allowed, values are typed, and this file is\n")
                    (display ";; rewritten when the shell changes an option.\n")
                    (write pairs)
                    (newline))))
    (catch #t
      (lambda () (rename-file tmp path))
      (lambda (key . rest)
        (log-error (cons key rest) (format #f "renaming ~a into place" tmp))
        ;; Fall back to a plain write rather than losing the change entirely.
        (write-file path (read-file tmp ""))))))

;; Applying one line of the file.  Pulled out of load-config-file! because the
;; nesting there was deep enough to lose count of, which is how a stray paren
;; becomes a hunt.
(define (apply-config-pair! config pair)
  (unless (pair? pair)
    (log-warning "a config entry is not a (name . value) pair" (config-file config))
    (throw 'skip))
  (let* ((name (car pair))
         (value (cdr pair))
         (validate (hashq-ref (config-validators config) name))
         (setter (hashq-ref (config-setters config) name)))
    (cond
     ((not setter)
      ;; An option the shell no longer has is worth saying, not worth failing
      ;; over: configs outlive the code that wrote them.
      (log-warning (format #f "unknown option ~a ignored" name) (config-file config)))
     ((and validate (not (validate value)))
      (log-error (format #f "~s is not a valid value for ~a" value name)
                 (config-file config)))
     (else
      (catch #t
        (lambda () (setter value))
        (lambda (key . rest)
          (log-error (cons key rest) (format #f "setting ~a" name))))))))

(define (load-config-file! config)
  "Read the file and apply what it validly says.

Per-option rather than all-or-nothing: one bad value should not discard the rest
of a user's config.  Each rejection is logged with the option's name."
  (let ((text (read-file (config-file config) #:fallback #f)))
    (if (not text)
        #f                          ; no file yet; the defaults stand
        (let ((parsed (attempt (lambda () (with-input-from-string text read)))))
          (if (not (result-ok? parsed))
              ;; Corrupt: keep it for the user to look at and carry on with
              ;; defaults.  A shell that will not start because of a typo in its
              ;; own config is one you cannot fix without a terminal.
              (begin
                (log-error (result-value parsed)
                           (format #f "~a is not readable; moving it aside"
                                   (config-file config)))
                (catch #t
                  (lambda ()
                    (rename-file (config-file config)
                                 (string-append (config-file config) ".bad")))
                  (lambda args #f))
                #f)
              (let ((data (result-value parsed)))
                (when (list? data)
                  (for-each (lambda (pair)
                              (catch 'skip
                                (lambda () (apply-config-pair! config pair))
                                (lambda args #f)))
                            data))
                #t))))))

;;; ---------------------------------------------------------------------------
;;; Saving, debounced
;;; ---------------------------------------------------------------------------

(define %save-delay-ms 400)

(define (schedule-save! config)
  "Mark CONFIG dirty and arrange a save shortly.

Debounced: dragging a slider would otherwise write the file once per frame.
Coalescing them means one write after the user stops."
  (set-config-dirty?! config #t)
  ;; let*, not let: the second binding reads the first, and `let' evaluates its
  ;; inits in the OUTER scope, so `name' would be unbound there.
  (let* ((name (config-name-of config))
         (existing (hashq-ref %save-handles name)))
    ;; Restart the timer if one is pending.
    (when existing
      (catch #t (lambda () (timer-cancel existing)) (lambda args #f)))
    (hashq-set! %save-handles name
                (timeout %save-delay-ms
                         (lambda ()
                           (hashq-remove! %save-handles name)
                           (catch #t
                             (lambda () (write-config-file! config))
                             (lambda (key . rest)
                               (log-error (cons key rest) "saving the config"))))))))

(define (config-name-of config)
  "The key this config was registered under, for the debounce table."
  (let loop ((pairs (hash-map->list (lambda (k v) (cons k v)) %configs)))
    (cond ((null? pairs) #f)
          ((eq? (cdr (car pairs)) config) (car (car pairs)))
          (else (loop (cdr pairs))))))

(define (config-save! name)
  "Write NAME's config now, cancelling any pending debounced save."
  (let ((config (config-for name)))
    (let ((pending (hashq-ref %save-handles name)))
      (when pending
        (catch #t (lambda () (timer-cancel pending)) (lambda args #f))
        (hashq-remove! %save-handles name)))
    (write-config-file! config)
    (set-config-dirty?! config #f)
    #t))

(define (config-reload! name)
  "Re-read NAME's config from its file, discarding unsaved changes."
  (let ((config (config-for name)))
    (load-config-file! config)
    (set-config-dirty?! config #f)
    #t))

;;; ---------------------------------------------------------------------------
;;; Live reload
;;; ---------------------------------------------------------------------------

(define %watches (make-hash-table))

(define (config-live? name)
  "Whether NAME is being watched for external edits."
  (hashq-ref %watches name #f))

(define (watch-config! name config)
  "Apply the file's contents whenever it changes on disk.

This is what makes `edit the config, see the bar change' work.  It is also why
saving writes atomically: the watcher sees the temporary file too, and a
half-written one would be read as corrupt -- and moved aside!"
  (unless (hashq-ref %watches name)
    (hashq-set! %watches name
                (monitor-file
                 (config-file config)
                 (lambda (kind path)
                   ;; The rename is what we care about; the temporary file's own
                   ;; events are noise.
                   (unless (string-suffix? ".tmp" path)
                     (catch #t
                       (lambda () (load-config-file! config))
                       (lambda (key . rest)
                         (log-error (cons key rest) "reloading the config")))))))))

;;; ---------------------------------------------------------------------------
;;; The macro
;;; ---------------------------------------------------------------------------

;; (name default validate) triples, from the option forms the user wrote.
(define (parse-options forms)
  (map (lambda (form)
         (unless (and (list? form) (= 3 (length form)))
           (error "define-config: an option is (NAME DEFAULT VALIDATE)" form))
         form)
       forms))

(define-syntax define-config
  (lambda (stx)
    "Syntax: (define-config NAME #:file FILE OPTION ...)

Declare a config.  Each OPTION is (OPTION-NAME DEFAULT VALIDATE), where VALIDATE
is a predicate; a value failing it is rejected and logged, and the old value
stands.

NAME may be written with angle brackets or without; the brackets are stripped,
and NAME is then what config-ref and config-set! are addressed by:

  (define-config <desktop-config>
    #:file config.scm
    (clock-format %H:%M string?))

  (config-ref 'desktop-config 'clock-format)   => an accessor"
    (syntax-case stx ()
      ((_ name option ...)
       (let* ((raw (syntax->datum #'name))
              (base (let ((str (symbol->string raw)))
                      (if (and (string-prefix? "<" str) (string-suffix? ">" str))
                          (substring str 1 (- (string-length str) 1))
                          str)))
              (all (syntax->datum #'(option ...)))
              (file (let ((hit (member #:file all)))
                      (if hit (cadr hit) "config.scm")))
              (opts (parse-options (let loop ((l all) (out '()))
                                     (cond ((null? l) (reverse! out))
                                           ((eq? (car l) #:file) (loop (cddr l) out))
                                           (else (loop (cdr l) (cons (car l) out))))))))
         ;; The options are built as an EXPRESSION, not as quoted data.
         ;;
         ;; Quoting the whole list is the obvious thing and it is wrong: the
         ;; validator in each triple then stays a symbol, so (validate value)
         ;; becomes an attempt to call the SYMBOL string? rather than the
         ;; predicate, and fails with "Wrong type to apply: string?".
         ;;
         ;; So each triple is emitted as (list 'name 'default validator), with
         ;; the validator left as something to evaluate.  Wrapping the whole
         ;; expression with datum->syntax gives every symbol in it, validators
         ;; included, the CALLER's context -- so an option written there resolves
         ;; there, which is also what makes (lambda (v) ...) work.
         (with-syntax ((ctor (datum->syntax #'name (string->symbol base)))
                       (key (datum->syntax #'name (list 'quote (string->symbol base))))
                       (opts* (datum->syntax
                               #'name
                               ;; cons, not (list 'list ...): the latter nests
                               ;; the triples into a ONE-element list, so
                               ;; %config-initialise! gets a single option whose
                               ;; triple it then tries to call.
                               (cons 'list
                                     (map (lambda (o)
                                            (list 'list
                                                  (list 'quote (car o))
                                                  (list 'quote (cadr o))
                                                  (caddr o)))
                                          opts))))
                       (file* (datum->syntax #'name file)))
           #'(begin
               (%config-initialise! key file* opts*)
               (define (ctor)
                 (or (hashq-ref %configs key)
                     (error "config is not initialised" 'key))))))))))

(define (%config-initialise! name file options)
  "Build NAME's config: the record, one accessor per option, the file path, and
the first load."
  (let* ((config (make-config-record options #f (make-hash-table)
                                     (make-hash-table) (make-hash-table) #f))
         (path (expand-path
                (if (or (string-prefix? "/" file) (string-prefix? "~" file))
                    file
                    (string-append (xdg-config-home) "/"
                                   (symbol->string name) "/" file)))))
    (register-config! name config)
    (set-config-file! config path)
    (for-each
     (lambda (opt)
       (let ((opt-name (car opt)) (default (cadr opt)) (validate (caddr opt)))
         (let-values (((acc set) (create-state default)))
           (hashq-set! (config-accessors config) opt-name acc)
           (hashq-set! (config-setters config) opt-name
                       (lambda (v)
                         (set v)
                         ;; Persist on every change, debounced: dragging a slider
                         ;; would otherwise write the file once per frame.
                         (schedule-save! config)))
           (hashq-set! (config-validators config) opt-name validate))))
     options)
    (load-config-file! config)
    ;; Watch the file, so editing it by hand changes the running shell.
    (catch #t (lambda () (watch-config! name config)) (lambda args #f))
    config))

;;; ---------------------------------------------------------------------------
;;; Access
;;; ---------------------------------------------------------------------------

(define (config-ref name option)
  "An ACCESSOR for OPTION of the config named NAME.

An accessor, not a value, so it goes straight into a widget property:

  (label #:label (config-ref 'desktop-config 'clock-format))"
  (let ((config (config-for name)))
    (or (hashq-ref (config-accessors config) option)
        (error "config-ref: no such option" option (format #f "in ~a" name)))))

(define (config-value name option)
  "OPTION's current value."
  (st-peek (config-ref name option)))

(define (config-set! name option value)
  "Set OPTION.  The value is validated; an invalid one is rejected and logged,
and the old value stands."
  (let* ((config (config-for name))
         (validate (hashq-ref (config-validators config) option))
         (setter (hashq-ref (config-setters config) option)))
    (cond
     ((not setter) (error "config-set!: no such option" option))
     ((and validate (not (validate value)))
      (log-error (format #f "~s is not a valid value for ~a" value option)
                 "config-set!")
      #f)
     (else (setter value) #t))))

(define (config-reset! name)
  "Put every option back to its default."
  (let ((config (config-for name)))
    (for-each (lambda (opt)
                (config-set! name (car opt) (cadr opt)))
              (config-options config))
    #t))
