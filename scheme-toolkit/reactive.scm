;;; (scheme-toolkit reactive) -- accessors, state, computed, effects, scopes
;;;
;;; A port of Gnim's jsx/state.ts and jsx/scope.ts semantics, which is what the
;;; reference shells are written against.  The behaviour worth stating up front,
;;; because it is what everything else depends on:
;;;
;;;   - An ACCESSOR is callable.  (acc) reads its value *and records a
;;;     dependency* when a computation is tracking it; (st-peek acc) reads without
;;;     recording.
;;;
;;;   - Accessors are COLD.  A derived accessor subscribes to its sources only
;;;     while it itself has a subscriber, and lets go when the last one leaves.
;;;     This is what makes binding hundreds of Astal properties free until a
;;;     widget actually shows them.
;;;
;;;   - Dependency tracking is IMPLICIT.  (create-computed thunk) runs THUNK
;;;     with a fresh dependency set installed; every (acc) read inside adds
;;;     itself.  There are no dependency lists to keep in sync by hand.
;;;
;;;   - Reading and writing are DIFFERENT operations: create-state returns an
;;;     accessor and a setter.  Do not pun them onto one procedure -- Gnim
;;;     reserves the one-argument call for "derive a computed from this
;;;     accessor" (as in a clock's (time (lambda (t) ...))), which the shells
;;;     use constantly, and a read/write pun would hide mutation.
;;;
;;; Why <st-accessor> is a distinct type and not a plain lambda: the element
;;; runtime must tell "this prop is a reactive value to bind" from "this prop is
;;; an event handler to connect".  Both are procedures.  Making <st-accessor> an
;;; applicable GOOPS struct gives (acc) *and* a real predicate.
;;;
;;; The two pieces of dynamic state -- the dependency set being collected, and
;;; the current scope -- are Guile PARAMETERS rather than module variables.
;;; That matters beyond style: parameters are thread-local, so an evaluation on
;;; the main thread cannot see a tracking set left over by another thread, and
;;; the cooperative REPL (M0.5) always evaluates on the main thread precisely so
;;; that it sees the shell's own bindings of them.

(define-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit gi)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)

  #:export (accessor? accessor-name <st-accessor>
            make-subs subs-add! subs-remove! subs-count subs-notify!
            create-binding
            create-binding-path
            create-accessor
            st-peek subscribe as
            create-state create-computed create-memo
            create-effect create-connection
            create-root dispose-root
            on-cleanup on-mount
            get-scope with-scope current-scope
            st-create-context))

;;; ---------------------------------------------------------------------------
;;; Dynamic state
;;; ---------------------------------------------------------------------------

