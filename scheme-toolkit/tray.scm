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
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)

  ;; MANDATORY, and its absence is subtle.  With merge-generics, importing
  ;; (scheme-toolkit gi) MERGES GI's generics with Guile's own procedures of the
  ;; same name -- `connect' gains GObject signal methods alongside the socket
  ;; one, `append' gains GtkBox's, and so on.
  ;;
  ;; WITHOUT THIS DECLARATION the module keeps whatever `connect' Guile core
  ;; provides, so `(connect button 'clicked proc)' dispatches to the SOCKET
  ;; connect and fails with
  ;;
  ;;   Wrong type argument in position 1 (expecting open file port): #<gtk-button>
  ;;
  ;; which names a file port and mentions no signal, no widget and no module.
  ;; It works in every isolated test -- because those import (scheme-toolkit
  ;; widget) or (scheme-toolkit gi) first -- and fails only here.
  ;;
  ;; gi.scm and widget.scm both declare it; every module that imports gi AND
  ;; calls a merged name must too.
  #:duplicates (merge-generics replace warn-override-core warn last)

  #:export (tray-widget
            tray-items
            update-tray!
            tray-item-menu-labels
            item-menu-model
            refresh-menu!
            tray-item-action-report))

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
;;; Making an item's menu appear
;;; ---------------------------------------------------------------------------

;; DBusMenu items are populated LAZILY.  Before the host asks, a tray item's
;; model holds placeholder rows with no labels and no actions -- measured on
;; this machine: Syncthing's menu is 2 empty rows until AboutToShow, and 8 real
;; rows immediately after.  So a Gtk.PopoverMenu built from the model at
;; construction time shows an EMPTY menu, which is exactly what a user sees as
;; "the menu is broken".
;;
;; The host's contract is to call AboutToShow (com.canonical.dbusmenu) on the
;; item's menu path, wait for the reply, and only then show the menu.  ags2-shell
;; does this; so does every other tray host.
;;
;; NOT EVERY APPLICATION IMPLEMENTS IT.  Measured here: Syncthing and Insync
;; implement AboutToShow; JetBrains Toolbox and Chromium-style items do not (they
;; expose Event/GetLayout/GetGroupProperties only).  So the call is
;; best-effort -- it must not stop the menu appearing, and it must not hang.
;;
;; Asked with `gdbus' rather than Gio.DBusConnection.call_async.  The async GI
;; call needs a closure and a GAsyncReadyCallback, which is a lot of machinery
;; for a call whose answer we do not even read; `gdbus' is installed wherever a
;; StatusNotifier host runs, and the subprocess costs a few milliseconds once
;; per menu OPEN, not per frame.

