;;; tests/element.scm -- the element runtime against real GTK widgets
;;;
;;; These build actual widgets, so they need GTK initialised but not a
;;; compositor: nothing is presented, so no window appears and no layer-shell
;;; surface is created.  That keeps the suite runnable from a terminal.
;;;
;;; Note the two vocabularies, which are the whole surface of this layer:
;;;
;;;   (make <gtk-label> #:label "x")          a leaf widget, G-Golf's own API
;;;   (element <gtk-box> child ...)           structure: children, signals,
;;;                                           reactive props, css, slots
;;;
;;; `element' exists only for what `make' cannot express.  A static leaf needs
;;; nothing from it.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit reactive))
(use-modules (scheme-toolkit widget))
;; Only for %css-providers, to assert the per-widget provider is held.
(use-modules ((scheme-toolkit style) #:prefix style:))
(use-modules (oop goops))
(use-modules (srfi srfi-64))

;; Import just the classes this file names, the way any consumer would.
(define-gi-imports "Gtk"
  "Box" "Label" "Button" "CenterBox" "Stack")

(gtk-bootstrap!)

(test-begin "element")

(test-group "make covers a static leaf"
  ;; No element needed: this is G-Golf's own constructor.
  (let ((l (make <gtk-label> #:label "hello")))
    (test-assert "right class" (is-a? l <gtk-label>))
    (test-equal "property set" "hello" (slot-ref l 'label))))

(test-group "element constructs and passes properties"
  (let ((l (element <gtk-label> #:label "hello")))
    (test-assert "right class" (is-a? l <gtk-label>))
    (test-equal "property set" "hello" (slot-ref l 'label)))
  (let ((b (element <gtk-box> #:orientation 'vertical)))
    (test-equal "enum property as a symbol" 'vertical (slot-ref b 'orientation))))

(test-group "text children become labels"
  ;; A string child is a label child of the parent, as in JSX.
  (let ((b (element <gtk-box> "hi")))
    (test-equal "one child" 1 (length (%element-children b)))
    (test-equal "with the text" "hi"
      (slot-ref (car (%element-children b)) 'label)))
  (let ((b (element <gtk-box> 42)))
    (test-equal "numbers too" "42"
      (slot-ref (car (%element-children b)) 'label))))

(test-group "add-child! dispatch"
  (let ((b (element <gtk-box>
                     (make <gtk-label> #:label "a")
                     (make <gtk-label> #:label "b"))))
    (test-equal "box appends" 2 (length (%element-children b))))
  ;; #:slot is a property of the CHILD -- it says where the child goes, so it
  ;; is written on the child, as Gnim writes $type.
  (let ((cb (element <gtk-center-box>
                     (element <gtk-label> #:label "s" #:slot 'start))))
    (test-assert "centerbox start slot" (is-a? (slot-ref cb 'start-widget) <gtk-label>)))
  (let ((cb (element <gtk-center-box>
                     (element <gtk-label> #:label "e" #:slot 'end))))
    (test-assert "centerbox end slot" (is-a? (slot-ref cb 'end-widget) <gtk-label>)))
  (let ((cb (element <gtk-center-box>
                     (make <gtk-label> #:label "c"))))
    (test-assert "centerbox defaults to center"
      (is-a? (slot-ref cb 'center-widget) <gtk-label>)))
  ;; The fallback path: any parent with a writable child property.
  (let ((btn (element <gtk-button> (make <gtk-label> #:label "in"))))
    (test-assert "button set-child via the fallback"
      (is-a? (slot-ref btn 'child) <gtk-label>))))

(test-group "reactive property binding"
  ;; Outside a root the binding still takes effect -- subscribe is not
  ;; conditional on having a scope -- but there is nowhere to register the
  ;; disposal, so it leaks.  That is precisely what on-cleanup warns about, and
  ;; why widgets are built inside a root.
  (define-values (txt set-txt!) (create-state "one"))
  (let ((l (element <gtk-label> #:label txt)))
    (test-equal "read at construction" "one" (slot-ref l 'label))
    (set-txt! "two")
    (test-equal "updates even without a scope" "two" (slot-ref l 'label))))

(test-group "binding inside a root updates"
  (define-values (txt set-txt!) (create-state "one"))
  (define lbl #f)
  (define dispose
    (create-root (lambda (_d)
                   (set! lbl (element <gtk-label> #:label txt)))))
  (test-equal "initial" "one" (slot-ref lbl 'label))
  (set-txt! "two")
  (test-equal "reactive update reached the widget" "two" (slot-ref lbl 'label))
  (dispose))

(test-group "signals"
  (let ((clicks 0))
    (let ((b (element <gtk-button> #:label "x"
                      #:on-clicked (lambda (w) (set! clicks (1+ clicks))))))
      ;; Emitting is the same path a real click takes.
      (emit b 'clicked)
      (test-equal "on-clicked connected" 1 clicks))))

(test-group "css and class"
  (let ((l (element <gtk-label> #:label "x" #:class "a b")))
    (test-equal "class split into two" 2
      (length (slot-ref l 'css-classes))))
  ;; A declaration with no braces is wrapped, so this must not raise -- and it
  ;; did raise, with a bytevector type error, because the priority was passed as
  ;; the symbol 'user where GTK wants a number.  Assert the provider is HELD,
  ;; too: a per-widget provider nobody references is collected and its rules
  ;; then stop applying, silently and later.
  (let ((before (length style:%css-providers)))
    (element <gtk-label> #:label "y" #:css "color: red")
    (test-assert "a #:css prop loads and its provider is kept"
      (> (length style:%css-providers) before))))

(test-group "deferred properties"
  ;; Gtk.Stack's visible-child-name is meaningless before the children exist:
  ;; set during construction it is overwritten by the first add.
  (let ((s (element <gtk-stack>
                     #:visible-child-name "second"
                     (element <gtk-label> #:label "1"
                              #:slot 'named #:name "first")
                     (element <gtk-label> #:label "2"
                              #:slot 'named #:name "second"))))
    (test-equal "visible-child-name survived construction"
      "second" (slot-ref s 'visible-child-name))))

(test-group "fragments"
  ;; Keep the items by name rather than reaching into the fragment with
  ;; fragment-items: the accessor is internal, and a test that aborts on an
  ;; unbound name reports NO failure for every group after it -- which is
  ;; exactly how three bugs hid here for days.
  (let* ((a (make <gtk-label> #:label "a"))
         (f (fragment a))
         (b (element <gtk-box> f)))
    (test-equal "contents added" 1 (length (%element-children b)))
    (fragment-append! f (make <gtk-label> #:label "b"))
    (test-equal "append reached the parent" 2 (length (%element-children b)))
    (fragment-remove! f a)
    (test-equal "remove reached the parent" 1 (length (%element-children b)))))

(test-group "this! on an existing object"
  (let ((l (make <gtk-label> #:label "before")))
    (this! l #:label "after")
    (test-equal "property changed" "after" (slot-ref l 'label))))

(test-group "remove-child! dispatch"
  (let ((b (element <gtk-box>
                    (make <gtk-label> #:label "a")
                    (make <gtk-label> #:label "b"))))
    (remove-child! b (car (%element-children b)) #f)
    (test-equal "box removes" 1 (length (%element-children b))))
  (let ((cb (element <gtk-center-box>
                     (element <gtk-label> #:label "s" #:slot 'start))))
    (remove-child! cb (slot-ref cb 'start-widget) 'start)
    (test-equal "centerbox clears the slot" #f (slot-ref cb 'start-widget))))

(test-end "element")