;; The dependency set the running computation is collecting, or #f outside one.
(define %tracking (make-parameter #f))

;; The scope that new effects, bindings and cleanups belong to.
(define %scope (make-parameter #f))

;; THE SAME PARAMETER, UNDER A NAME ANOTHER MODULE CAN HOLD.
;;
;; `with-scope' is the way to enter a scope and it is right for callers in the
;; SAME module or in interpreted code.  A compiled module that calls it can get
;; a WRONG ANSWER, and it cost an afternoon to find: Guile 3.0.11 inlines a
;; one-line procedure like `with-scope' into its caller, and the inlined copy's
;; reference to the module-private `%scope' resolved to the neighbouring
;; procedure `get-scope' instead -- so `parameterize' was handed a procedure and
;; died with
;;
;;   Not a parameter: #<procedure get-scope ()>
;;
;; from `(make <some-widget>)', which looks like a bug in the widget machinery
;; and is not.  Making `with-scope' BIGGER made it stop, which is the giveaway:
;; it is the inliner, not the code.
;;
;; So a module that has to enter a scope from compiled code parameterizes THIS
;; binding -- an ordinary imported variable, with nothing to inline:
;;
;;   (parameterize ((current-scope scope)) (thunk))
(define current-scope %scope)

;; Mount callbacks collected by the root currently being built.  Gnim bubbles
;; onMount to the nearest *unmounted* ancestor so that every mount runs once the
;; whole tree exists, rather than mid-construction with half a widget tree in
;; place.  Collecting them per root reproduces that.
(define %mounts (make-parameter #f))

(define (warn fmt . args)
  (apply format (current-error-port)
         (string-append "scheme-toolkit: " fmt "\n") args))

;;; ---------------------------------------------------------------------------
;;; The accessor type
;;; ---------------------------------------------------------------------------

;; The slot holding the callable MUST be named `procedure': that is the slot an
;; <applicable-struct> applies.  Any other name yields an object that satisfies
;; accessor? but raises "Wrong type to apply" when called.
;;
;; Built with `class' rather than `define-class': define-class treats a trailing
;; keyword as a malformed slot and the file fails to compile, whereas `class'
;; takes the options explicitly.  Within `class', the keyword options come AFTER
;; the slot definitions -- the parser stops reading slots at the first keyword.
;;
;; #:metaclass is required.  Without it GOOPS picks
;; <applicable-struct-with-setter-class> for an <applicable-struct> subclass,
;; which makes the class a *generic function*: instances then carry
;; methods/setter slots and are not callable at all ("No applicable method").
(define <st-accessor>
  (class (<applicable-struct>)
    (procedure #:init-keyword #:procedure)
    (peek-fn   #:init-keyword #:peek)
    (sub-fn    #:init-keyword #:subscribe #:init-value #f)
    (version-fn #:init-keyword #:version-fn #:init-value (lambda () 0))
    (name      #:init-keyword #:name #:init-value 'accessor)
    #:metaclass <applicable-struct-class>
    #:name '<st-accessor>))

(define (accessor? x) (is-a? x <st-accessor>))
(define (accessor-name acc) (slot-ref acc 'name))

;; Every accessor has a version that ticks when its value changes.  create-state
;; and create-connection tick it in their setters; create-computed ticks it in
;; recompute!.  A cold computed uses it to notice that a source moved without
;; having to hold a subscription to be told.
(define (%version acc)
  ((slot-ref acc 'version-fn)))

(define (note-dependency! acc)
  (let ((t (%tracking)))
    (when t (hashq-set! t acc #t))))

(define* (create-accessor peek-fn name #:key (subscribe-fn #f) (version-fn #f))
  "Build an accessor over PEEK-FN.  The one-argument call derives a computed,
matching Gnim's (time (lambda (t) ...)) idiom."
  (define acc #f)
  (set! acc (make <st-accessor>
              #:procedure (lambda args
                            (case (length args)
                              ((0) (note-dependency! acc) (peek-fn))
                              ;; (acc f) derives a computed of (f value).  F is
                              ;; applied to the VALUE: calling ((acc) f) reads
                              ;; through the accessor, which is what records the
                              ;; dependency on it.
                              ((1) (create-computed
                                    (lambda () ((car args) (acc)))
                                    (list 'derived name)))
                              (else (error "accessor called with wrong number of arguments"
                                           name args))))
              #:peek peek-fn
              #:subscribe subscribe-fn
              #:version-fn (or version-fn (lambda () 0))
              #:name name))
  acc)

(define (st-peek acc)
  "Read ACC's value without recording a dependency.  This is the read to use
inside a procedure that must not be re-run when ACC changes."
  (unless (accessor? acc) (error "st-peek: not an accessor" acc))
  ((slot-ref acc 'peek-fn)))

(define (subscribe acc thunk)
  "Call THUNK whenever ACC changes; return a procedure that unsubscribes.

Deliberately NOT scope-aware: the caller decides the lifetime, which is what
lets create-binding hand the disconnect to on-cleanup itself."
  (unless (accessor? acc) (error "subscribe: not an accessor" acc))
  (let ((f (slot-ref acc 'sub-fn)))
    (unless f (error "subscribe: accessor is not subscribable" (accessor-name acc)))
    (f thunk)))

(define (as acc f)
  "An accessor of (F (acc))."
  (create-computed (lambda () (f (acc))) (list 'as (accessor-name acc))))

;;; ---------------------------------------------------------------------------
;;; Subscriber bookkeeping
;;; ---------------------------------------------------------------------------

;; The same thunk subscribing twice is still one subscription, so the count that
;; drives the cold behaviour is a set's size, not a list length.
(define (make-subs) (make-hash-table))
(define (subs-add! subs thunk) (hashq-set! subs thunk #t))
(define (subs-remove! subs thunk) (hashq-remove! subs thunk))
(define (subs-count subs) (hash-count (const #t) subs))
(define (subs->list subs) (hash-map->list (lambda (k v) k) subs))
(define (subs-notify! subs)
  (for-each (lambda (thunk) (thunk)) (subs->list subs)))

;;; ---------------------------------------------------------------------------
;;; create-state
;;; ---------------------------------------------------------------------------

(define* (create-state initial #:key (equals equal?))
  "Returns two values: an accessor for the value, and a setter.

    (define-values (count set-count!) (create-state 0))
    (count)            ; => 0
    (set-count! 1)     ; a value
    (set-count! 1+)    ; or an updater procedure

The setter notifies only when the value actually changed."
  (let ((value initial)
        (version 0)
        (subs (make-subs)))
    (let ((acc (create-accessor (lambda () value) 'state
                              #:version-fn (lambda () version)
                              #:subscribe-fn
                              (lambda (thunk)
                                (subs-add! subs thunk)
                                (lambda () (subs-remove! subs thunk))))))
      (define (setter new)
        (let ((new (if (procedure? new) (new value) new)))
          (unless (equals value new)
            (set! value new)
            (set! version (1+ version))
            (subs-notify! subs))))
      (values acc setter))))

;;; ---------------------------------------------------------------------------
;;; create-computed
;;; ---------------------------------------------------------------------------

(define* (create-computed thunk #:optional (name 'computed))
  "An accessor of (THUNK), recomputed when anything read inside it changes.

Dependencies are found by running THUNK under a fresh tracking set, so there is
no dependency list to keep in sync by hand.

COLD BEHAVIOUR, the part that is easy to get wrong.  A computed with no
subscriber cannot be *told* that a source changed, because holding the
subscription that would tell it is exactly what being cold avoids.  So a cold
read must not trust a cache: it has to ask whether any source has moved since
its last run.  Every accessor therefore carries a version that ticks when its
value changes, and a cold computed re-runs when any source's version differs
from the one it recorded.

The alternative -- trusting the cache while cold -- makes (double) read 2
forever after its source becomes 3."
  (let ((value #f)
        (dirty? #t)
        (version 0)            ; ticks when VALUE changes; see %version
        (deps '())             ; (source . unsubscribe), while warm
        (seen-versions '())    ; (source . version) as of the last run
        (warm? #f)
        (running? #f)
        (subs (make-subs)))

    (define (drop-source-subs!)
      (for-each (lambda (pair) ((cdr pair))) deps)
      (set! deps '()))

    (define (take-source-subs!)
      (set! deps (map (lambda (source)
                        (cons source (subscribe source dep-changed!)))
                      (map car seen-versions))))

    (define (sources-moved?)
      ;; Ask the sources whether they have moved, which is what makes this work
      ;; while cold.
      ;;
      ;; (%version source) is not enough on its own: a nested computed that is
      ;; ALSO cold has not recomputed, so its version is still the old one and
      ;; the chain looks unchanged.  Reading it first forces it to update (its
      ;; own read checks its sources), and its version ticks if its value really
      ;; did change.  That read is what makes a cold chain propagate.
      (any (lambda (source)
             (let ((prev (assq source seen-versions)))
               (or (not prev)
                   (begin
                     (source)  ; force a cold source to refresh itself
                     (not (= (cdr prev) (%version source)))))))
           (map car seen-versions)))

    (define (recompute!)
      (when running?
        (error "create-computed: a computation read its own value" name))
      (let ((old value) (first? dirty?))
        (set! running? #t)
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (let ((fresh (make-hash-table)))
              (set! value (parameterize ((%tracking fresh)) (thunk)))
              (set! seen-versions
                    (map (lambda (source) (cons source (%version source)))
                         (subs->list fresh)))))
          (lambda () (set! running? #f)))
        (set! dirty? #f)
        (unless (and (not first?) (equal? old value))
          (set! version (1+ version))))
      ;; Re-subscribe from the dependency set just recorded, so a computation
      ;; whose branches changed lets go of what it stopped reading.
      (drop-source-subs!)
      (when warm? (take-source-subs!)))

    (define (dep-changed!)
      ;; A source moved.  The value is recomputed on the next read rather than
      ;; here, so a chain of computeds does not fan out into work nobody asked
      ;; for -- but subscribers must hear now.
      (set! dirty? #t)
      (subs-notify! subs))

    (define (read)
      (when (or dirty? (and (not warm?) (sources-moved?)))
        (recompute!))
      value)

    (create-accessor read name
                   #:version-fn (lambda () version)
                   #:subscribe-fn
                   (lambda (thunk)
                     (subs-add! subs thunk)
                     (when (and (= 1 (subs-count subs)) (not warm?))
                       ;; Cold -> warm.  Bring the value up to date before
                       ;; subscribing, so a source that moved while we were cold
                       ;; is not missed.
                       (set! warm? #t)
                       (recompute!))
                     (lambda ()
                       (subs-remove! subs thunk)
                       (when (and (zero? (subs-count subs)) warm?)
                         (set! warm? #f)
                         (drop-source-subs!)))))))

;;; ---------------------------------------------------------------------------
;;; create-memo
;;; ---------------------------------------------------------------------------

(define* (create-memo thunk #:key (equals equal?) (name 'memo))
  "Like create-computed, but notifies only when the value actually changed.

`With' is built on this, so that replacing a widget with an equal value does not
tear the child down and rebuild it."
  (let* ((inner (create-computed thunk name))
         (last #f)
         (started? #f)
         (subs (make-subs))
         (dispose-inner #f))

    (define (changed!)
      (let ((v (st-peek inner)))
        (unless (and started? (equals last v))
          (set! last v)
          (set! started? #t)
          (subs-notify! subs))))

    (define (sync-baseline!)
      ;; The value has to be recorded before the first notification is judged,
      ;; or the first change notifies twice: once for the real change and once
      ;; because there was no baseline to compare against.
      (unless started?
        (set! last (st-peek inner))
        (set! started? #t)))

    (create-accessor
     (lambda ()
       (sync-baseline!)
       (st-peek inner))
     name
     #:subscribe-fn
     (lambda (thunk)
       (sync-baseline!)
       (subs-add! subs thunk)
       (unless dispose-inner
         (set! dispose-inner (subscribe inner changed!)))
       (lambda ()
         (subs-remove! subs thunk)
         (when (zero? (subs-count subs))
           (when dispose-inner (dispose-inner))
           (set! dispose-inner #f)))))))

;;; ---------------------------------------------------------------------------
;;; Scopes
;;; ---------------------------------------------------------------------------

(define-class <scope> ()
  (parent    #:init-keyword #:parent #:init-value #f)
  (cleanups  #:init-form '())
  (contexts  #:init-form '())
  (disposed? #:init-form #f))

(define (get-scope) (%scope))

(define (scope-disposed? scope) (slot-ref scope 'disposed?))

(define (scope-add-cleanup! scope thunk)
  (slot-set! scope 'cleanups (cons thunk (slot-ref scope 'cleanups))))

(define (run-cleanups! scope)
  ;; Reverse order, like a dynamic-wind unwinding: a binding is disconnected
  ;; before the scope that owns it is forgotten.
  (for-each (lambda (thunk)
              (catch #t thunk
                     (lambda (key . args)
                       (warn "cleanup raised ~a: ~a" key args))))
            (slot-ref scope 'cleanups))
  (slot-set! scope 'cleanups '()))

(define (on-cleanup thunk)
  "Register THUNK to run when the current scope is disposed.

This is how a binding's notify handler is disconnected, and how a widget added
to a container is removed: disposing a widget tree must leave no GObject signal
handlers behind."
  (let ((scope (%scope)))
    (if scope
        (scope-add-cleanup! scope thunk)
        ;; Warn rather than leak silently.  Gnim warns here too.
        (warn "on-cleanup called outside a scope; it will never run"))
    thunk))

(define (on-mount thunk)
  "Run THUNK once the enclosing root has finished building its tree."
  (let ((mounts (%mounts)))
    (if mounts
        (set-car! mounts (cons thunk (car mounts)))
        (thunk))))

(define* (create-root proc #:key (name 'root))
  "Build a reactive root; PROC is called with a dispose procedure.

Everything created inside PROC belongs to the root, and dispose runs every
cleanup registered in it.  A root is needed because widgets get built from
signal handlers long after the initial tree; those need a scope handed to them
rather than an ambient one."
  (let* ((scope (make <scope> #:parent #f))
         (mounts (list '()))
         (disposed? #f)
         (dispose
          (lambda ()
            (unless disposed?
              (set! disposed? #t)
              (slot-set! scope 'disposed? #t)
              (run-cleanups! scope)))))
    (parameterize ((%scope scope) (%mounts mounts))
      (proc dispose))
    ;; The tree exists now, so the mounts can run against it.
    (for-each (lambda (thunk)
                (catch #t thunk
                       (lambda (key . args)
                         (warn "mount raised ~a: ~a" key args))))
              (reverse (car mounts)))
    dispose))

(define (dispose-root dispose)
  "Run a root's cleanups.  Spelled out because the call site reads better than
a raw thunk."
  (dispose))

(define (%enter-scope scope thunk)
  ;; THE ACTUAL ENTRY, IN A PROCEDURE THE INLINER LEAVES ALONE.  Guile 3.0.11
  ;; inlines a one-line procedure, and an inlined copy of this one, used from
  ;; ANOTHER COMPILED MODULE, resolved its reference to the module-private
  ;; `%scope' to the neighbouring `get-scope' procedure -- "Not a parameter:
  ;; #<procedure get-scope ()>", raised from wherever the caller happened to be.
  ;; Two statements is enough to stop the inliner: the comment above says that
  ;; making `with-scope' bigger made it stop, and that is the giveaway that it is
  ;; the inliner and not the code.
  ;;
  ;; Every caller used to have to know this.  None of them does now.
  (parameterize ((%scope scope)) (thunk)))

(define (with-scope scope thunk)
  "Run THUNK with SCOPE current, so anything it creates is owned by SCOPE."
  (let ((s scope) (t thunk))
    (%enter-scope s t)))

;;; ---------------------------------------------------------------------------
;;; Contexts
;;; ---------------------------------------------------------------------------

(define* (st-create-context default #:optional (name 'context))
  "Returns two procedures: (provide value) and (use-context).

A context lets a subtree pass a value down without threading it through every
element's keyword arguments."
  (let ((key (gensym "context")))
    (define (provide value)
      (let ((scope (%scope)))
        (unless scope
          (error "context provide: no current scope" name))
        (slot-set! scope 'contexts
                   (cons (cons key value) (slot-ref scope 'contexts)))
        value))
    (define (use-context)
      (let loop ((scope (%scope)))
        (cond ((not scope) default)
              ((assq key (slot-ref scope 'contexts)) => cdr)
              (else (loop (slot-ref scope 'parent))))))
    (values provide use-context)))

;;; ---------------------------------------------------------------------------
;;; create-effect
;;; ---------------------------------------------------------------------------

(define* (create-effect thunk #:key (immediate #f) (name 'effect))
  "Run THUNK, and re-run it whenever anything it read changes.

THUNK runs on MOUNT by default -- after the enclosing root has built its tree --
so an effect never sees a half-built widget tree.  #:immediate #t runs it now.

Each run gets a fresh child scope, so cleanups registered by one run are
disposed before the next.  That is what stops an effect which creates widgets
from leaking them across re-runs."
  (let ((dispose-run #f)
        (deps '())
        (stopped? #f)
        (subs (make-subs)))

    (define (drop-deps!)
      (for-each (lambda (pair) ((cdr pair))) deps)
      (set! deps '()))

    (define (run)
      (unless stopped?
        (when dispose-run (dispose-run))
        (let ((scope (make <scope> #:parent (%scope))))
          (set! dispose-run (lambda () (run-cleanups! scope)))
          (let ((fresh (make-hash-table)))
            (parameterize ((%scope scope) (%tracking fresh))
              (thunk))
            (drop-deps!)
            (set! deps (map (lambda (source) (cons source (subscribe source run)))
                            (subs->list fresh)))))))

    (if immediate (run) (on-mount run))

    (lambda ()
      (unless stopped?
        (set! stopped? #t)
        (drop-deps!)
        (when dispose-run (dispose-run))))))

;;; ---------------------------------------------------------------------------
;;; create-binding -- reactive reads of GObject properties
;;; ---------------------------------------------------------------------------

(define (binding-getter-value obj prop)
  "Read PROP from OBJ, or #f if it cannot be read.

#f rather than an error, because create-binding-path walks chains that legitimately
break in the middle -- a machine with no wireless card has no `wifi' device to
read an `ssid' from."
  (let* ((prop (if (string? prop) prop (symbol->string prop)))
         (sym (string->symbol prop)))
    (cond
     ((catch #t (lambda () (slot-exists? obj sym) #t) (lambda args #f))
      (catch #t (lambda () (slot-ref obj sym)) (lambda args #f)))
     (else
      ;; Not every property has a generated accessor slot; get-<prop> is the
      ;; fallback.
      (let ((getter (string->symbol (string-append "get-" prop))))
        (catch #t
          (lambda ()
            (when (module-bound? (current-module) getter)
              ((module-ref (current-module) getter) obj)))
          (lambda args #f)))))))

(define (binding-getter obj prop)
  "A thunk reading PROP from OBJ, or an error if the property does not exist.

This is create-binding's version, which is strict: a single-property binding
that cannot read its property is a bug worth raising.  (create-binding-path is
the lenient one, because its chains are allowed to break.)"
  (let ((sym (string->symbol (if (string? prop) prop (symbol->string prop)))))
    (or (and (catch #t (lambda () (slot-exists? obj sym) #t) (lambda args #f))
             (lambda () (slot-ref obj sym)))
        (let ((getter (string->symbol (string-append "get-" prop))))
          (and (module-bound? (current-module) getter)
               (lambda () ((module-ref (current-module) getter) obj))))
        (error "create-binding: cannot read property" prop "from" obj))))

(define* (create-binding obj prop #:optional (name 'binding))
  "An accessor tracking PROP on the GObject OBJ.

Re-reads on notify::PROP.  The handler is disconnected by on-cleanup, so
disposing the enclosing scope leaves no handler keeping OBJ alive -- which is
the difference between a bar that can be rebuilt on monitor hotplug and one that
leaks a widget tree per replug."
  (unless (string? prop) (set! prop (symbol->string prop)))
  (let* ((get (binding-getter obj prop))
         (subs (make-subs))
         (handler-id #f))

    (define (drop-handler!)
      (when handler-id
        (catch #t (lambda () (disconnect obj handler-id)) (lambda args #f))
        (set! handler-id #f)))

    (create-accessor
     get
     name
     #:subscribe-fn
     (lambda (thunk)
       (subs-add! subs thunk)
       (unless handler-id
         (set! handler-id
               (connect obj (string->symbol (string-append "notify::" prop))
                        (lambda (o . rest) (subs-notify! subs))))
         ;; Owned by the scope, so a disposed tree disconnects.
         (on-cleanup drop-handler!))
       (lambda ()
         (subs-remove! subs thunk)
         (when (zero? (subs-count subs))
           (drop-handler!)))))))

;;; ---------------------------------------------------------------------------
;;; create-binding-path
;;; ---------------------------------------------------------------------------

;; GObject properties frequently form a chain that can break in the middle: the
;; network's `wifi' device, the wifi device's `active-access-point', and the
;; access point's `ssid'.  Binding to `wifi' only tells you when the DEVICE
;; changes, not when its SSID does -- that is a property of the device.
;;
;; Following the chain needs two things a plain create-binding does not do:
;; tolerate a #f link (a machine with no wireless card), and MOVE its
;; subscription when an intermediate object is replaced.
;;
;; A step is either a property name (a string) or a PROCEDURE that selects the
;; next object from the current one.  The procedure form is what a list needs:
;; MPRIS exposes `players' as a list, and the metadata lives on the first player,
;; so ("players" first-player "title") is the path.  There is no property to
;; subscribe to for the selection itself -- the notification on the step BEFORE
;; it covers that -- so a procedure step descends without subscribing.
(define (path-step obj step)
  (cond ((not obj) #f)
        ((procedure? step) (step obj))
        ((string? step) (binding-getter-value obj step))
        (else (binding-getter-value obj (symbol->string step)))))

(define (path-step-property step)
  "The property name a step subscribes to, or #f for a selector."
  (cond ((string? step) step)
        ((symbol? step) (symbol->string step))
        (else #f)))

(define (path-read obj path)
  "Read PATH from OBJ, returning #f the moment a link is missing."
  (let loop ((o obj) (rest path))
    (cond ((null? rest) o)
          (else (loop (path-step o (car rest)) (cdr rest))))))

(define* (create-binding-path obj path #:optional (name 'binding-path))
  "An accessor over a chain of GObject properties, null-safely.

  (create-binding-path (network) '(\"wifi\" \"ssid\"))
  (create-binding-path (mpris) (list \"players\" first-player \"title\"))

A step is a property name or a procedure selecting the next object.  The chain
may break anywhere and yields #f there rather than an error, which is what makes
it usable on hardware that may not have the device, and on a session with no
media player running.

Subscribes along the whole chain and re-subscribes when an intermediate object
changes, so replacing the device -- or the player -- is noticed."
  (let* ((subs (make-subs))
         (chain '()))                  ; (obj . handler-id), current subscriptions

    (define (read) (path-read obj path))

    (define (drop-chain!)
      (for-each (lambda (entry)
                  (catch #t (lambda () (disconnect (car entry) (cdr entry)))
                         (lambda args #f)))
                chain)
      (set! chain '()))

    (define (subscribe-chain!)
      ;; Walk the path, subscribing to notify::<prop> on each object we can
      ;; reach.  Re-done on every notification, because one may mean the object
      ;; below it was replaced and our subscription now points at a dead one.
      (drop-chain!)
      (let loop ((o obj) (rest path))
        (when (and o (pair? rest))
          (let ((prop (path-step-property (car rest))))
            (when prop
              (let ((id (catch #t
                          (lambda ()
                            (connect o (string->symbol (string-append "notify::" prop))
                                     (lambda (changed . ignored)
                                       ;; Re-subscribe FIRST: the chain may have
                                       ;; moved, and waiting until after the
                                       ;; notify would miss a change in between.
                                       (subscribe-chain!)
                                       (subs-notify! subs))))
                          (lambda args #f))))
                (when id (set! chain (cons (cons o id) chain)))))
            ;; Descend regardless: a selector step has nothing to subscribe to,
            ;; but the step after it does.
            (loop (path-step o (car rest)) (cdr rest))))))

    (create-accessor
     read
     name
     #:subscribe-fn
     (lambda (thunk)
       (subs-add! subs thunk)
       (when (= 1 (subs-count subs))
         (subscribe-chain!)
         (on-cleanup drop-chain!))
       (lambda ()
         (subs-remove! subs thunk)
         (when (zero? (subs-count subs))
           (drop-chain!)))))))

;;; ---------------------------------------------------------------------------
;;; create-connection
;;; ---------------------------------------------------------------------------

(define* (create-connection initial #:optional (name 'connection))
  "Returns two values: an accessor whose value is pushed from outside, and a
setter for it.  This is the shape for a value fed by a GObject signal rather
than read from a property."
  (let ((value initial)
        (version 0)
        (subs (make-subs)))
    (let ((acc (create-accessor
                (lambda () value)
                name
                #:version-fn (lambda () version)
                #:subscribe-fn
                (lambda (thunk)
                  (subs-add! subs thunk)
                  (lambda () (subs-remove! subs thunk))))))
      (define (set-value! v)
        (unless (equal? value v)
          (set! value v)
          (set! version (1+ version))
          (subs-notify! subs)))
      (values acc set-value!))))
