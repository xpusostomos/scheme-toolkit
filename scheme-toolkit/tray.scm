;;; (scheme-toolkit tray) -- a StatusNotifier system tray widget
;;;
;;; Every StatusNotifier item a desktop offers, each a button whose click opens
;;; that item's own D-Bus menu.  Nothing here is a decision a particular shell
;;; made: the tray protocol, the menu plumbing and the action-group requirement
;;; are the same for any shell, so this lives in the toolkit and a shell calls
;;; `tray-widget' with its own CSS class and icon size.
;;;
;;; THREE THINGS MAKE THIS DIFFERENT FROM A WIDGET THAT JUST LISTS THINGS.
;;;
;;; 1. THE TRAY IS EMPTY AT STARTUP.  Measured on this machine: `get-items'
;;;    answers #f and `get-n-items' answers 0 when a process starts, and five
;;;    items have arrived about two seconds later.  StatusNotifier items
;;;    register as applications start, so a tray built once shows nothing and
;;;    looks broken.  Everything here is therefore driven by the `items-model'
;;;    GListModel's `items-changed' signal, not by a single read.
;;;
;;; 2. THE MENU IS NOT OURS.  A TrayItem carries a `menu-model' (a Gio.MenuModel
;;;    built by the application) and an `action-group' (its exported actions).
;;;    We do not interpret the menu; we hand it to a Gtk.PopoverMenu, which
;;;    renders it.  This is the part worth not reinventing: a tray menu can be
;;;    arbitrarily deep, contain checkboxes and submenus, and change at runtime,
;;;    and reimplementing that is how a tray ends up broken for half the
;;;    applications on a desktop.
;;;
;;;    The `action-group' MUST be inserted into a widget that is an ANCESTOR of
;;;    the popover, or the menu renders correctly with every row INSENSITIVE --
;;;    which reads as "this application does not respond" rather than "we forgot
;;;    the action group".  See insert-action-group!.
;;;
;;; 3. THE CHILD LIST IS GTK'S, NOT `%element-children'.  Items are added and
;;;    removed at runtime, so this module uses `add-child!'/`remove-child!'
;;;    directly rather than `element'.  The element runtime's record of what it
;;;    built is therefore EMPTY here, and anything reasoning about the tray's
;;;    contents must walk GTK's own child list.  Getting that wrong made an
;;;    empty-looking tray that was in fact holding five widgets, and made a
;;;    rebuild accumulate items instead of replacing them.

(define-module (scheme-toolkit tray)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit astal)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (tray-widget
            tray-items
            update-tray!))

(define-gi-imports "Gtk" "Box" "Button" "Image" "MenuButton" "PopoverMenu" "Widget")
(define-gi-imports "Gio" "MenuModel" "ActionGroup" "SimpleActionGroup")

(gi-import-by-name "AstalTray" "Tray")
(gi-import-by-name "AstalTray" "TrayItem")

;;; ---------------------------------------------------------------------------
;;; Item helpers
;;; ---------------------------------------------------------------------------

(define (item-attr item prop)
  "ITEM's PROP, or #f.  Every tray property is read defensively: a third-party
item is within its rights to leave the title empty or the icon unset, and one
malformed item must not take the whole tray with it."
  (catch #t (lambda () (slot-ref item prop)) (lambda args #f)))

(define (item-title item)
  "A label for ITEM.

Falls back to the application's own id, because a blank button is
indistinguishable from a broken one -- and several real items (measured: four
of five on this machine) ship an empty title."
  (let ((title (item-attr item 'title)))
    (cond ((and (string? title) (not (string-null? (string-trim title)))) title)
          (else
           (let ((id (item-attr item 'item-id)))
             ;; The id is "bus-name/StatusNotifierItem"; the bus name is not
             ;; readable to a user, so it is only a last resort.
             (if (and (string? id) (not (string-null? id)))
                 (car (string-split id #\/))
                 "tray item"))))))

(define (item-tooltip item)
  "The best available tooltip, or #f."
  (let ((markup (item-attr item 'tooltip-markup))
        (text (item-attr item 'tooltip-text))
        (title (item-attr item 'title)))
    (cond ((and (string? markup) (not (string-null? markup))) markup)
          ((and (string? text) (not (string-null? text))) text)
          ((and (string? title) (not (string-null? title))) title)
          (else #f))))

(define (item-icon item)
  "A GIcon or an icon name for ITEM, or #f.

`gicon' is the reliable one.  The test is `string?' rather than
`is-a? <g-icon>': what the caller needs is which of the two forms it holds,
and that is exactly the string/non-string distinction.  (Measured on this
machine: `icon-name' is a string on some items and a non-string on others.)"
  (let ((gicon (item-attr item 'gicon))
        (name (item-attr item 'icon-name)))
    (cond ((and gicon (not (string? gicon))) gicon)
          ((and (string? name) (not (string-null? name))) name)
          (else #f))))

(define (item-menu-model item)
  "A Gio.MenuModel for ITEM's menu, or #f.

Measured against the real items on this machine: an AstalTray item's
`menu-model' is a Gio.DBusMenuModel with exactly ONE item, and that item links
to the application's real menu under `section' -- not `submenu'.  Asking for
`submenu' answers #f for every item, which builds a button that opens nothing
and looks exactly like an application whose menu is broken.

Both are tried, in that order, because which one a StatusNotifier host uses is
its own choice; the DBusMenu case is simply what is here.
  (get-n-items model)      => 1
  (get-item-link m 0 \"submenu\") => #f
  (get-item-link m 0 \"section\") => <d-bus-menu-section-model>

The section (or submenu) is what a Gtk.PopoverMenu wants.  Handing it the
outer model instead shows a single row that opens a submenu -- not what the
application drew."
  (let ((model (item-attr item 'menu-model)))
    (and model
         (catch #t
           (lambda ()
             (let ((n (get-n-items model)))
               (and (> n 0)
                    (or (get-item-link model 0 "section")
                        (get-item-link model 0 "submenu")
                        ;; No wrapper at all: some hosts hand over the menu
                        ;; directly, and then the model IS the section.
                        model))))
           (lambda args #f)))))

;;; ---------------------------------------------------------------------------
;;; The menu
;;; ---------------------------------------------------------------------------

(define (insert-action-group! button group)
  "Make GROUP's actions available to BUTTON's menu.

  (insert-action-group WIDGET PREFIX GROUP)   -- THREE arguments.

Gtk.PopoverMenu resolves a menu item's action against the widget hierarchy: an
action named \"activate\" is looked up as an action-group on the popover, or on
an ancestor of it.  A tray item's actions belong to the APPLICATION, so without
this the menu renders correctly and every row is insensitive -- which reads as
\"the application does not respond\" rather than \"we forgot the action group\".

PREFIX is required and must be the EMPTY STRING here.  The menu items the
application built carry unprefixed action names (\"activate\", \"quit\"), and the
prefix is what those names are registered under -- anything else and every
lookup misses.  G-Golf's signature is (widget name group); calling it with two
arguments raises a goops-error that names neither the missing argument nor this
requirement."
  (when group
    (catch #t
      (lambda () (insert-action-group button "" group))
      (lambda (key . args)
        (format (current-error-port)
                "scheme-desktop: tray: cannot install action group: ~a ~s~%"
                key args)))))

(define* (tray-menu-button item #:optional (class "tray-item") (icon-size 16))
  "A MenuButton for ITEM: its icon, and its application's menu on click.

CLASS and ICON-SIZE are the caller's choices, which is why this is not
hard-coded: a bar's icon size and CSS class are that shell's decision."
  (let* ((section (item-menu-model item))
         (group (item-attr item 'action-group))
         ;; A PopoverMenu built from the item's own section -- NOT from the
         ;; menu bar, which would nest one row deep.
         (popover (if section
                      (make <gtk-popover-menu> #:menu-model section)
                      #f))
         (button (element <gtk-menu-button>
                          #:class class
                          #:tooltip-text (item-tooltip item)
                          ;; A menu button with no menu must not open an empty
                          ;; popover: some items are click-to-activate only.
                          #:always-show-arrow #f
                          (element <gtk-image> #:gicon (item-icon item)
                                   #:pixel-size icon-size))))
    (when popover
      ;; The action group goes on the BUTTON, which is an ancestor of the
      ;; popover -- see insert-action-group!.
      (insert-action-group! button group)
      (slot-set! button 'popover popover))
    button))

;;; ---------------------------------------------------------------------------
;;; The widget
;;; ---------------------------------------------------------------------------

(define (status-is-passive? item)
  "Is ITEM's status 'passive?  Such items are asking not to be shown -- a
hidden-but-registered helper rather than something the user wants in a bar."
  (let ((status (item-attr item 'status)))
    (and status (memq status '(passive)) #t)))

(define (show-item? item)
  (and item
       (not (status-is-passive? item))
       ;; An item with neither icon nor title would render as an empty square
       ;; that does nothing, which is worse than omitting it.
       (or (item-icon item) (item-title item))))

(define (tray-items)
  "The presentable tray items right now, as a list.

`get-items' answers #f -- not '() -- while the tray is still empty, which is the
normal state for the first seconds of a process's life.  Normalising here means
every caller does not have to."
  (let ((t (catch #t (lambda () (tray)) (lambda args #f))))
    (if (not t)
        '()
        (let ((items (catch #t (lambda () (get-items t)) (lambda args #f))))
          (if (list? items) (filter show-item? items) '())))))

(define* (update-tray! box #:key (class "tray-item") (icon-size 16))
  "Fill BOX with a button per presentable tray item.  Returns the count.

Rebuilt from scratch on every change.  A tray holds a handful of items, so
reconciliation would be more code than it saves -- and StatusNotifier items are
added and removed rarely, not per frame."
  ;; Clear by walking GTK's OWN child list, not %element-children.  This module
  ;; adds children with add-child!, so the element record stays empty and
  ;; clearing from it removed nothing -- items accumulated on every change,
  ;; visible as a tray that grows every time an application starts.
  (let loop ((child (gtk-widget-get-first-child box)))
    (when child
      (let ((next (gtk-widget-get-next-sibling child)))
        (catch #t (lambda () (remove-child! box child #f)) (lambda args #f))
        (loop next))))
  (let ((items (tray-items)))
    (for-each
     (lambda (item)
       ;; add-child! directly rather than `element': this is a rebuild of an
       ;; existing box, not a new tree, and `element' would record children
       ;; against a fresh object.
       (add-child! box (tray-menu-button item class icon-size) #f))
     items)
    (set-visible-if-content box)
    (length items)))

(define (gtk-child-count widget)
  "How many children WIDGET actually has, according to GTK.

Not `%element-children': that records what `element' built, and this module adds
children with `add-child!' directly -- which is correct for a live rebuild but
leaves the element record empty.  Reading the record here reported an empty tray
that was in fact holding fifteen widgets."
  (let loop ((child (gtk-widget-get-first-child widget)) (n 0))
    (if child
        (loop (gtk-widget-get-next-sibling child) (+ n 1))
        n)))

(define (set-visible-if-content box)
  "Hide BOX when it holds nothing.

An empty tray must take no space at all: a padded empty box pushes the rest of
the bar along and looks like a rendering fault."
  (catch #t
    (lambda () (slot-set! box 'visible (> (gtk-child-count box) 0)))
    (lambda args #f)))

(define* (tray-widget #:key (class "tray") (item-class "tray-item")
                              (icon-size 16))
  "A system tray: every StatusNotifier item, each opening its own menu.

CLASS is the box's CSS class, ITEM-CLASS the per-item button's, ICON-SIZE the
icon pixels -- all three are a shell's decisions, which is why they are
arguments.

The tray is EMPTY for the first seconds of a process's life (measured: five
items arrive about two seconds in), so this subscribes to the items model rather
than reading it once.  A one-shot read produces a tray that never appears.

An empty tray hides itself, so it takes no space in a bar until something
registers."
  (let ((box (element <gtk-box> #:orientation 'horizontal #:class class)))
    (let ((t (catch #t (lambda () (tray)) (lambda args #f))))
      (when t
        (let ((model (catch #t (lambda () (slot-ref t 'items-model)) (lambda args #f))))
          (when model
            ;; items-changed fires with (position removed added).  The
            ;; arguments are not used: the tray is small enough to rebuild
            ;; whole, and reading them correctly is a source of off-by-one
            ;; bugs for no benefit at this size.
            (connect model 'items-changed
                     (lambda (m position removed added)
                       (catch #t
                         (lambda ()
                           (update-tray! box #:class item-class
                                              #:icon-size icon-size))
                         (lambda (key . args)
                           ;; Report the KEY AND the offending name.  A bare
                           ;; "rebuild failed: unbound-variable" cost a
                           ;; debugging round here: the name IS the message.
                           (format (current-error-port)
                                   "scheme-toolkit: tray: rebuild failed: ~a ~s~%"
                                   key args)))))))))
    (update-tray! box #:class item-class #:icon-size icon-size)
    box))
