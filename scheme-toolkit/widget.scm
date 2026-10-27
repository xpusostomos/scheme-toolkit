;;; (scheme-toolkit widget) -- the element runtime, the JSX equivalent
;;;
;;; Widget code's shape mirrors the tree's shape, and a reactive value can be
;;; dropped in anywhere a property goes:
;;;
;;;   (window #:name "bar" #:anchor '(top left right)
;;;     (centerbox
;;;       (button #:slot 'start #:on-clicked (lambda (b) ...)
;;;         (label #:label "Welcome"))
;;;       (box #:slot 'center)
;;;       (menubutton #:slot 'end
;;;         (label #:label (clock))        ; an accessor: updates live
;;;         (popover (calendar)))))
;;;
;;; That is the AGS starter bar, line for line.
;;;
;;; WHY A PROCEDURE AND NOT A MACRO: JSX evaluates its children eagerly and
;;; passes a props object, and a Scheme variadic keyword procedure does exactly
;;; the same thing.  There is no compile-time structure to exploit.
;;;
;;; THE ONE PLACE THIS DIVERGES FROM GNIM.  Gnim falls back to
;;; `Gtk.Buildable.vfunc_add_child' for any parent it does not recognise, and
;;; GtkBuildable then dispatches to the right thing (CenterBox start/center/end,
;;; Box append, Bin set_child, and so on).  G-Golf can IMPLEMENT a vfunc in a
;;; subclass but has no way to INVOKE one on an existing instance, so that
;;; fallback is unavailable.  `add-child!' is the replacement: an explicit
;;; GOOPS generic with a method per container, which is more work to extend but
;;; says what it does and fails with the two class names when it cannot.

(define-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  ;; Prefixed: (scheme-toolkit style) also exports apply-css!, and this module
  ;; keeps its own name for the #:css prop.  The prefixed import is the whole
  ;; of style.scm's surface used here, which is one call.
  #:use-module ((scheme-toolkit style) #:prefix style:)
  #:use-module (oop goops)
  #:use-module (ice-9 match)
  #:duplicates (merge-generics replace warn-override-core warn last)

  #:export (element
            add-child! remove-child!
            this! fragment fragment? fragment-append! fragment-remove!
            on-fragment-change!
            text-node
            apply-css! apply-class!
            child-type set-child-type!
            %element-setup
            %element-children))

;; The add-child! methods below dispatch on Gtk container classes, so those
;; classes have to be imported here: a method specialiser naming an unbound
;; class is a compile error.  The import runs at expand time so the compiler can
;; see the classes while it is compiling the methods.
(eval-when (expand load eval)
  (use-modules (g-golf))
  (g-irepository-require "Gtk" #:version "4.0")
  (for-each (lambda (name) (gi-import-by-name "Gtk" name))
            '("Widget" "CenterBox" "Overlay" "Box" "Stack" "ListBox"
              "FlowBox" "Grid" "MenuButton" "Popover" "EventController"
              "Label" "CssProvider")))


;;; ---------------------------------------------------------------------------
;;; Child type tags
;;; ---------------------------------------------------------------------------

;; GtkBuildable's child types are strings ("start", "center", "end", "overlay",
;; "named").  A child is built before its parent sees it, so the tag has to be
;; stored ON the child -- Gnim uses a symbol property for this.  A weak table
;; keyed on the child does the same without adding a slot to every GObject.
(define %child-types (make-weak-key-hash-table))

(define (set-child-type! child type)
  (hashq-set! %child-types child (if (symbol? type) (symbol->string type) type))
  child)

(define (child-type child)
  (hashq-ref %child-types child #f))

;;; ---------------------------------------------------------------------------
;;; Property classification
;;; ---------------------------------------------------------------------------

;; Props arrive as keywords.  Which kind each one is decides what happens to it:
;;
;;   #:on-clicked / #:on-notify-visible / #:on-changed:key   a signal to connect
;;   #:class #:css #:setup #:slot #:constructor #:children      specials
;;   anything else                                          a constructor
;;                                                          property, unless it
;;                                                          is a deferred one
;;
;; Note the spelling differs from Gnim, which writes these as `$' and `$type' in
;; JSX attribute names.  Guile cannot read `#:$type' at all -- `$' is not a
;; constituent character -- so the Guile spellings are #:setup (Gnim's `$') and
;; #:slot (Gnim's `$type').

(define (kw->str kw)
  "A keyword's name without the #: -- (kw->str #:on-clicked) => \"on-clicked\"."
  (symbol->string (keyword->symbol kw)))

(define (%special-prop? kw)
  (memq kw '(#:setup #:slot #:constructor #:class #:css)))

(define (%signal-kw? kw)
  (let ((s (kw->str kw)))
    (and (> (string-length s) 3) (string=? (substring s 0 3) "on-"))))

(define (signal-name-of kw)
  "on-clicked -> clicked;  on-notify-visible -> notify::visible;
on-changed:key -> changed::key."
  (let* ((s (kw->str kw))
         (rest (substring s 3))
         ;; A literal colon in the keyword survives as part of its name, which
         ;; is how a signal detail is spelled: #:on-changed:monitor.
         (parts (string-split rest #\:)))
    (cond ((string-prefix? "notify-" (car parts))
           (string-append "notify::" (substring (car parts) 7)))
          ((null? (cdr parts)) (car parts))
          (else (string-append (car parts) "::" (cadr parts))))))

;; Properties that only mean something once the children exist.  Gtk.Stack's
;; visible-child-name is the canonical case: set it during construction and it
;; is immediately overwritten by the first child added.  Gnim calls these
;; initProps; this is that table.
;; The keys are CLASS OBJECTS, so the table is built with a backquote and
;; unquotes.  Written as a plain quote it holds the SYMBOLS <gtk-stack> and
;; <adw-toggle-group>, which match no class -- so deferred-prop? answered #f for
;; everything and nothing was ever deferred.  It looked right because a symbol
;; and a class print the same way.
;; Adw.ToggleGroup's active/active-name belong here too, but only once a module
;; imports it: the entry must be the class OBJECT, and naming an unimported
;; class in the backquote is a load-time error rather than a silent miss.  Add
;; the entry in the module that imports Adw, or extend this one's imports.
(define %deferred-props
  `((,<gtk-stack> . ("visible-child-name"))))

(define (deferred-prop? class prop)
  "Is PROP a property of CLASS that must wait until the children exist?

The lookup is `eq?' on the class OBJECT, not assoc-ref.  assoc-ref compares with
equal?, and a GOOPS class is not equal? to itself by value -- it is only eq? --
so assoc-ref answered #f for every class.  The effect was that deferred
properties were never deferred: Gtk.Stack's visible-child-name went straight to
`make' at construction, was overwritten by the first child added, and left the
stack showing page one with a \"Child name not found\" warning."
  (let ((names (cond ((assq-ref %deferred-props class))
                     (else #f))))
    (or (and names (member prop names) #t)
        ;; A subclass inherits the deferral: (class-of obj) for anything
        ;; deriving from Gtk.Stack is not eq? to <gtk-stack>, and a conflict
        ;; window or an Astal box around a stack wants the same behaviour.
        (let loop ((rest %deferred-props))
          (cond ((null? rest) #f)
                ((and (is-a? class (caar rest)) (member prop (cdar rest))) #t)
                (else (loop (cdr rest))))))))

;;; ---------------------------------------------------------------------------
;;; Child insertion
;;; ---------------------------------------------------------------------------

;; Methods are ordered most-specific-first by GOOPS automatically; what matters
;; is that every container the shell uses has one.  When one is missing the
;; error names both classes, which is the signal to add a method here.
(define-generic add-child!)
(define-generic %remove-child!)
(define-generic remove-child!)

(define (widget? o) (is-a? o <gtk-widget>))

;; CenterBox's three slots are the reason $type exists at all.
(define-method (add-child! (p <gtk-center-box>) (c <gtk-widget>) type)
  (case (and type (string->symbol type))
    ((start) (set-start-widget p c))
    ((end) (set-end-widget p c))
    (else (set-center-widget p c))))

(define-method (add-child! (p <gtk-overlay>) (c <gtk-widget>) type)
  (if (and type (string=? "overlay" type))
      (add-overlay p c)
      (set-child p c)))

(define-method (add-child! (p <gtk-box>) (c <gtk-widget>) type)
  (append p c))

(define-method (add-child! (p <gtk-stack>) (c <gtk-widget>) type)
  (if (and type (string=? "named" type))
      (let ((name (slot-ref c 'name)))
        (add-named p c name))
      (add-child p c)))

(define-method (add-child! (p <gtk-list-box>) (c <gtk-widget>) type)
  (append p c))

(define-method (add-child! (p <gtk-flow-box>) (c <gtk-widget>) type)
  (append p c))

(define-method (add-child! (p <gtk-grid>) (c <gtk-widget>) type)
  ;; A grid child needs coordinates, which arrive as the child's own row/column
  ;; properties and are attached with a separate call.
  (attach p c
          (or (and (slot-exists? c 'column) (slot-ref c 'column)) 0)
          (or (and (slot-exists? c 'row) (slot-ref c 'row)) 0)
          1 1))

;; Event controllers and other non-widget children go on as controllers.
(define-method (add-child! (p <gtk-widget>) (c <gtk-event-controller>) type)
  (add-controller p c))

(define-method (add-child! (p <gtk-menu-button>) (c <gtk-popover>) type)
  (set-popover p c))

;; The fallback: any parent with a writable `child' property.  This covers
;; Window, Button, Revealer, Bin, ScrolledWindow, Expander, and every Astal
;; container that follows the same convention.
(define-method (add-child! (p <gtk-widget>) (c <gtk-widget>) type)
  (cond ((class-has-property? (class-of p) 'child) (slot-set! p 'child c))
        ((class-has-property? (class-of p) 'adjustment)
         (slot-set! p 'adjustment c))
        (else
         (error "add-child!: no method for this parent/child pair"
                (class-name (class-of p)) (class-name (class-of c))
                "-- add a method to (scheme-toolkit widget)"))))

(define (class-has-property? class prop)
  (define (specs c)
    (catch #t
      (lambda ()
        (map (lambda (p) (g-param-spec-get-name p))
             (g-object-class-list-properties (!g-class c))))
      (lambda args '())))
  (and (member (symbol->string prop) (specs class)) #t))

;; Removal mirrors insertion, so a For that removes a child does the same thing
;; for every container.
(define-method (%remove-child! (p <gtk-widget>) (c <gtk-event-controller>) type)
  (remove-controller p c))

(define-method (%remove-child! (p <gtk-center-box>) (c <gtk-widget>) type)
  (cond ((eq? (slot-ref p 'start-widget) c) (set-start-widget p #f))
        ((eq? (slot-ref p 'end-widget) c) (set-end-widget p #f))
        ((eq? (slot-ref p 'center-widget) c) (set-center-widget p #f))))

(define-method (%remove-child! (p <gtk-overlay>) (c <gtk-widget>) type)
  ;; GTK4 gives no way to enumerate an Overlay's children -- there is no
  ;; get_overlay_widgets -- so the only testable case is whether C is the main
  ;; child, which get-child answers.  An overlay added with add-overlay is
  ;; removed by the same call.
  (cond ((and (string=? (or type "") "overlay"))
         (remove-overlay p c))
        ((eq? (get-child p) c)
         (set-child p #f))
        (else #f)))

(define-method (%remove-child! (p <gtk-box>) (c <gtk-widget>) type)
  (remove p c))

(define-method (%remove-child! (p <gtk-list-box>) (c <gtk-widget>) type)
  (remove p c))

(define-method (%remove-child! (p <gtk-flow-box>) (c <gtk-widget>) type)
  (remove p c))

(define-method (%remove-child! (p <gtk-grid>) (c <gtk-widget>) type)
  (remove p c))

;; The generic fallback for a Bin-like parent: clear the child, but only if it
;; really is the current one, so removing a stale child does not blank the tree.
(define-method (%remove-child! (p <gtk-widget>) (c <gtk-widget>) type)
  (cond ((and (class-has-property? (class-of p) 'child)
              (eq? (slot-ref p 'child) c))
         (set-child p #f))
        ((class-has-property? (class-of p) 'child)
         #f)                       ; not the current child; nothing to do
        (else
         (error "remove-child!: no method for this parent/child pair"
                (class-name (class-of p)) (class-name (class-of c))))))

;; The public generic: remove, then keep %children honest.
;;
;; Without the second half, a direct remove-child! took the widget off the
;; parent but left it in %element-children.  The tree and the record then
;; disagreed, so a For reconciling by walking the record would try to remove a
;; child that was already gone -- and a test would read the wrong count.
(define (remove-child! p c . rest)
  (apply %remove-child! p c rest)
  (when (and (is-a? p <gtk-widget>)
             (hash-table? %children)
             (hashq-ref %children p))
    (hashq-set! %children p (delq c (hashq-ref %children p))))
  #t)

;;; ---------------------------------------------------------------------------
;;; Fragments
;;; ---------------------------------------------------------------------------

;; A For or a With hands the parent a single child that stands for a list of
;; children, and mutates that list later.  A Fragment is that stand-in: it holds
;; the items and a list of observers the parent registers to hear about changes.
;; #:init-value rather than #:init-form for items, and a #:init-keyword to go
;; with it.  Without the keyword, (make <fragment> #:items items) SILENTLY
;; IGNORES the keyword -- GOOPS accepts unknown init keywords for a class and
;; drops them -- so every fragment was empty and (element <gtk-box> f) added
;; nothing.  A #f #:child-type and zero children was the only symptom.
(define-class <fragment> ()
  (items     #:init-value '() #:init-keyword #:items #:accessor fragment-items)
  (observers #:init-value '() #:accessor fragment-observers)
  (parent    #:init-value #f #:init-keyword #:parent))

(define (fragment? x) (is-a? x <fragment>))
(define (make-fragment items) (make <fragment> #:items items))

(define (on-fragment-change! frag proc)
  (slot-set! frag 'observers (cons proc (slot-ref frag 'observers))))

(define (notify-fragment! frag action item)
  (for-each (lambda (proc) (proc action item))
            (slot-ref frag 'observers)))

(define (fragment-append! frag item)
  "Add ITEM to FRAG, telling any observers so the parent can insert it."
  (slot-set! frag 'items (append (slot-ref frag 'items) (list item)))
  (notify-fragment! frag 'append item))

(define (fragment-remove! frag item)
  (slot-set! frag 'items (delq item (slot-ref frag 'items)))
  (notify-fragment! frag 'remove item))

(define (fragment . items) (make-fragment items))

;;; ---------------------------------------------------------------------------
;;; Text children
;;; ---------------------------------------------------------------------------

(define (text-node x)
  "A string or number child becomes a label, as it does in JSX."
  (make <gtk-label> #:label (if (string? x) x (format #f "~a" x))))

;;; ---------------------------------------------------------------------------
;;; Per-widget css and classes
;;; ---------------------------------------------------------------------------

(define (apply-css! widget css)
  "A per-widget provider at USER priority.  A declaration without braces is
wrapped in a universal rule so `#:css \"color: red\"' works.

Delegates to (scheme-toolkit style), which HOLDS the provider.  A per-widget
provider nobody references is collected and its rules then stop applying --
silently, and at some unpredictable later moment -- so the one thing this must
not do is make its own provider and drop it.  It also must not pass a symbol
where GTK wants a number: 'user is not a priority, and the failure is a
bytevector type error naming neither CSS nor priorities."
  (unless (is-a? widget <gtk-widget>)
    (error "apply-css!: not a widget" widget))
  (let ((css (if (and (string-contains css "{") (string-contains css "}"))
                 css
                 (string-append "* { " css " }"))))
    (style:apply-css! widget css #:priority 800)))

(define (apply-class! widget class)
  (set-css-classes widget
                   (if (string? class)
                       (string-split class #\space)
                       class)))

;;; ---------------------------------------------------------------------------
;;; element
;;; ---------------------------------------------------------------------------

(define (%element-setup obj)
  "The $ callback, stored on the object so `this!' can find it."
  (hashq-ref %setups obj))

(define %setups (make-weak-key-hash-table))

(define (%element-children obj)
  "Children this element added, so a test or the REPL can walk the tree."
  (hashq-ref %children obj '()))

(define %children (make-weak-key-hash-table))

(define (split-args args)
  "Split a flat keyword/positional arg list into (CLASS KEYWORD-ARGS POSITIONAL)."
  (let loop ((rest args) (kws '()) (pos '()))
    (cond ((null? rest) (values (reverse kws) (reverse pos)))
          ((keyword? (car rest))
           (loop (cddr rest) (cons (cons (car rest) (cadr rest)) kws) pos))
          (else (loop (cdr rest) kws (cons (car rest) pos))))))

(define (make-from-constructor constructor class kw-args)
  "Construct the object, passing every non-special property through to make.

Reactive values are read once with peek for construction: a property set during
construction cannot be a subscription yet, because there is nothing to subscribe
with until the object exists."
  (let ((ctor-props '())          ; (keyword . value) pairs, in order
        (deferred '()))
    (for-each
     (lambda (pair)
       (let ((kw (car pair)) (val (cdr pair)))
         (cond
          ((%special-prop? kw) #f)
          ((%signal-kw? kw) #f)
          (else
           (let ((name (kw->str kw)))
             (if (deferred-prop? class name)
                 (set! deferred (cons pair deferred))
                 ;; Read an accessor once here: a property set during
                 ;; construction cannot be a subscription yet, because there is
                 ;; no object to subscribe for until make returns.
                 ;; The keyword itself goes through to `make': GOOPS wants
                 ;; #:label, not the bare symbol `label'.
                 (set! ctor-props
                       (cons (cons kw (if (accessor? val) (st-peek val) val))
                             ctor-props))))))))
     kw-args)
    ;; Reverse to restore source order, then flatten to the keyword arguments
    ;; `make' expects.
    (let* ((props (reverse ctor-props))
           (flat (apply append (map (lambda (p) (list (car p) (cdr p))) props)))
           (obj (if constructor
                    ;; #:constructor overrides, for the cases where the GIR
                    ;; constructor is not the one you want (Gtk.Label.new).
                    (apply constructor flat)
                    (apply make class flat))))
      (values obj deferred))))

(define (bind-property! obj prop acc)
  "Point a GObject property at an accessor: read it now, and re-set it whenever
the accessor changes.  The subscription is registered with on-cleanup, which is
what makes disposing a widget tree leave no handlers behind."
  (let ((sym (string->symbol prop)))
    (catch #t
      (lambda () (slot-set! obj sym (st-peek acc)))
      (lambda (key . args)
        (error "cannot bind property" prop "on" (class-name (class-of obj)))))
    (on-cleanup (subscribe acc (lambda ()
                                 (slot-set! obj sym (st-peek acc)))))))

(define (connect-signal! obj signal proc)
  (let ((id (connect obj (string->symbol signal)
                     (lambda (o . rest) (apply proc o rest)))))
    (on-cleanup (lambda ()
                  (catch #t (lambda () (disconnect obj id)) (lambda args #f))))
    id))

(define (element class . args)
  "Construct a widget tree node.

  (element <gtk-label> #:label \"hi\")
  (element <gtk-center-box> (element <gtk-button> #:label \"x\") ...)

CLASS is a G-Golf class.  Keywords are properties, signals (`#:on-clicked'),
bindings (a property whose value is an accessor), or one of the specials #:class
#:css #:setup #:slot #:constructor."
  (call-with-values
    (lambda () (split-args args))
    (lambda (kw-args children)
      (let* ((props (map car kw-args))
             (get (lambda (kw) (assq-ref kw-args kw)))
             (constructor (get #:constructor))
             (setup (get #:setup))
             (slot (get #:slot))
             (css (get #:css))
             (klass (get #:class)))
        (call-with-values
          (lambda () (make-from-constructor constructor class kw-args))
          (lambda (obj deferred)
            ;; Reactive properties that were passed through to the constructor
            ;; get their subscription now that the object exists.
            (for-each
             (lambda (pair)
               (let ((kw (car pair)) (val (cdr pair)))
                 (when (and (accessor? val)
                            (not (%special-prop? kw))
                            (not (%signal-kw? kw)))
                   (bind-property! obj (symbol->string (keyword->symbol kw)) val))))
             kw-args)
            ;; Signals.
            (for-each
             (lambda (pair)
               (let ((kw (car pair)) (val (cdr pair)))
                 (when (%signal-kw? kw)
                   (connect-signal! obj (signal-name-of kw) val))))
             kw-args)
            ;; class and css.
            (when klass
              (if (accessor? klass)
                  (begin (apply-class! obj (st-peek klass))
                         (on-cleanup (subscribe klass (lambda () (apply-class! obj (st-peek klass))))))
                  (apply-class! obj klass)))
            (when css
              (if (accessor? css)
                  (begin (apply-css! obj (st-peek css))
                         (on-cleanup (subscribe css (lambda () (apply-css! obj (st-peek css))))))
                  (apply-css! obj css)))
            (when slot (set-child-type! obj slot))
            (when setup (hashq-set! %setups obj setup))
            ;; Children.
            ;;
            ;; Everything inserted is recorded in %children, including the label
            ;; built for a string child: (element <gtk-box> "hi") really does
            ;; add a widget, and a caller walking the tree should see it.
            (let ((added '()))
              ;; record!/unrecord! publish IMMEDIATELY rather than leaving the
              ;; final (hashq-set! ...) to do it.  A fragment's observer runs
              ;; later, after this let has returned, so a version of this that
              ;; only consed onto `added' updated a dead local and the parent's
              ;; child list never grew: append added the widget to the box but
              ;; %element-children still answered the old count.
              (define (publish!)
                (hashq-set! %children obj (reverse added)))
              (define (record! child)
                (set! added (cons child added))
                (publish!))
              (define (unrecord! child)
                (set! added (delq child added))
                (publish!))
              (define (add! child type)
                (add-child! obj child type)
                (record! child))
              (for-each
               (lambda (child)
                 (cond
                  ((string? child) (add! (text-node child) #f))
                  ((number? child) (add! (text-node child) #f))
                  ((fragment? child)
                   ;; The fragment stands for a list; add what is in it now and
                   ;; follow it afterwards, so a For can mutate the parent.
                   (for-each (lambda (item) (add! item (child-type item)))
                             (fragment-items child))
                   (on-fragment-change!
                    child
                    (lambda (action item)
                      (case action
                        ((append) (add! item (child-type item)))
                        ((remove) (catch #t
                                    (lambda () (remove-child! obj item (child-type item)))
                                    (lambda args #f))
                                  (unrecord! item))))))
                  ;; A controller is not a child widget; it is not recorded.
                  ((is-a? child <gtk-event-controller>)
                   (add-child! obj child #f))
                  (else (add! child (child-type child)))))
               children)
              (publish!))
            ;; Deferred properties, set after the children exist.
            (for-each
             (lambda (pair)
               (let ((prop (symbol->string (keyword->symbol (car pair))))
                     (val (cdr pair)))
                 (catch #t
                   (lambda () (slot-set! obj (string->symbol prop)
                                         (if (accessor? val) (st-peek val) val)))
                   (lambda args #f))))
             deferred)
            ;; The $ setup callback runs last, on a complete node.
            (when setup (setup obj))
            obj))))))

;;; ---------------------------------------------------------------------------
;;; this! -- apply props and children to an existing object
;;; ---------------------------------------------------------------------------

(define (this! obj . args)
  "Apply props and children to an object that already exists.

This is how a factory that returns a configured widget gets further configured
without rebuilding it."
  (call-with-values
    (lambda () (split-args args))
    (lambda (kw-args children)
      (for-each
       (lambda (pair)
         (let ((kw (car pair)) (val (cdr pair)))
           (cond
            ((%special-prop? kw)
             (case kw
               ((#:class) (apply-class! obj (if (accessor? val) (st-peek val) val)))
               ((#:css) (apply-css! obj (if (accessor? val) (st-peek val) val)))
               ((#:setup) (hashq-set! %setups obj val) (val obj))
               ((#:slot) (set-child-type! obj val))
               (else #f)))
            ((%signal-kw? kw) (connect-signal! obj (signal-name-of kw) val))
            ((accessor? val)
             (bind-property! obj (symbol->string (keyword->symbol kw)) val))
            (else
             (catch #t
               (lambda () (slot-set! obj (keyword->symbol kw) val))
               (lambda args #f))))))
       kw-args)
      (for-each (lambda (child)
                  (cond ((string? child) (add-child! obj (text-node child) #f))
                        ((number? child) (add-child! obj (text-node child) #f))
                        (else (add-child! obj child (child-type child)))))
                children)
      obj)))