(define (item-menu-address item)
  "ITEM's (BUS-NAME . OBJECT-PATH) for its dbusmenu, or #f.

The item id is \"<bus-name>/StatusNotifierItem\"; the menu path is a separate
property.  Both are needed and neither is derivable from the other."
  (let ((id (item-attr item 'item-id))
        (path (item-attr item 'menu-path)))
    (and (string? id) (string? path) (not (string-null? path))
         (let ((slash (string-index id #\/)))
           (and slash (> slash 0)
                (cons (substring id 0 slash) path))))))

(define (menu-about-to-show! item)
  "Ask ITEM's application to populate its menu now.  Returns #t if it answered.

Blocking, but only for as long as one dbus round trip -- and a tray menu is
opened by a click, not in a loop."
  (let ((address (item-menu-address item)))
    (if (not address)
        #f
        (catch #t
          (lambda ()
            (let* ((cmd (format #f "gdbus call --session --dest ~a --object-path ~a ~
--method com.canonical.dbusmenu.AboutToShow 0 2>/dev/null"
                                (car address) (cdr address)))
                   (p (open-input-pipe cmd))
                   (out (get-string-all p)))
              (close-pipe p)
              ;; The reply is "(false,)" or "(true,)"; a missing method gives
              ;; empty output, which is the common case and not an error.
              (and out (not (string-null? (string-trim out))) #t)))
          (lambda args #f)))))

(define (item-action-prefix item)
  "The prefix ITEM's actions are registered under.

A StatusNotifier item exports its actions under a namespace derived from its own
id -- ags2-shell uses `itemId` up to the first \"/\".  The menu's action
attributes are unprefixed names, and Gtk resolves them as PREFIX.NAME, so the
prefix is what makes them findable.  The empty string is not always right, which
is what made every row of a first attempt insensitive."
  (let ((id (item-attr item 'item-id)))
    (if (and (string? id) (not (string-null? id)))
        id
        "")))

;;; ---------------------------------------------------------------------------
;;; Rendering a menu model by hand
;;; ---------------------------------------------------------------------------
;;
;; Gtk.PopoverMenu DOES NOT WORK WITH THESE MODELS, which is why this section
;; exists.  A tray item's menu-model is a Gio.DBusMenuModel, and PopoverMenu
;; renders it as an empty popup -- measured: the model reports 8 items after
;; AboutToShow and the popover still shows nothing.  ags2-shell does not use
;; PopoverMenu for tray menus either; it walks the model and builds buttons.
;; This is that, in Scheme.
;;
;; The walk needs three things per item, each read as a GVariant:
;;
;;   (get-item-attribute-value MODEL INDEX ATTRIBUTE VARIANT-TYPE)
;;
;; The VARIANT-TYPE argument is where this is easy to get wrong.  Passing #f or
;; a plain string answers #f for every item -- silently, with real menu items
;; present -- and the natural conclusion is that the model has no labels.  It
;; must be a GVariantType, which G-Golf spells g-variant-type-new, and which
;; comes back as a <foreign> that works perfectly well.

(define %string-variant-type #f)

(define (string-variant-type)
  "A GVariantType for \"s\", created once.

Lazily, because the GLib typelib has to be required first, and at module load
that would cost every shell that never opens a tray menu."
  (unless %string-variant-type
    (g-irepository-require "GLib" #:version "2.0")
    (gi-import-by-name "GLib" "VariantType")
    (set! %string-variant-type (g-variant-type-new "s")))
  %string-variant-type)

(define (menu-attribute model index attribute)
  "MODEL's INDEX-th item's ATTRIBUTE as a string, or #f."
  (catch #t
    (lambda ()
      (let ((v (get-item-attribute-value model index attribute (string-variant-type))))
        (and v (g-variant-get-string v))))
    (lambda args #f)))

(define (menu-item-submenu model index)
  "The submenu MODEL under MODEL's INDEX-th item, or #f."
  (catch #t
    (lambda () (or (get-item-link model index "submenu")
                   (get-item-link model index "section")))
    (lambda args #f)))

;; A model that contains nothing but a single linked section is a WRAPPER: the
;; real menu is inside.  Gio.DBusMenuModel is shaped this way -- one item whose
;; section holds everything -- so a walk that does not unwrap it renders a
;; single row that opens the real menu, which is not what the application drew.
(define* (menu-unwrap model #:optional (depth 0))
  (if (> depth 4)
      model
      (let ((n (catch #t (lambda () (get-n-items model)) (lambda args 0))))
        (if (and (= n 1)
                 (not (menu-attribute model 0 "label"))
                 (menu-item-submenu model 0))
            (menu-unwrap (menu-item-submenu model 0) (+ depth 1))
            model))))

(define (action-name full-action)
  "FULL-ACTION with its prefix stripped: \"dbusmenu.id-10\" -> \"id-10\".

THE REASON CLICKING DID NOTHING.  A DBusMenu item's action attribute is
PREFIXED -- the model says \"dbusmenu.id-10\" -- while the action group exports
the bare name, \"id-10\".  Activating the prefixed name asks the group for an
action it does not have, and GActionGroup::activate_action does not raise when
the name is unknown: it does nothing at all.  So every row appeared, was
sensitive, was clickable, and silently did nothing.

ags2-shell strips it the same way (`action_name' in TrayMenu.tsx)."
  (let ((dot (and (string? full-action) (string-index full-action #\.))))
    (if dot (substring full-action (+ dot 1)) full-action)))

(define (menu-target model index)
  "MODEL's INDEX-th item's \"target\" attribute, or #f.

Needed because a radio or checkbox item carries its VALUE in the target, and
that is what decides whether the row shows a tick."
  (catch #t
    (lambda () (get-item-attribute-value model index "target" #f))
    (lambda args #f)))

(define (action-checked? group name target)
  "Does GROUP's NAME action consider TARGET its current state?

A boolean state is the simple case; a radio item's state is a string and is
compared against the target.  ags2-shell's is_checked, in Scheme."
  (if (not (and group name (has-action group name)))
      #f
      (catch #t
        (lambda ()
          (let ((state (get-action-state group name)))
            (cond
             ((not state) #f)
             ;; A string state (a radio group) equals its target; a boolean one
             ;; is simply true, or equal to a boolean target.
             ((string? state) (and target (equal? state (variant->value target))))
             (else (if target
                       (equal? state (variant->value target))
                       (eq? state #t))))))
        (lambda args #f))))

(define (variant->value v)
  "A GVariant's Scheme value, best-effort: string or boolean."
  (catch #t
    (lambda ()
      (cond ((string? v) v)
            ((not v) #f)
            (else (or (catch #t (lambda () (g-variant-get-string v)) (lambda a #f))
                      #t))))
    (lambda args #f)))

;;; ---------------------------------------------------------------------------
;;; Building the menu
;;; ---------------------------------------------------------------------------

(define %menu-budget 200)

(define* (append-model! box model group close! ancestors budget depth)
  "Append MODEL's rows to BOX.

A FAITHFUL PORT of ags2-shell's append_model, and the details are the whole
substance of it:

  A linked SECTION is not a row -- it is a separATOR and then its contents.
  That is where a tray menu's dividing rules come from, and skipping it (as an
  earlier version did) loses the line before Edit/Quit.

  A linked SUBMENU becomes a button that POPS OUT into its own popover on the
  right.  Rendering it inline is wrong: the application chose a submenu, and
  inline expansion also makes the parent menu jump about.

  BUDGET is shared across the whole recursion, so a runaway model cannot build
  unbounded widgets; ANCESTORS catches a model that links to itself."
  (if (or (> depth 16) (memq model ancestors) (<= budget 0))
      box
      (let ((ancestors (cons model ancestors))
            (n (catch #t (lambda () (get-n-items model)) (lambda args 0))))
        (let loop ((i 0) (budget budget))
          (if (or (>= i n) (<= budget 0))
              box
              (let ((section (catch #t (lambda () (get-item-link model i "section"))
                                    (lambda args #f))))
                (cond
                 (section
                  ;; A separator, but only between sections -- a leading rule at
                  ;; the top of the menu is not what the application drew.
                  (when (gtk-widget-get-last-child box)
                    (append box (make <gtk-separator> #:orientation 'horizontal)))
                  (append-model! box section group close! ancestors
                                 (- budget 1) (+ depth 1))
                  (loop (+ i 1) (- budget 1)))
                 (else
                  (let ((label (menu-attribute model i "label"))
                        (sub (menu-item-submenu model i)))
                    (cond
                     (sub
                      (when label
                        (append box (menu-submenu-button
                                     label sub group close! ancestors
                                     (- budget 1) depth))))
                     (label
                      (append box (menu-action-button model i label group close!))))
                    (loop (+ i 1) (- budget 1)))))))))))

(define (menu-action-button model index label group close!)
  "A button for a labelled menu item: ticked if checked, dimmed if disabled.

  SENSITIVE, not just clickable.  ags2-shell sets sensitivity from
  get_action_enabled, and without it a row the application has DISABLED --
  \"Show internal errors\" with no errors to show, on this machine -- renders as
  though it were available.  A greyed row is information; an apparently-enabled
  one that does nothing is a bug report.

  The tick comes from the action's STATE matching the item's target, which is
  how a radio menu shows which option is current."
  (let* ((action (menu-attribute model index "action"))
         (name (action-name action))
         (target (menu-target model index))
         (known (and group name (has-action group name)))
         (enabled (and known (catch #t (lambda () (get-action-enabled group name))
                                    (lambda args #t))))
         (checked (action-checked? group name target))
         (inner (make <gtk-box> #:orientation 'horizontal))
         (button (make <gtk-button> #:has-frame #f)))
    (gtk-widget-add-css-class button "model-item")
    ;; SEQUENCED, not used as a value.  `set-sensitive' is a void GTK method, so
    ;; G-Golf has it return ZERO values -- and `when', which wants one, raises
    ;; "Zero values returned to single-valued continuation" for the whole call.
    ;; Inside refresh-menu!'s catch that surfaced as "cannot build menu" and a
    ;; menu that never appeared at all.
    ;;
    ;; The same shape as gtk-window-set-interactive-debugging in known-issues:
    ;; a void C setter reached through Scheme where a value is expected.
    (when known
      (set-sensitive button (and enabled #t))
      #t)
    ;; The tick, before the label, as ags2-shell places it.
    (when checked
      (let ((check (make <gtk-image> #:icon-name "object-select-symbolic"
                                      #:valign 'center)))
        (gtk-widget-add-css-class check "check")
        (append inner check)))
    (append inner (make <gtk-label> #:label label #:xalign 0
                                   #:halign 'start #:hexpand #t
                                   #:use-underline #t))
    (set-child button inner)
    (connect-signal! button "clicked"
             (lambda (b)
               (cond
                ((not known)
                 ;; A label with no action is legitimate (a header, or something
                 ;; the application chose not to wire up).
                 #f)
                ((not enabled) #f)
                (else
                 (catch #t
                   (lambda () (activate-action group name target))
                   (lambda (key . args)
                     (format (current-error-port)
                             "scheme-toolkit: tray: action ~a failed: ~a ~s~%"
                             name key args)))))
               (when close! (close!))))
    button))

(define (menu-submenu-button label submodel group close! ancestors budget depth)
  "A button for a submenu, popping SUBMODEL out to the right.

POPS OUT, does not expand inline.  The application chose a submenu; inline
expansion changes the parent menu's height as you browse it, and it cannot
express a submenu that is itself a section of sections."
  (let* ((inner (make <gtk-box> #:orientation 'horizontal))
         (popover (make <gtk-popover>))
         (button (make <gtk-button> #:has-frame #f)))
    (gtk-widget-add-css-class button "model-item")
    (gtk-widget-add-css-class button "submenu")
    (append inner (make <gtk-label> #:label label #:xalign 0
                                   #:halign 'start #:hexpand #t
                                   #:use-underline #t))
    (append inner (make <gtk-image> #:icon-name "go-next-symbolic"
                                   #:valign 'center))
    (set-child button inner)
    (slot-set! popover 'has-arrow #f)
    (slot-set! popover 'position 'right)
    (catch #t (lambda () (set-parent popover button)) (lambda args #f))
    (let ((box (make <gtk-box> #:orientation 'vertical)))
      (gtk-widget-add-css-class box "tray-menu")
      (append-model! box submodel group
                     (lambda () (popdown popover) (when close! (close!)))
                     ancestors budget (+ depth 1))
      (set-child popover box))
    (connect-signal! button "clicked"
             (lambda (b)
               (catch #t (lambda () (popup popover)) (lambda args #f))))
    button))

(define* (build-menu-box model group close! #:optional (depth 0))
  "A Gtk.Box of rows for MODEL, or #f when there is nothing to show."
  (if (not model)
      #f
      (let* ((model (menu-unwrap model))
             (box (make <gtk-box> #:orientation 'vertical)))
        ;; The class ags2-shell puts on a menu box, and what its stylesheet
        ;; targets: `window#bar popover contents .tray-menu { min-width: ... }'
        ;; plus the padding rules for `button.model-item' and `separator'.
        (gtk-widget-add-css-class box "tray-menu")
        (append-model! box model group close! '() %menu-budget depth)
        box)))

(define* (tray-menu-button item #:optional (class "tray-item") (icon-size 16))
  "A button for ITEM: its icon, opening ITEM's application menu on click.

CLASS and ICON-SIZE are the caller's choices, which is why this is not
hard-coded: a bar's icon size and CSS class are that shell's decision.

A PLAIN Gtk.Button, not a Gtk.MenuButton.  Two reasons, both measured:

  - GtkMenuButton has NO `activate' signal, so a handler attached to one never
    runs.  The first version of this file connected `activate' to refresh the
    menu on click; it never fired, which is why the menu stayed empty.

  - GtkMenuButton wants a Gio.MenuModel and renders it with PopoverMenu, which
    cannot render a DBusMenuModel at all.

ags2-shell uses a plain button with a popover parented to it and an `onClicked'
handler, which is what this does."
  (let* ((group (item-attr item 'action-group))
         (popover (make <gtk-popover>))
         (button (make <gtk-button> #:has-frame #f)))
    (gtk-widget-add-css-class button class)
    ;; SEQUENCED, and this is the third instance of the same trap in this file.
    ;; `set-tooltip-text' is a void GTK method, so it returns ZERO values and
    ;; `when' -- which wants one -- raises "Zero values returned to
    ;; single-valued continuation" for the whole build.  The menu then never
    ;; appears, with an error that names no widget, no property and no line.
    ;;
    ;; The other two are set-sensitive and set-child below.  (Note
    ;; gtk-widget-add-css-class and append are void as well, but they sit in
    ;; statement position where the value is discarded and nothing complains.)
    (when (item-tooltip item)
      (set-tooltip-text button (item-tooltip item))
      #t)
    (set-child button (make <gtk-image> #:gicon (item-icon item)
                                        #:pixel-size icon-size))
    ;; The action group must be on an ANCESTOR of the buttons that reference
    ;; its actions -- the popover's contents are built inside it below, and the
    ;; popover is parented to the button, so the button is that ancestor.
    (when group
      (catch #t
        (lambda () (insert-action-group button (item-action-prefix item) group))
        (lambda (key . args)
          (format (current-error-port)
                  "scheme-toolkit: tray: cannot install action group: ~a ~s~%"
                  key args))))
    (slot-set! popover 'has-arrow #f)
    (catch #t (lambda () (set-parent popover button)) (lambda args #f))

    ;; Fill it now, and again on every press -- see refresh-menu!.
    (refresh-menu! popover item group)
    (connect-signal! button "clicked"
             (lambda (b)
               (catch #t
                 (lambda ()
                   (refresh-menu! popover item group)
                   (popup popover))
                 (lambda (key . args)
                   (format (current-error-port)
                           "scheme-toolkit: tray: cannot open menu: ~a ~s~%"
                           key args)))))
    button))

(define (refresh-menu! popover item group)
  "Fill POPOVER with ITEM's menu, asking the application to populate it first.

CALLED ON EVERY PRESS, not once at construction, and both halves are
load-bearing.  An earlier version had neither right, which produced a menu that
was empty in two independent ways:

  - WITHOUT AboutToShow the model still holds its placeholder rows -- measured:
    2 rows with no labels, then 8 real ones immediately after the call -- so the
    box built from it is empty;
  - WITHOUT the REBUILD the popover keeps whatever it was given at construction,
    which is that empty box, every time.

The second was the harder one to see: the builder was correct and
tray-item-menu-labels proved it, while the widget a user clicked showed nothing.

Separated from the popup so it can be TESTED without one.  Popping up a popover
whose button is not in a realized toplevel does not merely fail -- it segfaults
inside gdk_surface_new_popup -- so a test that had to call popup could not run
headless at all."
  (catch #t
    (lambda ()
      (menu-about-to-show! item)
      (let ((box (build-menu-box (item-menu-model item) group
                                 (lambda () (popdown popover)))))
        ;; Sequenced, for the same reason as set-sensitive above: set-child is a
        ;; void GTK method and `when' wants one value.
        (when box
          (set-child popover box))
        box))
    (lambda (key . args)
      (format (current-error-port)
              "scheme-toolkit: tray: cannot build menu: ~a ~s~%" key args)
      #f)))

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
            (connect-signal! model "items-changed"
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

;;; ---------------------------------------------------------------------------
;;; Diagnostics
;;; ---------------------------------------------------------------------------

(define (widget-labels widget)
  "Every label's text under WIDGET, in tree order.

RECURSIVE, because a menu row is button > box > label and a walk of direct
children finds nothing -- which is exactly how this helper first reported an
empty menu that was in fact built.

Folded with cons rather than `append': in this module `append' is GTK's
generic, so using it on two LISTS dispatches into GTK's dispatch and is only
saved by the core list method surviving the merge.  cons and reverse have no
such ambiguity."
  (if (not (is-a? widget <gtk-widget>))
      '()
      (let loop ((child (gtk-widget-get-first-child widget)) (out '()))
        (if (not child)
            (reverse out)
            (loop (gtk-widget-get-next-sibling child)
                  (cond ((is-a? child <gtk-label>)
                         (cons (catch #t (lambda () (slot-ref child 'label))
                                      (lambda args ""))
                               out))
                        (else
                         (let build ((rest (reverse (widget-labels child)))
                                     (acc out))
                           (if (null? rest)
                               acc
                               (build (cdr rest) (cons (car rest) acc)))))))))))

(define (tray-item-menu-labels item)
  "The labels ITEM's application menu would show, in order, or '().

For tests and for a shell that wants to log what a tray item offers.  It builds
the same box the popover gets, so it reports what a user would see rather than
what the model claims -- which is the distinction that mattered here: the model
reported 8 items while the popover showed nothing."
  (catch #t
    (lambda ()
      (menu-about-to-show! item)
      (let ((box (build-menu-box (item-menu-model item)
                                 (item-attr item 'action-group)
                                 (lambda () #f))))
        (if box (widget-labels box) '())))
    (lambda (key . args)
      (format (current-error-port)
              "scheme-toolkit: tray: cannot read menu: ~a ~s~%" key args)
      '())))

(define (tray-item-action-report item)
  "For ITEM's menu: one (LABEL ACTION RESOLVES?) per row.

RESOLVES? is whether the action group actually has the action the row names --
the check that was missing when every row was clickable and did nothing.  A
Gtk menu row is sensitive and clickable whether or not its action exists, and
GActionGroup::activate_action does not raise for an unknown name, so the only
symptom is that nothing happens.

Useful from a REPL on a tray item that does not respond."
  (catch #t
    (lambda ()
      (let* ((model (menu-unwrap (item-menu-model item)))
             (group (item-attr item 'action-group))
             (n (if model (get-n-items model) 0)))
        (let loop ((i 0) (out '()))
          (if (>= i n)
              (reverse out)
              (let ((label (menu-attribute model i "label"))
                    (action (menu-attribute model i "action")))
                (loop (+ i 1)
                      (if label
                          (cons (list label
                                      action
                                      (if (and group action
                                               (has-action group (action-name action)))
                                          #t
                                          #f))
                                out)
                          out)))))))
    (lambda (key . args)
      (format (current-error-port)
              "scheme-toolkit: tray: cannot report actions: ~a ~s~%" key args)
      '())))
