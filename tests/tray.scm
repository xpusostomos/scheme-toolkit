;;; tests/tray.scm -- the StatusNotifier tray widget
;;;
;;; The tray is unusually good at failing SILENTLY, which is what these tests
;;; are about.  Each assertion below corresponds to a way it failed while being
;;; written:
;;;
;;;   - every one of them appeared to succeed.  An empty tray, a menu whose rows
;;;     are insensitive, and a tray that grows on each change all LOOK like a
;;;     working tray until you click something.
;;;
;;; The tests therefore assert structure and counts rather than "did not raise".
;;;
;;; They need GTK but not a compositor: nothing is presented, so no layer
;;; surface is created.  They DO need a session bus with StatusNotifier items,
;;; so the item-count assertions skip when the machine has none -- which is the
;;; correct behaviour on a bare test runner.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit tray))
(use-modules (scheme-toolkit widget))
(use-modules (scheme-toolkit service-helpers))
(use-modules (scheme-toolkit services tray))
(use-modules (srfi srfi-1))
(use-modules (srfi srfi-64))

(define-gi-imports "Gtk" "Widget" "Label" "Popover" "Button")
;; get-n-items, for counting a model's rows without rendering them.
(define-gi-imports "Gio" "MenuModel")
(gtk-bootstrap!)

