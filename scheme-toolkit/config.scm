;;; (scheme-toolkit config) -- typed, validated, persisted, live-reloading options
;;;
;;; TWO ENGINES LIVE HERE, and the split is deliberate rather than an accident
;;; of growth.  Read the section headings: everything down to "Widget options"
;;; is the first, and everything after it is the second.
;;;
;;;   THE FLAT ENGINE    a shell declares a central schema -- `clock-format',
;;;                      `bar-position' -- and looks options up by string name.
;;;                      A shell with a handful of options and no widgets to
;;;                      hang them on wants exactly this.  It is the one with
;;;                      the full test suite (tests/config.scm).
;;;
;;;   THE WIDGET ENGINE  the widget IS the schema: a `#:config' slot on the
;;;                      class that reads it, with the value living in the slot
;;;                      and the metaclass notifying on a change.  This is what
;;;                      scheme-desktop uses, because its options belong to
;;;                      widgets and a central list put them somewhere the
;;;                      reader was not.
;;;
;;; They share the file format's conventions -- s-expressions, atomic
;;; debounced writes, corrupt-file recovery -- and neither delegates to the
;;; other.  A shell picks one.
;;;
;;; The flat engine, in its own words:
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
  ;; The widget-option half of this module reads widget classes and the widget
  ;; registry, and those live in `app'.  No cycle: `app' does not use this
  ;; module -- a shell wires the two together, it does not have `app' reach for
  ;; a config engine.
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit result)
  ;; QUALIFIED, and this is not cosmetic.
  ;;
  ;; Importing Gtk also brings Gio's `GFile.monitor_file' under the name
  ;; `monitor-file', and the generic then carries ONLY Gio's methods -- so a
  ;; plain (use-modules (scheme-toolkit file)) here would resolve monitor-file
  ;; to Gio's and every call would fail with "No applicable method for
  ;; #<<generic> monitor-file (2)>", naming an arity rather than the collision.
  ;;
  ;; This module happened to work because it lists (scheme-toolkit gi) FIRST,
  ;; so file's binding won the merge -- luck, not design: reversing the two
  ;; lines silently breaks live config reload.  A prefix makes the choice
  ;; explicit and order-independent.
  #:use-module ((scheme-toolkit file) #:prefix file:)
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
            config-live?
            ;; widget options -- the widget is the schema
            widget-config-setup! widget-config-file widget-config-start!
            widget-config-save! widget-config-save-pending? schedule-widget-save!
            load-widget-config!
            watch-widget-config! widget-config-live? widget-config-datum
            ;; For a change made to a config LIST rather than to one option at a
            ;; time -- enabling a plugin, whose widgets splice themselves in.
            apply-widget-config-datum!
            widget-config-set! widget-config-value widget-config-ref
            widget-config-reset!))

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
    (file:write-file tmp
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
        ;;
        ;; read-file takes its fallback as a KEYWORD.  A positional second
        ;; argument raises keyword-argument-error, and inside this catch that
        ;; meant the recovery itself failed silently -- a config that could not
        ;; be renamed into place lost the change, which is the one outcome this
        ;; whole branch exists to prevent.
        (file:write-file path (file:read-file tmp #:fallback ""))))))

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
  (let ((text (file:read-file (config-file config) #:fallback #f)))
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
                (file:monitor-file
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
         (path (file:expand-path
                (if (or (string-prefix? "/" file) (string-prefix? "~" file))
                    file
                    (string-append (file:xdg-config-home) "/"
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

;;; ---------------------------------------------------------------------------
;;; Widget options
;;; ---------------------------------------------------------------------------
;;
;; THE WIDGET IS THE SCHEMA.  Everything above needs a shell to write its options
;; out in a list -- `(define-config <desktop> (clock-format "%H:%M" string?))` --
;; and a widget to look them up again by string name.  That is two places for
;; one fact: the option is declared away from the code that reads it, and
;; `(config-value 'desktop 'clock-format)' names a widget's own option as though
;; it belonged to the shell.
;;
;; Here the widget declares its options as `#:config' slots (see
;; `(scheme-toolkit app)') and this reads and writes those slots.  Nothing in
;; between: the SLOT is the value, and a write to it already notifies, because
;; the metaclass wraps config slots to tick a change signal.
;;
;; ONE FILE, ONE ENTRY PER WIDGET:
;;
;;   ((bar     (position top) (height 30))
;;    (clock   (format "%H:%M"))
;;    (network-panel (position center)))
;;
;; which is what both reference shells do (ags2-shell `options.ts' and
;; colorshell's dotted paths) and what a person can read.

(define %widget-config #f)

(define (widget-config-setup! widgets path)
  "Register the shell's widget options: WIDGETS, persisted in PATH.

WIDGETS is a thunk, not a list, because a shell builds its widgets lazily -- the
bar does not exist until the first `build-bar!' -- and a list captured now would
be missing it."
  (set! %widget-config (list widgets path #f #f))
  #t)

(define (widget-config-file)
  (and %widget-config (cadr %widget-config)))

(define (widget-config-widgets)
  (if %widget-config ((car %widget-config)) '()))

;;; --- reading and writing the file ------------------------------------------

(define (widget-option-name spec) (assoc-ref spec 'name))
(define (widget-option-type spec) (assoc-ref spec 'type))

(define (widget-config-datum)
  "Every widget's options, as the s-expression the file holds."
  (filter-map
   (lambda (w)
     (let ((opts (filter-map (lambda (spec)
                               (let ((name (widget-option-name spec)))
                                 (and name (list name (slot-ref w name)))))
                             (widget-config-slots w))))
       ;; KEYED BY THE WIDGET'S QUALIFIED NAME -- `(module ... <class>)', or
       ;; `root' for the root -- which is the name the root's list and the bar's
       ;; layout use, so one widget has one name in the whole file.
       (and (pair? opts)
            (cons (widget-name w) opts))))
   (widget-config-widgets)))

(define (write-widget-config!)
  "Write the file atomically: a temporary file, then a rename.

The rename is what makes it atomic, and it is also what keeps the live-reload
watcher sane: it sees the temporary file too, and a half-written one would be
read as corrupt and moved aside."
  (let ((path (widget-config-file)))
    (and path
         (let ((tmp (string-append path ".tmp")))
           (file:write-file
            tmp
            (with-output-to-string
              (lambda ()
                (display ";; scheme-desktop config.  S-expressions: comments\n")
                (display ";; allowed, values are typed, and this file is rewritten\n")
                (display ";; when the shell changes an option.\n")
                (display ";;\n")
                (display ";; One entry per widget, holding that widget's options:\n")
                (display ";;   ((bar (position top) (height 30)) (clock (format \"%H:%M\")))\n")
                (write (widget-config-datum))
                (newline))))
           (catch #t
             (lambda () (rename-file tmp path) #t)
             (lambda (key . rest)
               (log-error (cons key rest) (format #f "renaming ~a into place" tmp))
               ;; A plain write rather than losing the change entirely.
               (file:write-file path (file:read-file tmp #:fallback ""))))))))

(define (apply-widget-option! w spec value)
  "Set one of W's options from the file, reporting a bad value against the file.

THE CHECK IS NOT HERE ANY MORE.  It is in the SLOT -- `compute-get-n-set' in
(scheme-toolkit app) -- where every write passes, so a value that is refused is
refused however it arrived.  What is left here is the part that is specific to
reading a FILE: the error is reported against the path it came from, and it does
not escape, because a config is many options and one bad value is not the end of
it.

A descriptor this build does not understand is no longer a case here at all.
The descriptors come from the CLASS, not from the file, so one that cannot be
read fails when the class is DEFINED -- where it is fixable -- rather than being
noticed against one value out of a file."
  (let ((name (widget-option-name spec)))
    ;; `slot-set!' rather than the accessor's setter: they are the same closure,
    ;; and this one does not need the accessor to exist.
    (catch #t
      (lambda () (slot-set! w name value) #t)
      (lambda (key . rest)
        ;; The slot's own message names the value, the descriptor and the slot;
        ;; `describe-error' pulls it out of the (KEY . ARGS) shape `error' throws.
        (log-error (cons key rest)
                   (format #f "~a.~a, read from ~a"
                           (widget-label w) name (widget-config-file)))
        #f))))

(define (load-widget-config!)
  "Read the file and apply what it validly says."
  (let* ((path (widget-config-file))
         (text (and path (file:read-file path #:fallback #f))))
    (if (not text)
        #f                          ; no file yet; the declared defaults stand
        (let ((parsed (attempt (lambda () (with-input-from-string text read)))))
          (if (not (result-ok? parsed))
              (begin
                (log-error (result-value parsed)
                           (format #f "~a is not readable; moving it aside" path))
                (catch #t (lambda () (rename-file path (string-append path ".bad"))
                                      (load-widget-config!))
                       (lambda args #f)))
              (apply-widget-config-datum! (result-value parsed)))))))

;;; --- saving ----------------------------------------------------------------

(define %widget-save-delay-ms 400)

(define (widget-config-save!)
  "Write the file now, cancelling any pending debounced save."
  (and %widget-config
       (let ((pending (cadddr %widget-config)))
         (when pending
           (catch #t (lambda () (timer-cancel pending)) (lambda args #f))
           (set-car! (cdddr %widget-config) #f)))
       (write-widget-config!)))

(define (widget-config-save-pending?)
  "Whether a debounced save is waiting to be written.

THE REBUILD NEEDS TO KNOW, because a rebuild RE-READS THE FILE.  A change made
from code -- a settings widget, a keybinding, a poke from the REPL -- is written
only after a debounce, while the rebuild it triggers is deferred by an idle,
which runs FIRST.  So the rebuild read a file that did not yet contain the change
it was rebuilding for, and put the old value back; the pending save then wrote
that old value out, and the change was gone with no error anywhere.

Measured on the root's widget list: narrowing it worked (the file already said
so), and widening it did nothing at all."
  (and %widget-config (cadddr %widget-config) #t))

(define (schedule-widget-save!)
  "Write the file shortly, however many changes arrive in the meantime.

Debounced for the same reason the flat engine debounces: dragging a slider must
not write the file once per frame."
  (and %widget-config
       (let ((pending (cadddr %widget-config)))
         (when pending (catch #t (lambda () (timer-cancel pending)) (lambda args #f)))
         (set-car! (cdddr %widget-config)
                   (timeout %widget-save-delay-ms
                            (lambda ()
                              (set-car! (cdddr %widget-config) #f)
                              (catch #t write-widget-config!
                                     (lambda (key . rest)
                                       (log-error (cons key rest)
                                                  "saving the widget config")))))))))

;;; --- live reload -----------------------------------------------------------

(define (widget-config-live?)
  "Whether the widget config file is being watched."
  (and %widget-config (caddr %widget-config) #t))

(define (watch-widget-config!)
  "Apply the file's contents whenever it changes on disk.

This is what makes `edit the config, see the bar change' work -- and it is why
the save is atomic, because the watcher sees the temporary file too."
  (and %widget-config
       (let ((path (widget-config-file))
             (already (caddr %widget-config)))
         (unless already
           (set-car! (cddr %widget-config)
                     (file:monitor-file
                      path
                      (lambda (kind fpath)
                        (unless (string-suffix? ".tmp" fpath)
                          (catch #t load-widget-config!
                                 (lambda (key . rest)
                                   (log-error (cons key rest)
                                              "reloading the widget config")))))))))))

(define (widget-config-observe-ticks!)
  "Save whenever a config slot changes, HOWEVER it changed.

Without this the only writes that persist are the ones that come through
`widget-config-set!' -- a raw `slot-set!' on a config slot would change the value
in memory and never reach the file, which is the sort of thing that shows up much
later as a setting that will not stick.

The metaclass already ticks on every real change, so this is the other end of a
wire that was only connected at one end.

CALLED AFTER THE WIDGETS EXIST, and only once.  A widget registered after this
runs is not observed -- which would be a bug if a shell built widgets in response
to something.  Nothing does today: everything is registered at load, and the bar
is created by the shell's `main' before this is called."
  ;; INSIDE A ROOT, and this is not tidiness.  `widget-config-start!' is called
  ;; from the shell's `main', which runs inside GApplication's `activate' -- a
  ;; signal emitted by C, where no scope is current.  Creating a state there
  ;; warns three times and leaves the signal with no owner, which is exactly
  ;; what a standing root is for.
  (create-root
   (lambda (dispose)
     (for-each
      (lambda (w)
        (for-each (lambda (spec)
                    (subscribe (car (widget-config-tick w (widget-option-name spec)))
                               (lambda () (schedule-widget-save!))))
                  (widget-config-slots w)))
      (widget-config-widgets)))))

(define* (widget-config-start! #:key (watch? #t))
  "Load the file, persist anything that changes, and optionally watch it.

What a shell calls once at startup, after its widgets are registered.

`#:watch? #f' is for a shell with its OWN watcher -- `(scheme-toolkit reload)',
which rebuilds the shell when the file changes rather than only re-applying the
values.  Two watchers on one file is not a correctness problem, because
`monitor-file' shares a single GFileMonitor and calls both callbacks -- but it
means every save does a value-pass AND a rebuild, and the value-pass is then
work nobody needed."
  (load-widget-config!)
  ;; AFTER THE LOAD, so that reading the file does not look like an edit worth
  ;; saving.  It would not loop -- the metaclass ticks only on a real change, so
  ;; a reload of identical values saves nothing -- but observing first would do
  ;; a pointless write on every start.
  (widget-config-observe-ticks!)
  (when watch? (watch-widget-config!))
  #t)

;;; --- writing, and the three things a config must do ------------------------

(define (widget-config-slot-spec w option)
  "The declaration of OPTION on W, or #f."
  (find (lambda (s) (eq? (widget-option-name s) option)) (widget-config-slots w)))

(define (widget-config-set! namespace option value)
  "Set one option BY NAME, and let it persist.

This is now only the NAME half of the job.  The value is checked and the save is
arranged by the SLOT itself -- `compute-get-n-set' validates, and a real change
ticks, which the observer turns into a save -- so `slot-set!' on the widget is
all you need and this exists for callers that have a name rather than the object:
the settings widget, a keybinding, `bin/scheme-desktop eval'.

Answers #f, having logged, when there is no such widget, no such option, or the
value is not one the option accepts."
  (let ((w (desktop-widget-named namespace)))
    (cond
     ((not w) (error "widget-config-set!: no widget called" namespace) #f)
     (else
      (let ((spec (widget-config-slot-spec w option)))
        (cond
         ((not spec) (error "widget-config-set!: that widget has no option" option) #f)
         ((not (apply-widget-option! w spec value)) #f)
         ;; NO SAVE HERE.  `apply-widget-option!' writes the slot, which ticks,
         ;; which the observer turns into a save -- so scheduling one here as
         ;; well would be the same write twice.  One path, not two.
         (else #t)))))))

(define (widget-config-value namespace option)
  "The current value of one option."
  (let ((w (desktop-widget-named namespace)))
    (and w (slot-ref w option))))

(define (widget-config-ref namespace option)
  "A reactive ACCESSOR for one option, for binding to a widget property.

Resolved from the registry each call, so there is nothing to register and
nothing to keep in step: the widget registry IS the registration."
  (let ((w (desktop-widget-named namespace)))
    (and w (widget-slot-ref w option))))

(define (widget-config-reset! namespace)
  "Put every one of a widget's options back to its declared default.

The default is the slot's `#:init-value', which is why declaring an option in
the class is the whole of declaring it."
  (let ((w (desktop-widget-named namespace)))
    (and w
         (begin
           (for-each (lambda (spec)
                       (let ((name (widget-option-name spec))
                             (default (assoc-ref spec 'default)))
                         (catch #t (lambda () (slot-set! w name default)) (lambda args #f))))
                     (widget-config-slots w))
           (schedule-widget-save!)
           #t))))

;;; --- the flat format, and how it is read -----------------------------------
;;
(define (apply-widget-config-entry! entry)
  "One top-level entry of the config file: a widget's name and its options."
  (let ((name (and (pair? entry) (car entry))))
    (cond
     ;; A NAME IS A QUALIFIED NAME -- a list -- or `root'.
     ((not (or (symbol? name) (pair? name)))
      (log-warning "a config entry does not start with a name" (widget-config-file)))
     ;; THE NEW FORMAT: the name is a widget.
     ((desktop-widget-named name)
      (let ((w (desktop-widget-named name))
            (specs (widget-config-slots (desktop-widget-named name))))
        (unless (list? (cdr entry))
          (log-warning (format #f "~a is not a list of options" name)
                       (widget-config-file)))
        (for-each
         (lambda (pair)
           (let* ((oname (car pair))
                  (spec (find (lambda (s) (eq? (widget-option-name s) oname)) specs)))
             (if spec
                 (apply-widget-option! w spec (cadr pair))
                 (log-warning (format #f "~a has no option ~a; ignored" name oname)
                              (widget-config-file)))))
         (if (list? (cdr entry)) (cdr entry) '()))))
     (else
      (log-warning (format #f "no widget called ~a; its options are ignored" name)
                   (widget-config-file))))))

(define (apply-widget-config-datum! datum)
  "Apply a parsed file, entry by entry."
  (for-each apply-widget-config-entry! (if (list? datum) datum '())))