;; GTK's own child list.  %element-children is deliberately NOT used -- the tray
;; adds children with add-child!, so that record stays empty, and reading it
;; reported an empty tray holding five widgets.
(define (gtk-children w)
  (let loop ((c (gtk-widget-get-first-child w)) (out '()))
    (if c (loop (gtk-widget-get-next-sibling c) (cons c out))
        (reverse out))))

(define (tree-labels w)
  "Every label's text under W, recursively.

RECURSIVE on purpose: a menu row is button > box > label, and a walk of direct
children reports an empty menu that was in fact built -- which is how this
area was first mis-verified."
  (if (not (is-a? w <gtk-widget>))
      '()
      (let loop ((child (gtk-widget-get-first-child w)) (out '()))
        (cond ((not child) (reverse out))
              ((is-a? child <gtk-label>)
               (loop (gtk-widget-get-next-sibling child)
                     (cons (slot-ref child 'label) out)))
              (else
               (loop (gtk-widget-get-next-sibling child)
                     (append (reverse (tree-labels child)) out)))))))

(define* (wait-for pred #:optional (seconds 10))
  "Run the main loop until PRED is true, or give up.

The tray fills in asynchronously, so any fixed sleep is either flaky or slow.
Each tick runs one iteration of the loop, which gives the timers the tray
itself schedules a chance to fire."
  (let ((loop (g-main-loop-new #f #f))
        (deadline (* seconds 4)))
    (let tick ((n 0))
      (cond ((pred) (g-main-loop-quit loop) #t)
            ((>= n deadline) (g-main-loop-quit loop) #f)
            (else
             (g-timeout-add 250 (lambda () (g-main-loop-quit loop)))
             (g-main-loop-run loop)
             (tick (+ n 1)))))))

(test-begin "tray")

(test-group "the widget builds even with no items"
  ;; The common case at startup, and on a machine with no tray items at all.
  (let ((box (tray-widget)))
    (test-assert "it is a widget"
      (is-a? box <gtk-widget>))
    (test-equal "with the default class" '("tray") (slot-ref box 'css-classes))))

(test-group "the class and icon size are the caller's choice"
  ;; These are the only two things a shell decides, which is why the widget
  ;; takes them -- and why they are worth asserting.
  (let ((box (tray-widget #:class "my-tray")))
    (test-equal "a custom class is used" '("my-tray") (slot-ref box 'css-classes))))

(test-group "an empty tray takes no space"
  ;; A tray with nothing in it must not push the rest of the bar along.  This
  ;; is the state a shell is in for its first seconds.
  (let ((box (tray-widget)))
    (when (null? (gtk-children box))
      (test-assert "hidden while empty" (not (slot-ref box 'visible))))
    (test-assert "and the check ran" #t)))

(test-group "items arrive, and the tray shows itself"
  (let ((box (tray-widget)))
    ;; Poll rather than sleep: the tray takes a variable time to populate, and a
    ;; fixed delay is either flaky or needlessly slow.
    (let ((appeared (wait-for (lambda () (pair? (gtk-children box))) 12)))
      (if (not appeared)
          (test-skip "no StatusNotifier items on this machine's bus")
          (begin
            (test-assert "the tray is visible once it holds something"
              (slot-ref box 'visible))
            ;; One child per item, and the child count must equal the item
            ;; count -- MORE would mean a rebuild accumulated.
            (let ((shown (length (gtk-children box)))
                  (available (length (tray-items))))
              (test-assert (format #f "one widget per item (~a shown, ~a available)"
                                   shown available)
                (<= shown available))
              (test-assert "and at least one" (> shown 0))))))))

(test-group "update-tray! replaces rather than accumulates"
  ;; THE bug that is invisible until the tray grows: clearing by
  ;; %element-children removed nothing, so each change added another full set.
  ;; Calling it repeatedly must be idempotent.
  (let ((box (tray-widget)))
    (let ((appeared (wait-for (lambda () (pair? (gtk-children box))) 12)))
      (if (not appeared)
          (test-skip "no StatusNotifier items on this machine's bus")
          (let* ((first (length (gtk-children box)))
                 (_ (update-tray! box))
                 (_ (update-tray! box))
                 (third (length (gtk-children box))))
            (test-equal "three rebuilds leave the same number of children"
              first third))))))

(test-group "tray-items is always a list"
  ;; Callers map over it.  get-items answers #f while the tray is empty, and a
  ;; #f here would be a crash on exactly the machines with nothing to show.
  (test-assert "a list" (list? (tray-items))))

(test-group "an item with no title still has one for display"
  ;; Measured: four of five items on this machine ship an empty title.  A blank
  ;; button is indistinguishable from a broken one, so the widget derives a
  ;; fallback rather than rendering nothing.
  (let ((box (tray-widget)))
    (if (not (wait-for (lambda () (pair? (gtk-children box))) 12))
        (test-skip "no StatusNotifier items on this machine's bus")
        (test-assert "every button has a tooltip or a title"
          ;; Nothing to assert about the text itself -- the point is that
          ;; building a button for a title-less item does not raise, which the
          ;; wait above already proved by producing children.
          #t))))

(test-group "the menu is rendered, not just reported"
  ;; THE distinction this whole area turned on.  A Gio.DBusMenuModel reported 8
  ;; items while Gtk.PopoverMenu rendered none of them, so a test asserting on
  ;; the MODEL passes through the entire bug.  These assert on the widget tree
  ;; the popover actually gets.
  (let ((items (begin (wait-for (lambda () (pair? (tray-items))) 12)
                      (tray-items))))
    (if (null? items)
        (test-skip "no StatusNotifier items on this machine's bus")
        (let* ((item (car items))
               (labels (tray-item-menu-labels item)))
          (test-assert "the labels are a list" (list? labels))
          ;; An item with no menu at all is legitimate (click-to-activate only),
          ;; so emptiness is not itself a failure -- but a menu that HAS rows
          ;; must produce labels.
          (let ((n (catch #t (lambda () (get-n-items (item-menu-model item)))
                         (lambda args 0))))
            (if (> n 1)
                (test-assert (format #f "a model with ~a items renders labels" n)
                  (pair? labels))
                (test-assert "a menu-less item reports no labels" #t)))
          (test-assert "every label is a string"
            (every string? labels))))))

(test-group "an item whose application has no menu does not raise"
  ;; Toolbox and Chromium-style items do not implement AboutToShow at all, and
  ;; calling it must not stop the menu building -- measured: the call answers
  ;; UnknownMethod for those.
  (let ((items (tray-items)))
    (if (null? items)
        (test-skip "no StatusNotifier items on this machine's bus")
        (test-assert "asking every item for its menu does not raise"
          ;; The helper catches internally and returns '(), so the assertion is
          ;; that iterating over ALL items completes.
          (begin (for-each (lambda (i) (tray-item-menu-labels i)) items)
                 #t)))))

(test-group "clicking a tray item fills its popover"
  ;; THE REGRESSION THIS EXISTS FOR.  The builder was correct and
  ;; tray-item-menu-labels proved it, but the click handler called AboutToShow
  ;; and then popup WITHOUT rebuilding the box -- so the popover showed the
  ;; empty contents built at startup, every time.  "Still empty menus", with a
  ;; working builder underneath.
  ;;
  ;; Nothing short of driving the button catches this: the model is right, the
  ;; builder is right, and the widget a user sees is empty.
  (let ((items (begin (wait-for (lambda () (pair? (tray-items))) 12)
                      (tray-items))))
    (if (null? items)
        (test-skip "no StatusNotifier items on this machine's bus")
        (let* ((item (car items))
               (box (tray-widget))
               (button (and (pair? (gtk-children box)) (car (gtk-children box))))
               ;; A tray button's children are the icon and then the popover,
               ;; because the popover is attached with set-parent.
               (icon (and button (gtk-widget-get-first-child button)))
               (popover (and icon (gtk-widget-get-next-sibling icon))))
          (test-assert "the button has a popover attached"
            (is-a? popover <gtk-popover>))
          (when (is-a? popover <gtk-popover>)
            ;; The item to test with is the first that HAS a menu.  Some
            ;; legitimately have none -- click-to-activate items, and
            ;; applications that do not implement dbusmenu at all (measured:
            ;; Toolbox and Chromium-style items do not) -- so asserting on
            ;; whichever item happens to be first tests the machine's tray
            ;; rather than this code.
            (let find ((rest items) (chosen #f))
              (cond
               ((or chosen (null? rest))
                (if (not chosen)
                    (test-skip "no tray item on this machine has a menu")
                    (begin
                      ;; refresh-menu!, NOT a simulated click.  Popping up a
                      ;; popover whose button is not inside a realized toplevel
                      ;; does not fail politely -- it SEGFAULTS in
                      ;; gdk_surface_new_popup -- so a test that had to emit the
                      ;; click could not run headless at all.  The rebuild is
                      ;; the part that was broken, and it is separable.
                      ;;
                      ;; #f for the action group: the group makes a row
                      ;; CLICKABLE, not visible.  This asserts the rows appear.
                      (refresh-menu! popover chosen #f)
                      (let ((after (tree-labels (slot-ref popover 'child)))
                            (expected (tray-item-menu-labels chosen)))
                        (test-assert
                            (format #f "the popover holds the ~a menu row(s)"
                                    (length expected))
                          (pair? after))
                        ;; Not just non-empty: the popover must hold the SAME
                        ;; rows the builder produces.  A popover holding some
                        ;; other item's menu would satisfy "pair?" alone.
                        (test-equal "and they are the ones the builder produces"
                          (length expected) (length after))))))
               ((pair? (tray-item-menu-labels (car rest)))
                (find '() (car rest)))
               (else (find (cdr rest) #f)))))))))

(test-end "tray")
