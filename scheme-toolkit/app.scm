;;; (scheme-toolkit app) -- turning a widget tree into a running shell
;;;
;;; The pieces here are the ones every layer-shell shell needs and every
;;; reference shell reimplements: an application to own the process, layer
;;; windows with anchors and an exclusive zone, one root per monitor with the
;;; right lifecycle when monitors come and go, and a small vocabulary of
;;; procedures for a keybinding or a test to call.
;;;
;;; The control surface is deliberately ordinary procedures -- `toggle-window',
;;; `quit', `inspect' -- rather than a protocol.  AGS needs a D-Bus interface
;;; with four verbs and a string switch because JavaScript cannot evaluate code
;;; in a running process from outside; Guile can, so a shell's vocabulary is
;;; just its exported procedures and a keybinding is one expression.
;;;
;;; Per-monitor lifecycle follows ags2-shell's shell/main.tsx: one reactive root
;;; per monitor, disposed when that monitor goes away, keyed by output name
;;; rather than by index so a hotplug does not shuffle the wrong roots.

(define-module (scheme-toolkit app)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (srfi srfi-11)          ; let-values -- create-state returns two
  #:use-module (ice-9 format)

  #:export (run-shell quit-shell
            app-instance
            layer-window window-set-anchored!
            window-visible?
            ;; NOT windows/windows-named/window-names/toggle-window/
            ;; destroy-windows!: the widget registry replaced them.  See the
            ;; note where the window registry used to be.

            on-window-toggle notify-window-toggled!
            create-window-root dispose-window-roots!
            dispose-monitor-roots!
            popup-window hide-popup! bar-popup-position
            popup-anchor! popup-anchor-centred! popup-anchor popup-anchored!
            popup-place-under!
            popup-available-height
            set-window-edge-box!
            panel-anchor! panel-button
            <desktop-widget> <widget-class> <bar-item-widget>
            widget-config-slots widget-slot-ref widget-config-tick
            widget-apply-options! widget-apply-option! widget-scope
            config-descriptor-validator widget-label
            <window-widget> <popup-widget> <edge-widget>
            widget-name widget-build widget-window-name
            widget-section mark-item-section!
            widget-window widget-windows widget-show! widget-hide!
            widget-toggle! widget-visible? widget-destroy-windows!
            widget-decommission! widgets-decommission!
            widget-registry-changed! widgets-registry-changed!
            toggle-widget shell-windows
            register-desktop-widget! desktop-widgets desktop-widget-names
            desktop-widget-named desktop-widget-required
            unregister-desktop-widgets! unregister-desktop-widget!
            ;; the root: the one widget that owns which widgets are live
            <root-desktop-widget> root-widgets root-widgets-set! root-sync! root-start!
            widget-class-named widget-short-name
            widget-qualified-name widget-qualified-name-set!
            widget-name-from-class-name
            monitors for-each-monitor monitor-name monitor-geometry
            on-monitors-changed
            inspect
            unset-layer-shell-preload!))

(define-gi-imports "Gtk" "Application" "Window" "Settings" "Button"
                   "Revealer" "Widget" "EventControllerKey" "GestureClick")
(define-gi-imports "Gdk" "Display" "Monitor")
;; connector, for monitor-name. Re-imported here so the name is bound in THIS
;; module, which is where it is called.
(define-gi-imports "Gdk" "Monitor")
(define-gi-imports "Astal" "Window")

;;; ---------------------------------------------------------------------------
;;; State
;;; ---------------------------------------------------------------------------

(define %app #f)

;; The registry is a LIST of (name . window), not a name-keyed table.
;;
;; A table keyed by name looks right and is wrong: a per-monitor bar registers
;; under the same name once per monitor, so each one silently replaced the last
;; and only the final monitor got a bar.  Nothing errors -- the surface count is
;; just short.  Keeping every registration lets several windows share a name,
;; which is exactly what per-monitor bars need.

(define %monitor-roots (make-hash-table)) ; monitor name -> dispose

(define (app-instance) %app)

;;; ---------------------------------------------------------------------------
;;; Environment hygiene
;;; ---------------------------------------------------------------------------

;; GLib.unsetenv("LD_PRELOAD") immediately after Gtk.init().
;;
;; The layer-shell library must be preloaded into THIS process, but every child
;; it launches inherits LD_PRELOAD, and a text editor or a terminal started
;; from a shell menu would then load libgtk4-layer-shell into its own GTK --
;; which either does nothing or misbehaves, and is very hard to trace back here.
;; AGS does this at lib/gtk4/app.ts:21 and colorshell at app.ts:125.
;;
;; Guile's own `unsetenv', not a GLib import: G-Golf binds GLib's as the bare
;; name `unsetenv', which is the binding Guile already has, and the import
;; would shadow it for no gain.  Guile's version also updates the environment
;; children actually inherit -- verified with `printenv' in a pipe.
(define (unset-layer-shell-preload!)
  (catch #t
    (lambda () (unsetenv "LD_PRELOAD") #t)
    (lambda args #f)))

;;; ---------------------------------------------------------------------------
;;; Layer windows
;;; ---------------------------------------------------------------------------

;; `window-toggled': the signal AGS's App class emits so that a panel button can
;; follow the window it opens without polling it.
;;
;; AGS connects `notify::visible' on every window it adds and re-emits as one
;; app-level signal (lib/gtk4/app.ts).  Every window this toolkit registers gets
;; the same connection in `layer-window', so a window hidden by its own Escape
;; handler or by a click outside updates its button exactly like one hidden by
;; `toggle-window'.
;;
;; This is a plain list of procedures rather than a GObject signal because the
;; emitters are our own windows and the subscribers are our own widgets -- there
;; is nothing here a foreign language needs to connect to.
(define %window-toggle-hooks '())

(define (on-window-toggle name proc)
  "Call PROC whenever a window named NAME is shown or hidden.

PROC is passed the window, like AGS's `window-toggled' handler, and reads
`visible' itself -- the panel button needs the current state, not a delta.

Returns a procedure that removes the hook, and registers it with `on-cleanup'
so a rebuilt button stops listening."
  (let ((hook (cons name proc)))
    (set! %window-toggle-hooks (cons hook %window-toggle-hooks))
    (let ((stop (lambda ()
                  (set! %window-toggle-hooks
                        (delq! hook %window-toggle-hooks))
                  #t)))
      (on-cleanup stop)
      stop)))

(define (notify-window-toggled! win)
  "Tell every hook about WIN's new visibility."
  (let ((name (catch #t (lambda () (slot-ref win 'name)) (lambda args #f))))
    (for-each (lambda (hook)
                (when (equal? (car hook) name)
                  (catch #t (lambda () ((cdr hook) win)) (lambda args #f))))
              %window-toggle-hooks)))

(define* (layer-window name #:key
                       (anchor '(top left right))
                       (exclusivity 'exclusive)
                       (layer 'top)
                       (keymode 'none)
                       (gdkmonitor #f)
                       (namespace #f)
                       (class "Shell")
                       (margins #f)         ; (top right bottom left), or #f
                       ;; Whether the window is shown when the shell starts.
                       ;; A bar wants #t; a popup wants #f, and #f is what keeps
                       ;; `run-shell' from presenting it -- a popup that is
                       ;; presented at startup is a popup that is open at
                       ;; startup.
                       (visible #t)
                       (on-clicked #f)
                       ;; #:rest, so children can be written positionally after
                       ;; the keywords as they are in `element'.  A plain #:key
                       ;; rejects a trailing positional child outright -- "Invalid
                       ;; keyword" -- because everything after the first keyword
                       ;; must be a keyword when there is no rest argument.
                       #:rest children)
  "An Astal.Window configured as a layer surface.

  (layer-window \"bar\" #:anchor '(top left right) #:exclusivity 'exclusive
    (centerbox ...))

ANCHOR is a list of edges: a bar is `(top left right)'.  EXCLUSIVITY
'exclusive makes the compositor reserve the space; 'ignore lets it float over
other windows, which is what a popup wants.

The window is NOT presented here -- `run-shell' presents the registered windows
on the application's activate, which is the only point at which a GtkApplication
may have windows added."
  (let* ((args (append
                (list #:name name #:anchor anchor #:exclusivity exclusivity
                      #:layer layer #:keymode keymode
                      #:application %app #:class class #:visible visible)
                (if gdkmonitor (list #:gdkmonitor gdkmonitor) '())
                (if namespace (list #:namespace namespace) '())
                (if margins
                    (list #:margin-top (list-ref margins 0)
                          #:margin-right (list-ref margins 1)
                          #:margin-bottom (list-ref margins 2)
                          #:margin-left (list-ref margins 3))
                    '())
                (if on-clicked (list #:on-clicked on-clicked) '())))
         (win (apply element <astal-window> (append args children))))
    ;; NOTHING IS REGISTERED HERE.  A window belongs to the WIDGET that made
    ;; it -- the bar records each monitor's through `widget-windows', a popup
    ;; returns its own -- so the widget registry is the only place anything is
    ;; looked up, and this function is a constructor and nothing else.
    ;; The one place a window's visibility can change is the compositor setting
    ;; `visible', whether that came from a widget being toggled, from a popup's
    ;; own Escape handler, or from the window being destroyed.  Watching the
    ;; property catches all three.
    (catch #t
      (lambda ()
        (connect-signal! win "notify::visible"
                         (lambda args (notify-window-toggled! win))))
      (lambda args #f))
    win))

(define (window-set-anchored! win anchor)
  "Set a window's anchor after construction, which is how a bar changes edge."
  (catch #t (lambda () (slot-set! win 'anchor anchor)) (lambda args #f))
  win)

(define (window-visible? w)
  "Whether the WINDOW W is visible.  About a window, not a widget -- use
`widget-visible?' to ask about a widget."
  (catch #t (lambda () (slot-ref w 'visible)) (lambda args #f)))

;; THE WINDOW REGISTRY IS GONE.  It answered "what windows exist?", and every
;; window belongs to a widget: the bar records one per monitor through
;; `widget-windows', a popup returns its own.  So the widget registry answers it,
;; by walking the widgets -- `shell-windows' below -- and there is no second
;; table to keep in step.
;;
;; What used to be here, and what replaces it:
;;
;;   (windows-named name)  ->  (widget-windows (desktop-widget-named name))
;;   (windows)             ->  (shell-windows)
;;   (window-names)        ->  (desktop-widget-names), filtered if you want
;;                             only the ones with windows
;;   (toggle-window name)  ->  (toggle-widget name)
;;   (destroy-windows! n)  ->  (widget-destroy-windows! widget)
;;
;; `window-visible?' stays because it is a question about a window object, and
;; the two callers that legitimately have one -- a panel button tracking its
;; panel, and `describe-state' -- want exactly that.

;;; ---------------------------------------------------------------------------
;;; Monitors
;;; ---------------------------------------------------------------------------

(define (display-monitors)
  (catch #t
    (lambda ()
      (let ((model (gdk-display-get-monitors (gdk-display-get-default))))
        (let loop ((i 0) (out '()))
          (if (< i (get-n-items model))
              (loop (+ i 1) (cons (get-item model i) out))
              (reverse! out)))))
    (lambda args '())))

(define (monitors)
  "Every connected monitor, in Gdk's order."
  (display-monitors))

(define (monitor-geometry mon)
  "A monitor's geometry as a list (x y width height).  G-Golf turns the Gdk
struct into a list, so no struct access is needed."
  (catch #t
    (lambda () (gdk-monitor-get-geometry mon))
    (lambda args '(0 0 1920 1080))))

(define (monitor-name mon)
  "A stable identity for a monitor.

The Wayland CONNECTOR -- eDP-1, HDMI-A-1 -- so that a bar can be keyed by
connector rather than by an index that shifts when a monitor is unplugged, and
so that the name matches what Hyprland calls the same monitor.

`gdk_monitor_get_connector', which is GDK 4.10+. The plan called for
`AstalWl4.find_output_by_gdk_monitor', and that namespace does not exist here:
the typelib is `AstalWl-0.1' and it has no such function. GDK answers the same
question directly, with no extra typelib and no second source of truth.

Falls back to the geometry, which is at least stable while the monitor is
attached."
  (or (catch #t (lambda () (gdk-monitor-get-connector mon)) (lambda args #f))
      (let ((g (monitor-geometry mon)))
        (format #f "~a:~a" (list-ref g 2) (list-ref g 3)))))

(define (on-monitors-changed proc)
  "Call PROC whenever the monitor list changes.  Returns a procedure that stops
the watch.

Hooked to Gdk.Display's `items-changed', which is the GListModel signal -- the
same thing AGS listens to.  This is the whole of monitor hotplug support: a
shell disposes the roots for monitors that went away and builds roots for the
ones that arrived."
  (let* ((model (gdk-display-get-monitors (gdk-display-get-default)))
         (id (connect model 'items-changed
                      (lambda (m pos removed added) (proc)))))
    (lambda ()
      (catch #t (lambda () (disconnect model id)) (lambda args #f)))))

(define* (for-each-monitor proc #:key (force? #f))
  "Call PROC with each connected monitor, keyed so that a monitor coming back
keeps its identity.

FORCE? rebuilds even for a monitor that already has a root, disposing the old
one first.  A rebuild needs it: it destroys the windows and calls this again,
and without the override every monitor counts as already done and nothing is
built.

PROC is called as (proc monitor name).  Whatever PROC creates belongs to a root
registered under NAME, so calling this again after a hotplug rebuilds only what
changed: roots for monitors that are still present are left alone, roots for
monitors that have gone are disposed."
  (let ((seen (make-hash-table)))
    (for-each (lambda (mon)
                (let ((name (monitor-name mon)))
                  (hash-set! seen name #t)
                  ;; Rebuild only when it really is new: rebuilding a bar whose
                  ;; monitor has not moved is wasted work and a visible flicker.
                  ;;
                  ;; FORCE? overrides that.  A rebuild destroys the windows and
                  ;; then calls this again, and without the override nothing is
                  ;; built: the roots still exist, so every monitor is treated as
                  ;; already done and the shell is left with no bar at all --
                  ;; silently, because "monitor already has a root" is an
                  ;; ordinary state, not an error.
                  (when (or force? (not (hash-ref %monitor-roots name)))
                    (when force?
                      (let ((old (hash-ref %monitor-roots name)))
                        (when old (catch #t (lambda () (old)) (lambda args #f)))))
                    (let ((dispose
                           (create-root
                            (lambda (_dispose)
                              (proc mon name)))))
                      (hash-set! %monitor-roots name dispose)))))
              (display-monitors))
    ;; Dispose roots whose monitor is gone.
    (for-each (lambda (pair)
                (unless (hash-ref seen (car pair))
                  (catch #t (lambda () ((cdr pair))) (lambda args #f))
                  (hash-remove! %monitor-roots (car pair))))
              (hash-map->list (lambda (k v) (cons k v)) %monitor-roots))
    (hash-count (const #t) %monitor-roots)))

;;; ---------------------------------------------------------------------------
;;; Standing roots for windows that are not per-monitor
;;; ---------------------------------------------------------------------------
;;
;; A shell has two kinds of window.  The per-monitor ones (bars) get a root per
;; monitor from `for-each-monitor', so a hotplug builds and disposes them.  The
;; other kind -- popups, a launcher, a control centre -- exists once, follows the
;; focused monitor, and lives as long as the shell does.
;;
;; THEY STILL NEED A SCOPE.  Every binding a widget creates registers its
;; cleanup with `on-cleanup' in the enclosing scope, and a widget built outside
;; one gets "on-cleanup called outside a scope; it will never run" and then
;; leaks its signal handlers for the life of the process.  The warning is the
;; visible half; the leak is the real one.

(define %standing-roots '())

(define (create-window-root proc)
  "Run PROC inside a fresh reactive root that stays alive until the shell exits.

Returns whatever PROC returns, so a caller can do

    (create-window-root (lambda () (make-the-window)))

and get the window.  `create-root' returns its DISPOSE instead -- `for-each-monitor'
depends on that -- so the value is carried out through one local box rather than
by changing that contract."
  (let ((result #f))
    (create-root
     (lambda (dispose)
       (set! %standing-roots (cons dispose %standing-roots))
       (set! result (proc))))
    result))

(define (dispose-monitor-roots!)
  "Dispose every per-monitor root and forget them.

ORDER MATTERS, AND THIS IS THE ORDER. A root's cleanups are mostly signal
disconnects and child removals, and they need their widgets ALIVE. A rebuild
that destroys the windows first and disposes the roots afterwards asks GLib to
disconnect a handler on a freed object:

    GLib-GObject-CRITICAL: instance with invalid (NULL) class pointer
    GLib-GObject-CRITICAL: g_signal_handler_disconnect: assertion failed

which takes the shell down. Every layout option goes through this path, so the
first live change to one of them (a moved bar, a rescaled shell) killed it."
  (for-each (lambda (pair)
              (catch #t (lambda () ((cdr pair))) (lambda args #f)))
            (hash-map->list (lambda (k v) (cons k v)) %monitor-roots))
  (set! %monitor-roots (make-hash-table))
  #t)

(define (dispose-window-roots!)
  "Dispose every standing root, and forget them.  For a full rebuild."
  (for-each (lambda (dispose) (catch #t dispose (lambda args #f)))
            %standing-roots)
  (set! %standing-roots '())
  #t)

;;; ---------------------------------------------------------------------------
;;; Starting
;;; ---------------------------------------------------------------------------

(define (inspect)
  "Open GTK's interactive inspector on the running shell.

The binding is gtk-window-set-interactive-debugging, NOT
set-interactive-debugging: G-Golf names a namespace function after its C
identifier with the prefix kept.  The wrong name raised inside this procedure's
catch and was reported as \"cannot open the inspector\", so the inspector looked
broken rather than misspelt.  It also returns NO values, which is why the call is
sequenced with begin rather than followed by one."
  (catch #t
    (lambda ()
      (begin (gtk-window-set-interactive-debugging #t) #t))
    (lambda (key . args)
      (format (current-error-port) "scheme-toolkit: cannot open the inspector: ~a ~s~%"
              key args)
      #f)))

(define* (run-shell #:key (instance "shell") (main #f) (repl? #t))
  "Run a shell.

Named run-shell rather than start because G-Golf generates a generic named after
each GI method it imports, and `start' is one of them (Gtk.Spinner has
start and stop).  A module that imports GTK classes therefore cannot export a
bare `start': the two merge into a single generic and the call then fails with
a no-applicable-method error.  The same caution applies to stop, show and hide.

INSTANCE becomes the application id, io.Astal.<instance>, and the name the REPL
socket is keyed by.  MAIN is called once the application is activated and the
window system is ready -- building windows before that is not allowed, which is
why this takes a thunk rather than a widget.

Starts the REPL *before* MAIN, so a shell that fails during startup can still be
inspected from outside rather than only from a backtrace.

  (run-shell #:instance \"my-shell\"
         #:main (lambda () (for-each-monitor (lambda (mon name) (build-bar mon)))))

Returns the application's exit status."
  (assert-environment)
  ;; Gtk.init happens inside gtk-bootstrap!, and must precede any widget.
  (gtk-bootstrap!)
  (unset-layer-shell-preload!)
  (set! %app (make <gtk-application>
                   #:application-id (string-append "io.Astal." instance)))
  ;; A second launch must not become a rival shell owning the same id.
  ;;
  ;; `g-application-register', NOT `register'.  `register' here resolved to
  ;; GOOPS's own generic, which has no method for <gtk-application>, so this
  ;; check raised "No applicable method" on EVERY start -- and the `catch'
  ;; around it turned that into #f, which reads exactly like "not already
  ;; running".  The guard therefore never once fired: a second launch built a
  ;; full set of windows for an application that is not the primary owner, and
  ;; GTK said so three times --
  ;;
  ;;   Gtk-CRITICAL: New application windows must be added after the
  ;;   GApplication::startup signal has been emitted.
  ;;
  ;; A remote instance never gets `startup', so every window it adds is wrong.
  ;; Checked AFTER registering, because that is what decides it: the second
  ;; instance registers fine, as a remote.
  (let ((registered?
         (catch #t (lambda () (g-application-register %app #f)) (lambda args #f))))
    (unless registered?
      (format (current-error-port)
              "scheme-toolkit: cannot register ~a~%" instance)
      (exit 1))
    (when (catch #t (lambda () (g-application-get-is-remote %app)) (lambda args #f))
      (format (current-error-port)
              "scheme-toolkit: ~a is already running; use `scheme-toolkit eval' to talk to it~%"
              instance)
      (exit 0)))
  ;; activate fires once when the application comes up, and again if a second
  ;; launch reaches it; the guard keeps the second one from building a second
  ;; set of bars.
  (let ((built? #f))
    (connect %app 'activate
             (lambda (a)
               (unless built?
                 (set! built? #t)
                 (when repl? (try-start-repl! instance))
                 (when main (main))
                 ;; Present everything registered, now that a window may exist.
                 ;;
                 ;; A failure here is REPORTED, not swallowed.  It was silent
                 ;; once and cost an hour: the windows were built, no surface
                 ;; appeared, and there was nothing in the log to say why.  A
                 ;; window that cannot be presented is always a bug worth
                 ;; seeing.
                 (for-each
                  (lambda (w)
                    ;; ONLY THE WINDOWS THAT ASKED TO BE SHOWN.  A popup is
                    ;; registered like any other window, and presenting them
                    ;; all is how the date menu came up already open.
                    (when (window-visible? w)
                      (catch #t
                        (lambda () (present w))
                        (lambda (key . args)
                          (format (current-error-port)
                                  "scheme-toolkit: cannot present window ~s: ~a ~s~%"
                                  (catch #t (lambda () (slot-ref w 'name)) (lambda a '?))
                                  key args)))))
                  (shell-windows))))))
  (run %app '()))

(define (try-start-repl! instance)
  "Start the back door if (scheme-toolkit repl) is loadable.

Resolved at run time rather than imported, so that a shell works even when that
module is not on the load path -- it is a development affordance, not a
dependency.

resolve-interface, NOT resolve-module.  resolve-module does not LOAD a module
from disk; with its default #:ensure #t it hands back a fresh empty one, and with
#:ensure #f it returns #f for anything not already loaded.  Both look like
\"the module is missing\", so the REPL silently never started.  resolve-interface
is what use-modules itself uses, and it loads."
  (catch #t
    (lambda ()
      (let ((iface (resolve-interface '(scheme-toolkit repl))))
        ;; `#:name', WHICH THE SHARED MODULE CALLS IT.  `#:instance' was this
        ;; toolkit's word for the same thing; the module that owns the socket
        ;; naming chose the one a program reading it cold would guess, and this
        ;; is the only call site.
        ((module-ref iface 'start-repl!) #:name instance)
        ;; Remove the socket on the way out.  Without this the file outlives
        ;; the process, `scheme-toolkit list' has to label it "(stale)", and
        ;; anything that checks for the file rather than for a listener --
        ;; including the shell's own live tests -- mistakes it for a running
        ;; shell.
        (let ((stop (module-ref iface 'stop-repl!)))
          (connect %app 'shutdown (lambda (a) (catch #t stop (lambda args #f)))))))
    (lambda (key . args)
      (format (current-error-port) "scheme-toolkit: REPL not started: ~a ~s~%"
              key args)
      #f)))

(define* (quit-shell #:optional (status 0))
  "Ask the application to exit.  Safe to call before run-shell.

Named quit-shell for the same reason run-shell is not start: G-Golf generates a
generic named after each GI method, and `quit' is one of them."
  (when %app
    (catch #t (lambda () (g-application-quit %app)) (lambda args #f)))
  status)

;;; ---------------------------------------------------------------------------
;;; Popup windows
;;; ---------------------------------------------------------------------------
;;
;; The pattern every shell reimplements: a full-screen layer surface anchored to
;; all four edges with exclusivity IGNORE, whose content sits in one corner and
;; which closes on Escape or a click outside itself.
;;
;; ANCHORED TO ALL FOUR EDGES, with the content aligned inside, rather than a
;; small window placed at a coordinate.  That is how ags2-shell and colorshell
;; both do it, and it is what makes "click outside to close" possible at all: a
;; window the size of its content has no outside to click.

(define %popup-positions
  ;; position -> (halign valign), copied from ags2-shell's `position_config' in
  ;; widget/shared/PopupWindow.tsx -- except that ags2-shell's third column, the
  ;; TRANSITION, is gone.  It slid a popup in from the edge it hangs off, which
  ;; reads as coming out of the bar when the popup is small and near the bar --
  ;; and as falling out of the top of the SCREEN when it is not, which is what a
  ;; panel opened from a button actually looks like: the button is what it came
  ;; from, and the button is nowhere near the screen's edge.  A popup appears
  ;; instantly unless its caller asks for something else (`#:transition').
  ;; (position halign valign), as a LIST and not a dotted pair: `(a . (b c))'
  ;; IS `(a b c)', so a dotted entry here would hand back a list where a symbol
  ;; was wanted -- `(cdr config)' would be `(start)' rather than `start', and
  ;; GTK answers that with "no applicable method for g-value-set-enum".
  '((center        center center)
    (top-left      start  start)
    (top-center    center start)
    (top-right     end    start)
    (center-left   start  center)
    (center-center center center)
    (center-right  end    center)
    (bottom-left   start  end)
    (bottom-center center end)
    (bottom-right  end    end)))

(define (popup-position-config position)
  (or (assoc-ref %popup-positions position)
      (assoc-ref %popup-positions 'center)))

(define* (bar-popup-position #:key (bar 'bar) (horizontal 'center))
  "The position a panel opens at when it hangs off the BAR's edge.

THE VERTICAL HALF COMES FROM THE BAR and the horizontal half from the panel's own
option.  This is ags2-shell's `create_popup_position', which takes the two
accessors and joins them, and it is the whole of what a panel needs to know about
where the bar is: a bar on the top edge with a 'center panel opens at
'top-center -- OUT FROM the bar rather than over it.

The bar is looked up in the registry rather than imported, because the bar imports
the panels and a panel importing it back is a cycle.  A shell with no bar, or a
bar that does not say where it is, gets 'top-center.

THE HORIZONTAL HALF IS STILL THE PANEL'S, and it is not decoration even though a
panel opened from a button is PLACED by that button: it is what a panel opened
without one -- from a keybinding, from the REPL -- falls back to."
  ;; ONLY THE LAST COMPONENT OF EACH is kept, which is ags2-shell's rule and the
  ;; reason either half may be given in full: a bar says `top' or `bottom-left',
  ;; and a panel's option says `center' or `top-center', and the answer is the
  ;; bar's vertical with the panel's horizontal whatever the wrappers were.
  (let* ((bar-widget (desktop-widget-named bar))
         (edge (and bar-widget
                    (catch #t (lambda () (slot-ref bar-widget 'position))
                           (lambda args #f)))))
    (if edge
        (string->symbol
         (string-append (last-dash-component edge)
                        "-" (last-dash-component horizontal)))
        'top-center)))

(define (last-dash-component sym)
  "The part of SYM after its last `-': `top-left' -> \"left\", `top' -> \"top\"."
  (let ((parts (string-split (symbol->string sym) #\-)))
    (car (reverse parts))))

;;; --- where a panel opens ---------------------------------------------------
;;
;; UNDER THE BUTTON THAT OPENED IT, and starting below the bar rather than over
;; it.  The button is the only thing that knows either fact -- it can measure
;; itself, and its toplevel IS the bar -- so the button works out where it is and
;; records it, and the panel reads the record when it opens.
;;
;; RECORDED AND NOT CALLED, because the panel may not exist yet: the bar's
;; buttons are built while the bar is assembled, and the panels are built after.
;; There is nothing for a button to call, so it leaves a note instead.  The note
;; is keyed by the NAME THE PANEL'S WINDOW CARRIES, which is the same name
;; `panel-button' follows its window's visibility by.

;;; --- where the bar actually is ---------------------------------------------
;;
;; NOT A THING GDK KNOWS.  GDK tells a window its SIZE and never its position: a
;; layer surface's place is the compositor's decision and there is no API to ask
;; for it.  So the toolkit asks the SHELL, which knows its own compositor, and
;; this parameter is that seam: a procedure of `(monitor-name width height)'
;; answering the bar surface's `(x y width height)` on that monitor, or #f.
;;
;; IT IS NEEDED BECAUSE EXCLUSIVE SURFACES STACK.  Two bars on the same edge do
;; not both sit at the edge: the compositor pushes the second one along, so the
;; bar's HEIGHT stops being the distance from the edge to the bar.  Measured on
;; this machine with three bars on the top edge: ours is 45 tall at y=82, and a
;; panel placed at 46 -- its height -- covered the two bars above it instead of
;; starting below ours.
;;
;; THE WIDTH AND HEIGHT ARE PASSED because they are how the shell recognises the
;; surface: a layer surface cannot be given a name (setting one on this machine
;; makes the bar never appear at all -- see the note in the shell's bar), so the
;; bar is found by its process and its size.
;;
;; #f means "the shell cannot say", and the answer falls back to the window's own
;; height plus its margin, which is exact when the bar is the only thing on that
;; edge and wrong in the same way this is fixing when it is not.
(define %window-edge-box (make-parameter #f))

(define (set-window-edge-box! proc)
  "Tell the toolkit how to find the bar's place on a monitor.

PROC takes a monitor name and the bar window's width and height, and returns the
bar surface's `(x y width height)` on that monitor in the same pixels GDK uses,
or #f.  The toolkit turns that into the clearance a panel needs -- the bar's far
edge, measured from the edge of the screen the bar is anchored to."
  (%window-edge-box proc))

(define %popup-anchors (make-hash-table))

;; A NOTE THE OPENER LEAVES, not a question the panel asks.  The thing that opens
;; a panel is the thing that knows where it should appear -- a bar button is in
;; the bar and knows its section, a keybinding is not in the bar at all -- and it
;; says so here, on its way to showing the panel.  The panel reads the note and
;; does what it says; it never goes looking for anybody to ask.
;;
;; TWO THINGS AN OPENER CAN SAY, and that is why the note has a KIND:
;;
;;   (bar SECTION CLEARANCE MONITOR BAR-BOX)  -- hang off the bar: aligned to
;;   SECTION of it and starting at its far edge.  What a bar button says.
;;
;;   (centred MONITOR)                        -- in the middle of the screen.
;;   What a keybinding says, because it came from the keyboard and not from the
;;   bar, so hanging it off the bar would point at something that had no part in
;;   opening it.

(define (popup-anchor! name section edge clearance monitor bar-box)
  "Record that NAME's panel belongs UNDER THE BAR: in SECTION of it, on MONITOR.

EDGE is `top' or `bottom' -- the side of the screen the bar hangs off, which the
opener knows because it is in the bar.  THE PLACEMENT SETS EVERYTHING IT USES and
so does the other kind of note, because one panel can be opened both ways: the
menu is placed under the bar when the button opens it and centred when a
keybinding does, and whichever ran last would otherwise leave its alignment behind
-- a menu centred once stayed vertically centred when it was next placed under the
bar, which puts it in the middle of the screen rather than under the bar.

SECTION is `left', `center' or `right' -- the part of the bar the button that
opens it lives in.  CLEARANCE is the distance from the screen edge the bar hangs
off to the bar's far edge, in the panel window's own coordinates (which are the
screen's, since a popup is anchored to all four edges and fills it).  MONITOR is
the one the bar is on, so the panel opens on the same screen the button was
clicked on rather than on whichever screen the popup happened to be made on.
BAR-BOX is the bar surface's `(x y width height)', or #f when the shell could not
say -- the horizontal alignment is measured from it when it is there.

A RECORD, NOT A CALL: the panel may not be built yet."
  (hash-set! %popup-anchors name (list 'bar section edge clearance monitor bar-box))
  name)

(define (popup-anchor-centred! name monitor)
  "Record that NAME's panel belongs IN THE MIDDLE OF MONITOR.

WHAT AN OPENER WITH NO BAR TO POINT AT SAYS.  A keybinding opens the menu without
touching the bar, so aligning the menu to a bar button would point at the wrong
thing -- the gesture came from the keyboard -- and the honest place for it is the
middle of the screen.

MONITOR is which screen that middle is on: a popup is one window and follows the
focused monitor rather than existing on every one, so this is the shell's answer
to `where is the user looking' and not a question the panel can answer."
  (hash-set! %popup-anchors name (list 'centred monitor))
  name)

(define (popup-anchor name)
  "Where NAME's panel was last opened from, or #f.  See `popup-anchor!'."
  (hash-ref %popup-anchors name))

(define (popup-available-height win)
  "How much vertical room WIN's content has before it reaches the screen's edge.

THE SAME NUMBER WHICHEVER EDGE THE POPUP HANGS FROM, which is why it is one
function: the clearance a panel is placed at is measured from the edge it hangs
off, so the room it leaves is the screen less that either way.

FOR A CONTENT THAT SIZES ITSELF, which is what a menu wants: it should show its
twenty rows on a tall screen and only start scrolling when the rows do not fit,
and the number to cap it at is this one rather than a guess like `about ten rows'.

#f when there is nothing to measure against -- no monitor yet, which is a window
that has not been placed -- and the caller keeps whatever cap it had."
  (let* ((name (catch #t (lambda () (slot-ref win 'name)) (lambda args #f)))
         (anchor (and name (hash-ref %popup-anchors name)))
         ;; A CENTRED PANEL HAS THE WHOLE SCREEN: nothing is hanging over it.
         (clearance (and anchor (eq? (car anchor) 'bar) (list-ref anchor 3)))
         (monitor (or (and anchor (if (eq? (car anchor) 'bar)
                                      (list-ref anchor 4) (cadr anchor)))
                      (catch #t (lambda () (slot-ref win 'gdkmonitor))
                             (lambda args #f))))
         (geom (and monitor (catch #t (lambda () (monitor-geometry monitor))
                                   (lambda args #f)))))
    (and (list? geom) (= 4 (length geom))
         (- (list-ref geom 3) (if (number? clearance) clearance 0)))))

(define (panel-anchor! btn widget align)
  "Note where WIDGET's panel should open: in ALIGN, under BUTTON's bar.

CALLED ON THE CLICK, NOT AT BUILD.  Where the button is is a fact about the
moment -- the bar may have moved to the other edge, or to another monitor, and
the button's section changed with the layout -- and the panel is placed from the
note when it opens, so the first frame is already in the right place.

NO COORDINATES ARE TAKEN FROM THE BUTTON, and that is the lesson of the first
version of this: it measured the button's centre and put the panel's centre
there, which needs the panel's WIDTH, which is not settled until the panel has
been laid out once.  Measured on this machine, the answer moved with the placing
-- the datemenu's width alternated between 1225 and 1169 -- so the same panel
opened centred, then off-centre, then centred again.  A section is enough to say
what the panel should do and does not move.

THE BUTTON'S TOPLEVEL IS THE BAR, so one call gives everything the placement
needs: the bar's own rectangle, and the monitor to open on.

THE BAR'S RECTANGLE IS THE WHOLE ANSWER, and it comes from the shell rather than
from the window, because a window does not know where it is (see
`set-window-edge-box!').  Both halves of the placement are measured from it: the
panel starts at the bar's far edge, and it lines up with the bar's own left,
centre or right rather than with the screen's.  A bar pushed along by another bar
on the same edge -- which is the ordinary case on a desktop running two shells --
is therefore still what the panel is placed against.

WHEN THE SHELL CANNOT SAY, the fallback is the window's own height plus its
margin for the clearance and the SCREEN's edges for the alignment, which is right
when the bar is the only thing on its edge and alone on its monitor."
  (catch #t
    (lambda ()
      (let* ((root (gtk-widget-get-root btn))
             (monitor (and root
                           (catch #t (lambda () (slot-ref root 'gdkmonitor))
                                  (lambda args #f))))
             (anchor (and root
                          (catch #t (lambda () (slot-ref root 'anchor))
                                 (lambda args '()))))
             (bottom? (and (list? anchor) (memq 'bottom anchor)))
             (margin (or (and root
                              (catch #t
                                  (lambda () (slot-ref root (if bottom? 'margin-bottom
                                                                'margin-top)))
                                (lambda args 0)))
                         0))
             ;; THE SHELL'S ANSWER FIRST, the measurement as a fallback.  The
             ;; shell knows where the bar actually is -- see
             ;; `set-window-edge-box!' -- and the measurement is right only when
             ;; the bar is alone on its edge.
             (provider (%window-edge-box))
             (box (and provider monitor
                       (catch #t
                           (lambda () (provider (monitor-name monitor)
                                                (gtk-widget-get-width root)
                                                (gtk-widget-get-height root)))
                         (lambda args #f))))
             ;; THE BAR'S FAR EDGE, in the screen's coordinates: its bottom for a
             ;; bar on the top edge, its top for a bar on the bottom.
             (from-shell (and (list? box) (= 4 (length box))
                              (if bottom?
                                  (- (list-ref (monitor-geometry monitor) 3)
                                     (list-ref box 1))
                                  (+ (list-ref box 1) (list-ref box 3))))))
        (popup-anchor! (widget-window-name widget)
                       align
                       (if bottom? 'bottom 'top)
                       (if (and (number? from-shell) (> from-shell 0))
                           from-shell
                           (+ (gtk-widget-get-height root) margin))
                       monitor
                       ;; The bar's rectangle, kept whole: the clearance is one
                       ;; thing to be read out of it and the horizontal alignment
                       ;; is the other.
                       (if (and (list? box) (= 4 (length box))) box #f))))
    (lambda args #f)))

(define (bar-relative-margin section bar-box monitor)
  "Where SECTION's edge is within MONITOR, as `(halign . margin)'.

THE MARGIN IS ON THE SIDE THE ALIGNMENT IMPLIES -- a left panel is held off the
left, a right panel off the right -- and it is measured from the BAR's edge, not
the screen's.  A popup window fills its monitor, so the bar's box has to be
re-based on the monitor's origin first: the compositor reports a bar's x in the
whole desktop's coordinates, which on a two-screen desk is a number like 1592 for
a bar 56 pixels into the second screen.

A CENTRED PANEL IS A SEPARATE PIECE OF ARITHMETIC.  A centred widget with a start
margin of M sits at `(W + M) / 2' -- the margin takes M off one side and the
remaining space is halved -- so putting its centre on the bar's centre means a
margin of `2 * centre - W', which needs no knowledge of the PANEL's width.  That
is the whole reason this is expressible at all: a panel's width is not settled
until it has been laid out once.

#f when there is no box to measure from, and the caller falls back to the
screen's edges."
  (let* ((geom (and monitor (catch #t (lambda () (monitor-geometry monitor))
                                  (lambda args #f))))
         (ok (and (list? bar-box) (= 4 (length bar-box)) (list? geom)
                  (= 4 (length geom)))))
    (if (not ok)
        (case section
          ((left) (cons 'start 0))
          ((right) (cons 'end 0))
          (else (cons 'center 0)))
        (let* ((mon-x (list-ref geom 0))
               (mon-w (list-ref geom 2))
               (bar-x (- (list-ref bar-box 0) mon-x))
               (bar-w (list-ref bar-box 2))
               (centre (+ bar-x (/ bar-w 2)))
               (want (case section
                       ((left) bar-x)
                       ((right) (- mon-w (+ bar-x bar-w)))
                       (else (- (* 2 centre) mon-w)))))
          (cons (case section ((left) 'start) ((right) 'end) (else 'center))
                (pixels (if (< want 0) 0 want)))))))

;; THE SLOT WRITES ARE IN A PROCEDURE OF THEIR OWN: the caller's job is to find
;; the revealer and this one's is to write to it.
;;
;; ONE THING TO KNOW ABOUT THE DOCSTRING BELOW AND THE ONE ABOVE.  A double quote inside a
;; docstring that is not escaped does not stay in the string: the reader ends the
;; string there and the REST OF THE PROSE BECOMES CODE.  This file had a
;; docstring quoting a user's words, and the quoted sentence made the first word
;; after it -- `it' -- the first form of the function body, so every call threw
;; "Unbound variable: it" while the same expression typed at a REPL (with no
;; docstring) ran correctly.  That looked exactly like the inliner bug this
;; codebase has hit before, and it was not: the source was malformed, and Guile's
;; reader is silent about it.  Quote with ` or escape with \".
(define (popup-place-under! win anchor)
  "Move WIN's content where the note ANCHOR says.  See `popup-anchor!'."
  (let ((revealer (catch #t (lambda () (gtk-widget-get-first-child win))
                         (lambda args #f))))
    (if (is-a? revealer <gtk-revealer>)
        (case (if (pair? anchor) (car anchor) #f)
          ((centred) (set-popup-centred! win revealer (cadr anchor)))
          ((bar) (set-popup-placement! win revealer (cadr anchor) (list-ref anchor 3)
                                       (list-ref anchor 4) (list-ref anchor 5)
                                       (list-ref anchor 2)))
          (else #f))
        ;; Not a popup: nothing to place, and nothing to report.
        #f)))

;; IN THE MIDDLE OF THE SCREEN, both ways: an opener with no bar to point at says
;; this, and a panel that came from the keyboard should not appear to have come
;; from a bar button.
(define (set-popup-centred! win revealer monitor)
  "Put WIN's content in the middle of MONITOR."
  (catch #t
    (lambda ()
      (when monitor (catch #t (lambda () (slot-set! win 'gdkmonitor monitor))
                           (lambda args #f)))
      (slot-set! revealer 'halign 'center)
      (slot-set! revealer 'valign 'center)
      (slot-set! revealer 'margin-start 0)
      (slot-set! revealer 'margin-end 0)
      (slot-set! revealer 'margin-top 0)
      (slot-set! revealer 'margin-bottom 0)
      #t)
    (lambda args
      (log-error args (format #f "centring the ~a popup"
                              (catch #t (lambda () (slot-ref win 'name))
                                     (lambda a "?"))))
      #f)))

(define (set-popup-placement! win revealer section clearance monitor bar-box edge)
  "Put WIN's content UNDER THE BAR: SECTION's edge, CLEARANCE down.

AND ON THE MONITOR THE BAR IS ON.  A popup is made once and shown many times,
and its surface belongs to whichever monitor it was first mapped on -- so a
panel opened from the second screen's bar used to appear on the first screen,
over THAT bar, at that bar's idea of the edges."
  (let* (;; THE EDGE THE BAR HANGS FROM, FROM THE NOTE rather than from the
         ;; window: the popup's own position says this at build time, and a
         ;; centred placement changes it, so reading it here would make this
         ;; placement depend on which kind ran last.
         (valign (if (eq? edge 'bottom) 'end 'start))
         ;; THE BAR'S EDGE, IN GTK'S VOCABULARY.  `left' and `right' are this
         ;; toolkit's words for the bar's three parts; GTK calls the alignments
         ;; `start' and `end', and has no `left' at all.
         (across (bar-relative-margin section bar-box monitor)))
    ;; WHOLE PIXELS, and this is not tidiness: GTK's margins are C INTs, and
    ;; `(slot-set! r 'margin-top 45.5)' raises `wrong-type-arg'.  A rejected
    ;; margin is invisible unless it is said out loud, which is why the catch
    ;; logs -- an earlier version of this swallowed the error and put every panel
    ;; in the wrong place with nothing anywhere to say why.
    (catch #t
      (lambda ()
        (when monitor (catch #t (lambda () (slot-set! win 'gdkmonitor monitor))
                             (lambda args #f)))
        (slot-set! revealer 'valign (if (eq? edge 'bottom) 'end 'start))
        (slot-set! revealer 'halign (car across))
        (slot-set! revealer 'margin-start (if (eq? (car across) 'end) 0 (cdr across)))
        (slot-set! revealer 'margin-end (if (eq? (car across) 'end) (cdr across) 0))
        (slot-set! revealer 'margin-top (if (eq? valign 'end) 0 (pixels clearance)))
        (slot-set! revealer 'margin-bottom
                   (if (eq? valign 'end) (pixels clearance) 0))
        #t)
      (lambda args
        (log-error args (format #f "placing the ~a popup"
                                (catch #t (lambda () (slot-ref win 'name))
                                       (lambda a "?"))))
        #f))))

(define (pixels n)
  "N as a whole number, for a GTK property that is a C int."
  (inexact->exact (round n)))

(define (popup-anchored! win)
  "Place WIN under the bar item that last opened it, if one ever did.

Called by `window-set-visible!' immediately before the window is shown, so the
placement is in place for the first frame rather than a jump on the second.  A
window nothing has ever anchored -- the bar itself, an overview opened from a
keybinding -- is left exactly as its position says."
  (let ((name (catch #t (lambda () (slot-ref win 'name)) (lambda args #f))))
    (let ((anchor (and name (hash-ref %popup-anchors name))))
      (when anchor
        (catch #t
          ;; THE NOTE IS ONE ARGUMENT, not a list of them: it was passed with
          ;; `apply' until the note grew a kind and the kinds have different
          ;; lengths, and an arity error here is INVISIBLE -- the catch below
          ;; turns it into a placement that quietly does not happen.  Which is
          ;; what it did: the menu opened at its build position while the note
          ;; said otherwise.
          (lambda () (popup-place-under! win anchor))
          (lambda args
            (log-error args (format #f "placing the ~a popup"
                                    (catch #t (lambda () (slot-ref win 'name))
                                           (lambda a "?"))))
            #f)))
      win)))

(define* (popup-window name #:key
                       (position 'center)
                       (class #f)
                       (gdkmonitor #f)
                       (visible #f)
                       (exclusivity 'ignore)
                       ;; A popup that takes the keyboard needs `exclusive'; one
                       ;; that is only clicked needs `on-demand'. A menu is the
                       ;; first kind -- it is navigated entirely by arrow keys.
                       (keymode 'on-demand)
                       ;; A menu sits on `top'; a switcher that covers the
                       ;; screen goes on `overlay', above everything.
                       (layer 'top)
                       ;; INSTANTLY, BY DEFAULT.  `#:transition` takes any
                       ;; GtkRevealer transition type -- 'slide-down, 'crossfade,
                       ;; 'none -- and the default is `none' because a panel
                       ;; belongs to a button on the bar: sliding it in from the
                       ;; screen's edge says it came from the edge, and it did
                       ;; not.  A caller that wants an animation asks for one.
                       (transition 'none)
                       ;; WHETHER THE POPUP DARKENS WHAT IS BEHIND IT.  #f, so
                       ;; the screen around the panel is untouched -- the window
                       ;; is transparent and only the panel's own card is painted.
                       ;; #t paints the whole surface, which is what a switcher
                       ;; that wants the desktop dimmed behind it is for.
                       (darken-background #f)
                       #:rest children)
  "A layer surface that closes on Escape or a click outside its content.

POSITION is one of 'top-left ... 'bottom-right or 'center; it decides where the
content sits -- and, with the popup's section, which edge it is aligned to.

The window fills the screen so a click outside the CONTENT has somewhere to
land.  It is registered like any other window, so `toggle-window' and
`windows-named' work on it unchanged.

IT IS TRANSPARENT UNLESS ASKED OTHERWISE.  A window in this toolkit is painted
with the theme's background colour by the stylesheet, and this window is the size
of the SCREEN -- so without a rule of its own every popup would dim the whole
desktop, which is not what a panel opened from the bar should do.  The stylesheet
gives `window.popup-window' no background, and `#:darken-background' is what puts
one back."
  (let* ((config (popup-position-config position))
         (halign (car config))
         (valign (cadr config))
         (kind (or transition 'none))
         ;; The revealer is the window's ONLY child and takes the caller's
         ;; content as its own child, so alignment lives on it -- exactly as
         ;; ags2-shell wraps `children' in a Gtk.Revealer inside PopupWindow.
         ;; No wrapper box is added: a popup's content is already the box its
         ;; author wanted, and an extra one would fight their orientation.
         (revealer (apply this!
                          (make <gtk-revealer>
                                #:transition-type kind
                                #:transition-duration 200
                                #:halign halign
                                #:valign valign
                                #:reveal-child visible)
                          children))
         (win (layer-window name
                            #:anchor '(top bottom left right)
                            #:exclusivity exclusivity
                            #:layer layer
                            #:keymode keymode
                            #:class (format #f "popup-window ~a~@[ ~a~]~a"
                                            name class
                                            (if darken-background " dimmed" ""))
                            #:gdkmonitor gdkmonitor
                            #:visible visible
                            revealer)))
    ;; ESCAPE CLOSES IT.  A controller is a child of the window in GTK4, not a
    ;; window property; ags2-shell has it as a JSX child for the same reason.
    (let ((keys (make <gtk-event-controller-key>)))
      (connect-signal! keys "key-pressed"
                       (lambda (c keyval keycode modifiers)
                         (if (= keyval 65307)     ; GDK_KEY_Escape
                             (begin (hide-popup! win) #t)
                             #f)))
      (add-controller win keys))
    ;; A CLICK OUTSIDE THE CONTENT CLOSES IT.  ASK GTK WHAT WAS CLICKED ON and
    ;; walk up from there, rather than computing the content's bounds: the
    ;; bounds route needs Graphene, and this answers the same question for every
    ;; descendant of the content -- a separator, a scrolled window -- with no
    ;; coordinate arithmetic at all.
    ;;
    ;; THE FOURTH ARGUMENT IS '() -- G-Golf passes a C BITFIELD as a LIST of
    ;; symbols, and an empty list is "no flags".  It was 0.
    ;;
    ;; That one wrong literal took the whole shell down, and the error named
    ;; neither the call nor the file:
    ;;
    ;;   In procedure map: Wrong type argument: 0
    ;;
    ;; because G-Golf walks the flag list to build the C value and the walk is
    ;; a `map'.  What made it hard to find is where it fired: this handler is
    ;; on the POPUP, so it ran on any click inside the menu -- clicking the
    ;; calendar's month arrows was the reliable repro -- and the crash happened
    ;; inside a signal emitted by GTK, where Guile's backtrace printer cannot
    ;; reach past the G-Golf frame.
    (let ((click (make <gtk-gesture-click>)))
      (connect-signal! click "pressed"
                       (lambda (c n x y)
                         (unless (descendant-or-self? (gtk-widget-pick win x y '())
                                                      revealer)
                           (hide-popup! win))))
      (add-controller win click))
    ;; The revealer follows the window, so a `toggle-window' from the keyboard
    ;; or the REPL animates exactly like a click on the panel button.
    (connect-signal! win "notify::visible"
                     (lambda args
                       (catch #t
                         (lambda ()
                           (gtk-revealer-set-reveal-child
                            revealer (window-visible? win)))
                         (lambda a #f))))
    win))

(define (descendant-or-self? widget ancestor)
  "Is WIDGET ANCESTOR, or below it?"
  (cond ((not widget) #f)
        ((eq? widget ancestor) #t)
        (else (descendant-or-self?
               (catch #t (lambda () (gtk-widget-get-parent widget))
                      (lambda args #f))
               ancestor))))

(define (hide-popup! win)
  "Hide a popup window.  Safe on an already-hidden or destroyed window."
  (catch #t (lambda () (gtk-widget-set-visible win #f) #t) (lambda args #f)))

;;; ---------------------------------------------------------------------------
;;; Panel buttons
;;; ---------------------------------------------------------------------------

(define* (panel-button widget #:key
                       (class #f)
                       (halign 'fill)
                       ;; WHICH PART OF THE BAR THIS BUTTON IS IN, which is where
                       ;; the panel it opens will be aligned.  The caller knows
                       ;; it -- `widget-build' has the widget, and the bar said
                       ;; which section it is in -- and it is passed rather than
                       ;; looked up because the WIDGET here is the PANEL, and the
                       ;; section is the bar item's.
                       (align 'center)
                       (on-clicked #f)
                       #:rest children)
  "A button that toggles WIDGET and shows whether it is open.

This is ags2-shell's `widget/Bar/components/PanelButton.tsx', and the shape is
theirs: the button carries the widget's name as its own CSS name, toggling the
widget is the default action, and `active' tracks it.

A feature is therefore its bar widget and its panel widget, and this button is
the panel's state indicator.

IT TAKES THE WIDGET, NOT A WINDOW NAME.  `(widget-toggle! widget)' and
`(widget-visible? widget)' are the whole of what it needs, so a panel that owns
two windows or none is not this function's problem.

THE HOOK IS KEYED BY THE WINDOW'S NAME, NOT THE WIDGET'S, and `widget-window-name'
is what tells the two apart: `datemenu-panel' is the widget, `datemenu' its
window, and the window is what the notification comes from.  Keyed by name
because the window may not exist yet -- a button is built while the bar is being
assembled and the panels are built afterwards -- so there is nothing to connect
to, only a name to listen for.

IT ALSO SAYS WHERE TO OPEN.  A click records the button's place in the bar before
toggling, which is how the panel comes up under this button rather than wherever
its position points (`panel-anchor!').  Recorded on the click rather than at
build because where the button is is a fact about the moment.

THE DEFAULT CLICK IS THE TWO ABOVE, IN ORDER -- anchor, then toggle -- so a panel
opened by a click is placed under the button that opened it without the panel
knowing the button exists.  A caller that passes its own `on-clicked' replaces
both, and gets a button that neither places nor toggles; nothing does that today."
  ;; THE SHORT NAME, because this one is presentation: the button's GTK name and
  ;; its CSS class.  See `widget-short-name'.
  (let* ((name (widget-short-name widget))
         (window-name (widget-window-name widget))
         (btn (apply element <gtk-button>
                     #:name name
                     #:class (if class
                                 (format #f "panel-button ~a ~a" name class)
                                 (format #f "panel-button ~a" name))
                     #:valign 'center
                     #:halign halign
                     #:can-focus #f
                     #:on-clicked (or on-clicked
                                      (lambda (b)
                                        (panel-anchor! b widget align)
                                        (widget-toggle! widget)))
                     children)))
    ;; The initial state, then every change.  `toggle-class!' rather than a
    ;; css-classes edit: adding and removing by hand is how the tray lost its
    ;; `active' class.
    (toggle-class! btn "active" (widget-visible? widget))
    (on-window-toggle window-name
                      (lambda (win)
                        (toggle-class! btn "active" (widget-visible? widget))))
    btn))

;;; ---------------------------------------------------------------------------
;;; Widgets
;;; ---------------------------------------------------------------------------
;;
;; A WIDGET IS AN OBJECT, AND THE GTK TREE IS NOT.  The two are deliberately
;; different things, and keeping them apart is what makes a per-monitor shell
;; tractable:
;;
;;   the WIDGET is the abstract thing -- "the network widget".  There is ONE of
;;   it, it owns the configuration, and it is what `add-widget!' is handed.
;;
;;   the VIEW is the `<gtk-widget>' that `widget-build' returns -- one per
;;   monitor, because a bar is one per monitor.  It captures the output name and
;;   any per-monitor state in its own closure.
;;
;; So `widget-build' TAKES THE OUTPUT NAME: building is the act of becoming
;; monitor-aware, and a widget that needs to know which bar it is on has it
;; without asking anybody.
;;
;; WHY THIS IS NOT THE ABSTRACTION LAYER THE PLAN FORBIDS.  There is no wrapper
;; around `element' here: `widget-build' still calls `element' and `add-child!'
;; exactly as any other code does, and the tree it returns is an ordinary GTK
;; tree that nothing in this module ever inspects.  What the class adds is
;; IDENTITY, LIFECYCLE and DECLARATION -- a name, a way to build, and (on the
;; subclasses) `#:config' slots.  It replaces the `name -> builder' tables a
;; shell would otherwise keep, and it is what makes a settings window possible
;; without hand-writing one.
;;
;; THE METHODS ARE GENERICS WITH DEFAULTS, like `<wm>' in scheme-desktop: a
;; widget that cannot build itself says so by name rather than failing with
;; "no applicable method for #<generic widget-build (2)>".
;;
;; This lives in `app' rather than in `widget' because a widget that owns a
;; window needs the window machinery below, and because `(scheme-toolkit
;; widget)' is the element runtime and nothing else.

;; THE HIERARCHY, and every level of it answers a question somebody asks.
;;
;;   <desktop-widget>     the identity: a name, and that is all. A thing the
;;                        shell has, which can be found in the registry.
;;
;;   <bar-item-widget>    a mini-widget: one that is BUILT INTO something else.
;;                        It can be built (`widget-build') and it is never
;;                        shown, hidden or toggled, because it has no window --
;;                        so asking it to toggle is a category error rather
;;                        than a no-op, and the method does not exist.
;;
;;   <window-widget>      owns windows, and therefore can be shown, hidden and
;;                        toggled. `widget-window' is the singular convenience;
;;                        `widget-windows' is what the verbs use, because one
;;                        widget has a window per monitor.
;;
;;   <popup-widget>       a window that opens and closes: the menu, the wifi
;;                        panel, the workspace picker, the date menu. One per
;;                        shell, and it follows the focused monitor rather than
;;                        existing on every one.
;;
;;   <edge-widget>        a window that is OPENED ONCE AND STAYS: the bar, and
;;                        later the dock. One per monitor, anchored to a screen
;;                        edge, reserving or avoiding space. Auto-hide -- and
;;                        everything else a dock and a bar would share -- lands
;;                        here rather than in the bar alone.

;;; ---------------------------------------------------------------------------
;;; The metaclass: config slots that notify when they change
;;; ---------------------------------------------------------------------------
;;
;; A SLOT DOES NOT NOTIFY.  `(set! (bar-height w) 40)' changes a struct field
;; and nothing else happens -- so a label bound to it would never move.  That is
;; the whole problem this metaclass solves, and it solves it STRUCTURALLY: the
;; setter GOOPS builds for a `#:config' slot is replaced with one that stores
;; the value and ticks a per-widget change signal, so there is no way to write a
;; config slot and forget to notify.  No `#:setter' has to remember anything,
;; and a widget's config needs no hand-written accessors at all.
;;
;; WHAT `compute-get-n-set' ACTUALLY RETURNS, because the obvious version of
;; this is wrong: for an ordinary instance slot it returns AN INTEGER -- the
;; struct field offset -- and `allocate-slots' builds the accessor from it.  It
;; returns a `(get set)' pair only when the slot's storage is the metaclass's
;; own business.  So there are two shapes to get right:
;;
;;   - a slot we wrap: call `(next-method)' to allocate the field AS USUAL,
;;     keep struct storage, and close over the offset it returns;
;;   - a slot we do not: `(next-method)', untouched.
;;
;; `(next-method)' MUST NOT BE CALLED FOR A SLOT WE HANDLE OURSELVES without
;; using the offset -- it bumps the class's field counter, and every slot
;; declared after it would then read one field too far.
;;
;; `<desktop-widget>' CANNOT ALSO BE THE METACLASS.  It is the root of the
;; widget hierarchy, and a class cannot be both a superclass and the metaclass
;; of its own subclasses.  So `<widget-class>' is separate, and the root carries
;; `#:metaclass' once -- every subclass inherits it.

(define-class <widget-class> (<class>))

;; THE ROOT OF THE HIERARCHY, and the one place `#:metaclass' is written: every
;; widget class below inherits it, so no subclass repeats it.
(define-class <desktop-widget> ()
  ;; WHO THIS WIDGET IS: its QUALIFIED NAME, `(module ... <class>)' -- the
  ;; module that defines its class, then the class.  Set by the root when it
  ;; makes the widget from a name in its list, and it is what the registry, the
  ;; config file and the bar's layout all call it.  Two plugins can each have a
  ;; `<clock-desktop-widget>'; they cannot both have it in the same module.
  ;;
  ;; #f for a widget made by hand rather than from a name, which `widget-name'
  ;; then derives from the class -- see there.
  (qualified-name #:init-value #f #:init-keyword #:qualified-name
                  #:accessor widget-qualified-name
                  #:setter widget-qualified-name-set!)
  #:metaclass <widget-class>)

;; obj -> ((slot-name . (accessor . setter)) ...)
;;
;; A WEAK key table, so a widget that is collected takes its signals with it.
;; PER OBJECT AND PER SLOT, not per class: a signal created once per
;; `compute-get-n-set' call would be shared by every instance of the class, and
;; two widgets would notify each other's subscribers.
(define %config-ticks (make-weak-key-hash-table))

;; Objects under construction, which must not notify.  `make' writes every
;; `#:init-keyword' slot, so without this a widget ticked its own signals before
;; it existed.
(define %initialising (make-weak-key-hash-table))

(define (widget-config-tick w slot)
  "The change signal for SLOT of W, created on first ask.

Created ON DEMAND rather than eagerly, so a config slot nothing ever binds to
costs no state at all -- which is the same reason accessors in this toolkit are
cold."
  (let* ((al (hashq-ref %config-ticks w))
         (hit (and al (assq slot al))))
    (or (and hit (cdr hit))
        ;; NOT `set!' as the variable name: it is a Guile syntax keyword, and
        ;; binding it is `set!: bad set! in form set!' at compile time.
        (let-values (((acc bump!) (create-state 0)))
          (let ((pair (cons acc bump!)))
            (hashq-set! %config-ticks w (acons slot pair (or al '())))
            pair)))))

(define (widget-slot-ref w slot)
  "An ACCESSOR over one of W's config slots, for binding to a widget property.

Named `widget-slot-ref' and not `widget-config-ref' because the config engine
addresses options by widget NAME and owns that name -- and two procedures called
`widget-config-ref', one taking a widget and one taking a name, is the kind of
collision that resolves by import order and breaks on a reshuffle.

The slot holds the value; the tick is what says it changed.  A slot read records
no dependency of its own, so the tick is the only thing the computed can depend
on -- and it is read by CALLING it, which is what records the dependency."
  (create-computed
   (lambda ()
     ((car (widget-config-tick w slot)))
     (slot-ref w slot))))

(define-method (compute-get-n-set (class <widget-class>) slot)
  (if (memq #:config (slot-definition-options slot))
      (let* ((offset (next-method))
             (name (slot-definition-name slot))
             (descriptor (cadr (memq #:config (slot-definition-options slot))))
             ;; THE PREDICATE IS MADE HERE, ONCE.  `compute-get-n-set' runs when
             ;; the class is FINALISED -- once per slot per class, not once per
             ;; write -- so the descriptor is read at definition time and the
             ;; closure is reused by every set that slot ever takes.  An unknown
             ;; descriptor therefore fails when the CLASS is defined, which is
             ;; where it is fixable, rather than being discovered later against
             ;; one value.
             (valid? (config-descriptor-validator descriptor)))
        (list (lambda (o) (struct-ref o offset))
              (lambda (o v)
                ;; THE VALUE IS CHECKED HERE, IN THE SLOT, so that EVERY write is
                ;; checked -- `slot-set!', a GOOPS accessor's setter, the file
                ;; reader, the settings widget, a poke from the REPL.  They all
                ;; come through this closure; it is the one place they have in
                ;; common.
                ;;
                ;; IT USED TO BE IN THE CALLERS.  `apply-widget-option!' checked
                ;; and `widget-config-set!' went through it, which covers the
                ;; writes those two make and nothing else: `(bar-height-set!
                ;; (bar) 900)' checked nothing, persisted, and showed 900.  Two
                ;; entry points each checking for its own reason, and the slot
                ;; they both pass through checking for neither -- which is a
                ;; strange place to have arrived at, given the metaclass was
                ;; already intercepting the write to tick.
                (unless (valid? v)
                  (error (format #f "~s is not a valid ~a for ~a.~a"
                                 v descriptor (widget-label o) name)))
                ;; ONLY WHEN IT ACTUALLY CHANGED, for two reasons.
                ;;
                ;; Reactivity: a computed should not recompute because a slot
                ;; was written the same value it already held.
                ;;
                ;; And PERSISTENCE, which is the one that bites: the config
                ;; engine saves when a tick arrives, the file monitor reloads
                ;; when the file is written, and the reload writes every option
                ;; back.  Ticking unconditionally makes that a loop -- load,
                ;; save, load, save -- that never settles.  The old flat engine
                ;; got this for free from `create-state', which notifies only on
                ;; a real change; a raw struct write had to be taught the same.
                (unless (equal? (struct-ref o offset) v)
                  (struct-set! o offset v)
                  (unless (hashq-ref %initialising o)
                    (let* ((al (hashq-ref %config-ticks o))
                           (hit (and al (assq name al))))
                      ;; Only tick a signal that already exists: creating one on
                      ;; every write would give every config slot a state whether
                      ;; or not anything watches it.  The engine creates them
                      ;; deliberately, for the slots it wants to persist.
                      ;;
                      ;; `hit' is the alist entry -- (name . (acc . bump!)) --
                      ;; so the accessor is two cars deep, not one.
                      (when hit
                        (let ((pair (cdr hit)))
                          ((cdr pair) (+ 1 (st-peek (car pair))))))))))))
      (next-method)))

(define-method (initialize (w <desktop-widget>) args)
  (hashq-set! %initialising w #t)
  (next-method)
  (hashq-remove! %initialising w)
  ;; THE WATCHERS, once, here, for every option that said how to apply itself.
  ;; AFTER `%initialising' is cleared, so a watcher attached now can only ever
  ;; fire for a change made after the object was whole.
  (widget-watch-own-options! w))

;;; ---------------------------------------------------------------------------
;;; What a widget declares
;;; ---------------------------------------------------------------------------

;; A config slot is declared with a TYPE DESCRIPTOR, not a validator procedure.
;; The reason is the settings widget: `(lambda (v) (and (number? v) (<= 0.75 v
;; 3.0)))' can be enforced but cannot be ASKED what control to draw, and the
;; range 16..96 in `(integer 16 96)' is the whole of what a slider needs.
;;
;; The descriptor is QUOTED -- slot options are evaluated, so `(number 0.75
;; 3.0)' tries to call a procedure called `number'.

(define (widget-label o)
  "O's widget name if it has one, otherwise its class name.  For diagnostics.

The slot's own check runs for EVERY write, including on an object whose class
uses <widget-class> but which is not a <desktop-widget> -- and there `widget-name'
has no method and would raise.  A diagnostic must not be the thing that raises."
  (catch #t
    (lambda () (widget-name o))
    (lambda args (class-name (class-of o)))))

(define (config-descriptor-validator descriptor)
  "A predicate that accepts what DESCRIPTOR describes."
  (case (car descriptor)
    ((boolean) boolean?)
    ((string) string?)
    ((integer) (let ((lo (cadr descriptor)) (hi (caddr descriptor)))
                 (lambda (v) (and (integer? v) (<= lo v) (<= v hi)))))
    ((number) (let ((lo (cadr descriptor)) (hi (caddr descriptor)))
                (lambda (v) (and (number? v) (<= lo v) (<= v hi)))))
    ((choice) (let ((allowed (cdr descriptor)))
                (lambda (v) (and (memq v allowed) #t))))
    ;; An opaque list.  The bar's layout is this: a structure whose parts are
    ;; other widgets' names, which no single control could edit -- so the
    ;; descriptor says "a list" and the settings widget shows it read-only
    ;; rather than offering something that would not work.
    ((list) list?)
    (else (error "unknown config descriptor:" descriptor))))

(define (widget-config-slots w)
  "W's config slots, as an alist each.

  ((name . height) (type . (integer 16 96)) (label . \"Height\") (default . 30))

Inherited slots are included, so a widget inherits its superclass's options the
same way it inherits its behaviour."
  (filter-map
   (lambda (s)
     (let ((opts (slot-definition-options s)))
       (and (memq #:config opts)
            (let ((label (memq #:label opts))
                  (apply! (memq #:apply opts)))
              (list (cons 'name (slot-definition-name s))
                    (cons 'type (cadr (memq #:config opts)))
                    (cons 'label (and label (cadr label)))
                    ;; `#:apply' IS OPTIONAL.  An option that only says what it
                    ;; is has no way to reach the screen yet; the file and the
                    ;; settings widget still know about it.
                    (cons 'apply (and apply! (cadr apply!)))
                    (cons 'default (slot-definition-init-value s)))))))
   (class-slots (class-of w))))



;;; ---------------------------------------------------------------------------
;;; Options that apply themselves
;;; ---------------------------------------------------------------------------
;;
;; THE LAMBDA LIVES ON THE SLOT.  An option declared with `#:apply' says what to
;; do when it changes, in the place it is declared -- so taking effect is a line
;; in the declaration rather than a special case somewhere else, and an option
;; cannot be added without saying what it does:
;;
;;   (opacity #:init-value 0.92 #:accessor bar-opacity
;;            #:config '(number 0.0 1.0) #:label "Background opacity"
;;            #:apply (lambda (bar value)
;;                      (for-each (lambda (win) (slot-set! win 'opacity value))
;;                                (widget-windows bar))))
;;
;; WHAT THIS REPLACES.  Until now the only way an option could reach the screen
;; was for the shell to be rebuilt, so a hotkey for transparency cost a rebuild
;; of every bar -- and, while the config file was watched, a rebuild of the shell
;; behind it.  Now the option does its one thing, immediately, and nothing else
;; happens at all.
;;
;; A WATCHER IS ATTACHED ONCE PER WIDGET, in the constructor -- not per window
;; and not per rebuild.  A widget made once may end up with a window per monitor,
;; and its trees are built again on every rebuild, so attaching in the build
;; would multiply the watchers by both.  The lambda therefore CYCLES THROUGH
;; `widget-windows' rather than closing over one window.

(define %widget-scope #f)

(define (widget-scope)
  "The standing reactive scope that owns every per-widget tick.

STANDING, and one for the whole shell, because a widget subscribes to its own
options in its constructor -- and widgets are made when no scope is current: the
shell's `main' runs inside GApplication's `activate', a signal emitted from C.
Creating a state there warns, three times, and leaves the state unowned.

ONE ROOT FOR ALL OF THEM is safe because the tick table is weak-keyed by the
widget: a widget that is dropped takes its ticks with it, so nothing accumulates
here."
  (unless %widget-scope
    (create-root (lambda (dispose) (set! %widget-scope (get-scope)))))
  %widget-scope)

(define (widget-apply-option! w spec)
  "Do what one option SAID to do, with the value its slot now holds.

The value is read here rather than handed in, so there is one reading of it.  The
procedure takes the WIDGET and the value, and answers for whatever it touches --
several windows, one window, or nothing at all when the widget has not been built
yet."
  (let ((proc (assoc-ref spec 'apply)))
    (and proc
         ;; `(assoc-ref spec 'name)', not `widget-option-name': that reader lives
         ;; in (scheme-toolkit config), which imports THIS module, so this module
         ;; cannot call it.  The spec alist already carries the name.
         (let ((name (assoc-ref spec 'name)))
           (catch #t
             (lambda () (proc w (slot-ref w name)) #t)
             (lambda (key . rest)
               ;; LOGGED, NOT RAISED.  This runs from a slot write, and a slot
               ;; write may be a file being read or a keybinding calling in: a bar
               ;; that cannot become translucent must not take the shell down.
               (log-error (cons key rest)
                          (format #f "applying ~a.~a" (widget-label w) name))
               #f))))))

(define (widget-apply-options! w)
  "Put every option's current value where it belongs, all of them.

WHAT THE BUILD CODE CALLS, once, after it has made the GTK objects.  The watchers
cover every change from then on, but a value set BEFORE those objects existed had
nothing to act on -- and that is the normal order, because the config file is
read before anything is built.  So the objects are brought up to date here rather
than the watchers having to remember what they missed."
  (for-each (lambda (spec) (widget-apply-option! w spec))
            (widget-config-slots w))
  #t)

(define (widget-watch-own-options! w)
  "Subscribe every option of W that declares an `#:apply'.

THE CONSTRUCTOR'S JOB.  Nothing is deferred and nothing is written: the point of
the whole arrangement is that setting a value does its one thing straight away."
  ;; `parameterize' ON THE IMPORTED PARAMETER, not `with-scope'.  `with-scope' is
  ;; the documented way and is what a caller in the same module or in
  ;; interpreted code should use -- but Guile 3.0.11 INLINES it, and the inlined
  ;; copy's reference to the module-private parameter resolves wrongly when the
  ;; caller is another compiled module.  The result is
  ;;
  ;;   Not a parameter: #<procedure get-scope ()>
  ;;
  ;; from `(make <a-widget>)', which reads like a widget bug and is not one.
  ;; `current-scope' is the same parameter, exported, so there is nothing here
  ;; to inline.  See the long note beside it in (scheme-toolkit reactive).
  (parameterize ((current-scope (widget-scope)))
    (for-each (lambda (spec)
                (when (assoc-ref spec 'apply)
                  (subscribe (car (widget-config-tick w (assoc-ref spec 'name)))
                             (lambda () (widget-apply-option! w spec)))))
              (widget-config-slots w)))
  #t)

(define-generic widget-name)

;; THE NAME COMES FROM THE CLASS, so it is written once.  `<clock-desktop-widget>'
;; is "clock"; a name that had to be given again as a slot is a name that drifts
;; from the class it belongs to.  The suffix is what makes the rule mechanical --
;; one rule, no special cases.  A subclass may override this method when the
;; derived name is wrong.
;; THE DERIVATION IS A FUNCTION OVER A CLASS NAME, not a method over an instance,
;; because the root has to know what a name WILL BE before it makes one -- to
;; compare its list against the registry without instantiating anything.  One
;; rule, called from both places, so the two can never drift.
(define (widget-name-from-class-name class-name)
  "The widget name CLASS-NAME denotes: `clock' for `<clock-desktop-widget>'."
  (let* ((s (symbol->string class-name))
         (s (if (and (> (string-length s) 2)
                     (string-prefix? "<" s) (string-suffix? ">" s))
                (substring s 1 (- (string-length s) 1))
                s))
         (suffix "-desktop-widget"))
    (if (string-suffix? suffix s)
        (substring s 0 (- (string-length s) (string-length suffix)))
        s)))

;; THE IDENTITY IS THE QUALIFIED NAME; THE SHORT NAME IS PRESENTATION.
;;
;; `widget-name' answers the qualified name, `(scheme-desktop widgets network
;; <network-panel-desktop-widget>)' -- the key in the registry, the config file
;; and the bar's layout, and unique across plugins.
;;
;; `widget-short-name' answers "network-panel", derived from the class as names
;; always were, and it is for what the SCREEN sees: a window's name, a GTK widget
;; name, a CSS class.  The stylesheet says `window#network' and
;; `button.network-panel', and none of that had any reason to change when the
;; identity did.
(define-method (widget-name (w <desktop-widget>))
  (or (widget-qualified-name w) (widget-short-name w)))

(define (widget-short-name w)
  "W's presentation name: \"network-panel\" for <network-panel-desktop-widget>."
  (widget-name-from-class-name (class-name (class-of w))))

;; WHICH PART OF THE BAR THIS ITEM IS IN -- `left', `center' or `right' -- and it
;; is the bar's to say, not the widget's: a widget moves between sections when
;; the layout changes and its own code never hears about it.  The bar sets it as
;; it places the tree (`mark-item-section!'), and the panel a button opens is
;; aligned by it: a panel from the left section opens flush left, one from the
;; centre section centred, one from the right flush right.
;;
;; BY SECTION RATHER THAN BY THE BUTTON'S EXACT PLACE, because the button's place
;; is not knowable well enough to hang a panel on: a panel's own width is not
;; settled until it has been laid out once (see `popup-anchored!'), so centring
;; on a button measured a few dozen pixels out on one open and right on the next.
;; A section is a fact that does not move.
;;
;; `center' IS THE DEFAULT because it is the harmless one: a panel opened from a
;; keybinding rather than from a button opens centred, which is what a panel that
;; has not been told otherwise should do.
(define-class <bar-item-widget> (<desktop-widget>)
  (section #:init-value 'center #:init-keyword #:section
           #:accessor widget-section))

;; WHAT THE BAR CALLS WHEN IT PLACES AN ITEM'S TREE.  A function rather than the
;; accessor so the bar says "this tree belongs to this widget, in this section"
;; in one line, and so the default stays the class's.
(define (mark-item-section! widget position)
  (catch #t (lambda () (slot-set! widget 'section position) #t)
         (lambda args #f)))

(define-generic widget-build)

(define-method (widget-build (w <bar-item-widget>) output)
  (error "the widget does not know how to build itself:" (widget-name w)))

;; A LOW-LEVEL HOOK, NOT PART OF THE CONTRACT.  The verbs below are written in
;; terms of `widget-windows' and most widgets never mention either; nothing
;; OUTSIDE a widget should ask how many GTK windows it owns, because that is the
;; widget's business.  What the outside gets is `widget-toggle!' and
;; `widget-visible?'.
;;
;; `widget-window' answers #f rather than erroring, so the verbs are no-ops on a
;; widget with no window at all.  It is the SINGULAR convenience, and
;; `widget-windows' is what the verbs actually use -- a widget with one window
;; (nearly all of them) gets the default, and the one widget that has a window
;; per monitor overrides `widget-windows' and nothing else.
(define-class <window-widget> (<desktop-widget>))

;; WHAT ITS WINDOW IS CALLED, when that is not the widget's own name.  The two
;; usually agree -- the overview widget owns the window `overview' -- but a panel
;; is the exception, because a widget called `datemenu-panel' owns a window called
;; `datemenu': the widget's name is the FEATURE (button and panel together) and
;; the window's is what the stylesheet and the layer shell call it.
;;
;; Asked of the widget rather than passed to `panel-button' because three things
;; need the same answer -- the window's own name, the button's visibility hook,
;; and the anchor the panel opens from -- and a second copy is a second thing to
;; keep in step.
;;
;; A METHOD AND NOT A SLOT, and the reason is a GOOPS trap worth knowing: a
;; subclass that re-declares an inherited slot WITHOUT repeating its `#:accessor'
;; leaves the parent's accessor with no applicable method, so the call throws
;; "No applicable method for #<<accessor> ...>".  A slot with a per-subclass
;; default therefore needs every subclass to repeat the accessor name; a method
;; is one declaration per panel and nothing to repeat.
(define-generic widget-window-name)
;; The default is the widget's own name, which is right for every widget whose
;; window is named after it -- and a widget with no windows still answers, so
;; `panel-button' can name a button after a widget that is only ever in a bar.
(define-method (widget-window-name (w <desktop-widget>)) (widget-short-name w))

(define-generic widget-window)
(define-method (widget-window (w <window-widget>)) #f)

(define-generic widget-windows)
(define-method (widget-windows (w <window-widget>))
  (let ((win (widget-window w))) (if win (list win) '())))

;; A window that opens and closes, one per shell, following the focused monitor.
;; Nothing in it yet: every popup here is built with `popup-window', which
;; carries the Escape and click-outside behaviour.  The class is where a second
;; kind of popup behaviour would go.
(define-class <popup-widget> (<window-widget>))

;; A window that is OPENED ONCE AND STAYS: the bar, and later the dock.  One per
;; monitor.  `widget-windows' is what makes that real in practice -- a bar
;; returns one window per monitor, so its verbs move them all together -- and
;; auto-hide, and everything else a bar and a dock would share, lands here
;; rather than in the bar alone.
(define-class <edge-widget> (<window-widget>))

;; SHOWING IS WHERE A PANEL IS PLACED.  A popup is made once and shown many
;; times, so its place is decided on each showing rather than at build: the bar
;; may have moved, and the button that opens it may have moved with it.  Doing it
;; HERE rather than in the toggle verbs means every path in -- a click, a
;; keybinding, the REPL -- gets it, and gets it before the window is mapped
;; rather than a frame later.
(define (window-set-visible! win on)
  (when on (popup-anchored! win))
  (catch #t (lambda () (slot-set! win 'visible (and on #t)) #t) (lambda args #f)))

;; THE VERBS ARE THE CONTRACT, and they mean "whatever showing this widget
;; means".  For most of them it is one window; for the bar it is every
;; monitor's; for a widget that is only ever in a bar there is nothing to show
;; and they do nothing.
(define-generic widget-show!)
(define-method (widget-show! (w <window-widget>))
  (for-each (lambda (win) (window-set-visible! win #t)) (widget-windows w))
  #t)

(define-generic widget-hide!)
(define-method (widget-hide! (w <window-widget>))
  (for-each (lambda (win) (window-set-visible! win #f)) (widget-windows w))
  #t)

;; ALL OF THEM MOVE TOGETHER, which is what a per-monitor bar wants:
;; `(widget-toggle! bar)' should not leave one monitor behind.  The target is
;; "hidden" only when every window is hidden, so a half-shown pair is fixed by
;; one call rather than flipped into another half-shown state.
(define-generic widget-toggle!)
(define-method (widget-toggle! (w <window-widget>))
  (let ((wins (widget-windows w)))
    (if (null? wins)
        #f
        (let ((target (not (any window-visible? wins))))
          ;; THROUGH THE VERBS, NOT `window-set-visible!'.  The comment above
          ;; says the verbs ARE the contract, and this method is how a panel
          ;; button opens its panel -- so going round them meant a widget's
          ;; `widget-show!' never ran for a CLICK, only for the keyboard menu.
          ;;
          ;; MEASURED, twice.  First: a line added to `widget-show!' printed for
          ;; `toggle-menu' and never for a bar-button click.  Second, and this is
          ;; what it costs the user: a panel that rebuilds itself before showing
          ;; was therefore rebuilt only AFTER it became visible -- so you watched
          ;; it empty and refill on every open, which reads as "the panel keeps
          ;; changing width when I click it".
          ;;
          ;; `widget-show!' runs the override BEFORE `next-method' shows the
          ;; windows, so the rebuild happens while the panel is still hidden and
          ;; the first frame shown is already the finished one.
          (if target (widget-show! w) (widget-hide! w))
          target))))

;; What a panel button asks to decide its `active' class.  It is the ONLY thing
;; anything outside a widget wants to know about its windows, and it is a
;; question about the widget rather than about a window.
(define-generic widget-visible?)
(define-method (widget-visible? (w <window-widget>))
  (any window-visible? (widget-windows w)))

;; EVERY WINDOW THE SHELL HAS, which is what startup presents and what a
;; rebuild re-presents.  It is derived, not stored: the widgets are the registry
;; and their windows are `widget-windows', so there is nothing here to keep in
;; sync with anything.
(define (shell-windows)
  (append-map widget-windows
              (filter (lambda (w) (is-a? w <window-widget>))
                      (desktop-widgets))))

;; DESTROY, not hide.  A rebuild needs the old windows gone rather than
;; invisible, and a widget that caches its windows has to forget them or the
;; next `widget-windows' hands back dead objects.
;;
;; The default destroys what `widget-windows' returns; a widget that caches
;; them overrides this to clear its cache as well.  It does NOT dispose the
;; reactive root: roots are per-MONITOR, and a rebuild builds the new windows
;; inside the same root -- disposing it would leave the fresh widgets
;; subscribed into a dead scope.
(define-generic widget-destroy-windows!)
(define-method (widget-destroy-windows! (w <window-widget>))
  (let ((wins (widget-windows w)))
    (for-each (lambda (win)
                (catch #t
                  (lambda () (destroy win))
                  ;; A window the compositor already took is not an error worth
                  ;; stopping a rebuild for.
                  (lambda (key . rest) #f)))
              wins)
    (length wins)))

;;; ---------------------------------------------------------------------------
;;; Decommissioning -- the message a teardown sends to every widget
;;; ---------------------------------------------------------------------------
;;
;; A TEARDOWN IS A ROOT-LEVEL EVENT AND EVERY WIDGET HEARS ABOUT IT.  Most have
;; nothing to do, so the default method answers #t and only a widget holding GUI
;; of its own overrides it.  Same shape as `widget-windows': a default, and a
;; method where there is something to say.
;;
;; WHAT IT IS FOR.  A widget that keeps a slot holding the GTK objects it built
;; must empty that slot when the trees go, and that is not tidiness -- a Scheme
;; reference to a destroyed widget is how this happens:
;;
;;   GLib-GObject-CRITICAL: g_object_get_property: assertion 'G_IS_OBJECT' failed
;;
;; which is the crash that took the shell down on its first config edit.  The bar
;; already does this by hand for its windows in `widget-destroy-windows!'; this is
;; the same idea for everything that is not a window.
;;
;; ORDER: DESTROY FIRST, THEN SEND THIS.  A widget that owns windows destroys
;; them in `widget-destroy-windows!', and that needs its slot still populated --
;; so a teardown destroys, and then tells everyone.
;;
;; OUTPUT NAMES ONE MONITOR, or #f for all of them: a monitor leaving is the
;; teardown of one output's GUI, and a rebuild is the teardown of every one.
(define-generic widget-decommission!)
(define-method (widget-decommission! (w <desktop-widget>) output)
  "Forget whatever GUI W built for OUTPUT; #f means every output."
  #t)

(define (widgets-decommission! output)
  "Send the teardown message to every registered widget.

The PROPAGATION half of a root-level teardown: the shell rebuilding itself, or
one monitor going away.  Each widget is caught separately -- a widget that
mishandles its own teardown must not abort the rebuild for the others.

Returns how many were told."
  (for-each (lambda (w)
              (catch #t (lambda () (widget-decommission! w output)) (lambda args #f)))
            (desktop-widgets))
  (length (desktop-widgets)))

;; Toggle the widget CALLED NAME.  The name-based form exists for keybindings
;; and the REPL, where naming the thing is all there is to go on:
;;
;;   scheme-toolkit eval '(toggle-widget "launcher")'
(define (toggle-widget name)
  (let ((w (desktop-widget-named name)))
    (or (and w (widget-toggle! w))
        (begin
          (format (current-error-port)
                  "scheme-toolkit: toggle-widget: no widget called ~a~%" name)
          #f))))

;;; ---------------------------------------------------------------------------
;;; The registry
;;; ---------------------------------------------------------------------------
;;
;; ONE GLOBAL REGISTRY, AND IT HOLDS WIDGETS.  Not a second one for the windows
;; they own: a window is reached through the widget that owns it, with
;; `widget-window', so a window table would be a second thing to keep in step
;; with the first -- which is exactly how `network' came to be a bar button
;; whose panel nothing built.
;;
;; NOT EVERY WIDGET IS IN A BAR.  A panel that is only ever opened by a
;; keybinding is still a widget, is still registered, and is simply never named
;; by the bar's layout.  "Is it in the bar?" is a fact about the bar, not a kind
;; of widget.
;;
;; REGISTERING REPLACES BY NAME, and that is the override mechanism: a shell
;; registers everything it ships, and a user's file loaded afterwards replaces
;; the entries it names.  One widget per name is right because a widget is one
;; per SHELL -- the per-monitor trees are views built from it by `widget-build'.

;; ((name . widget) ...), in registration order.
(define %desktop-widgets '())

(define (register-desktop-widget! w)
  "Put W in the shell's widget registry, replacing any widget of the same name.

Returns W, so a registration file reads as a list of widgets rather than a list
of calls with no results."
  (let* ((name (widget-name w))
         (existing (assoc name %desktop-widgets)))
    (if existing
        ;; Replaced IN PLACE, so an override keeps the position the shell gave
        ;; it and a settings list does not shuffle when one entry changes.
        (set-cdr! existing w)
        (set! %desktop-widgets (append %desktop-widgets (list (cons name w)))))
    w))

(define (desktop-widgets)
  "Every registered widget, in registration order."
  (map cdr %desktop-widgets))

(define (desktop-widget-names)
  "The name of every registered widget, in registration order."
  (map car %desktop-widgets))

(define (desktop-widget-named name)
  "The live widget NAME denotes, or #f.

NAME is any of:

  a QUALIFIED NAME   '(scheme-desktop widgets network <network-panel-desktop-widget>)
                     -- what the registry is keyed by, and what a module that does
                     not import the class writes
  a CLASS            <network-panel-desktop-widget> -- what the module that
                     DEFINES the class writes, with nothing to spell out
  'root              the root, which has no class of its own to name"
  (if (is-a? name <class>)
      (find (lambda (w) (eq? (class-of w) name)) (map cdr %desktop-widgets))
      (let ((pair (assoc name %desktop-widgets)))
        (and pair (cdr pair)))))

(define (desktop-widget-required name)
  "The widget called NAME, or an error that says which one was missing.

A bar item that opens a panel reaches for it by name, and the two are separate
widgets -- so the lookup can fail for a real reason: a registration file that
does not list the panel, or a name that has drifted from what the item asks
for.  The error names it rather than leaving a `no applicable method for
widget-name' three calls further on."
  (or (desktop-widget-named name)
      (error (format #f "no widget called ~s is registered (have: ~s)"
                     name (desktop-widget-names)))))

(define (unregister-desktop-widgets!)
  "Forget every registered widget.

For a test that wants a known registry, and for a shell rebuilding itself."
  (set! %desktop-widgets '())
  #t)

(define (unregister-desktop-widget! name)
  "Drop the widget called NAME from the registry; #t when there was one.

The single-name form, because the root has to be able to take a widget OUT when
a user's list stops naming it.  `unregister-desktop-widgets!' -- every one of
them -- is not that operation, and using it would throw away the widgets the
user DID ask for."
  ;; THE KEY AS GIVEN: a qualified name, or 'root.  It used to be turned into a
  ;; string, back when the registry was keyed by short-name strings.
  (let* ((key name)
         (before (length %desktop-widgets)))
    (set! %desktop-widgets
          (filter (lambda (pair) (not (equal? (car pair) key))) %desktop-widgets))
    (> before (length %desktop-widgets))))

;;; ---------------------------------------------------------------------------
;;; The root widget -- the custodian of which widgets are live
;;; ---------------------------------------------------------------------------
;;
;; WHAT WAS WRONG BEFORE.  `(scheme-desktop widgets)' did `(make <x>)' fifteen
;; times at import, so every widget the shell could ever draw was instantiated
;; before anything -- the user, the config file -- had an opinion.  A user who
;; wanted no tray got a tray.  The list of live widgets is the USER's decision
;; and it belongs in the user's config, which means something has to read it and
;; act on it, and that something cannot be a top-level form in a module: a module
;; is read once per process and can hold no opinion about a file.
;;
;; SO THE ROOT WIDGET OWNS IT.  A root is an ordinary <desktop-widget> whose
;; option is the list of names, and whose job is the three things the static
;; code was doing: instantiate what is listed, keep the registry equal to that
;; list, and attach the per-widget machinery as it goes.  It is the ONE special
;; case -- it cannot load itself -- and it replaces the two there were (the
;; static list in the shell, and the bar registering itself lazily from inside
;; its own accessor).
;;
;; THE CLASSES STAY IN COMPILED CODE.  A root resolves a NAME to a class through
;; GOOPS at run time -- `module-ref' then `make' -- rather than through a factory
;; table.  The classes are what a shell SHIPS and cannot change while it runs; the
;; instances are what a user CHOOSES, and those are made, unmade and remade on
;; demand.

;; FROM A QUALIFIED NAME TO A CLASS, by loading the module the name gives.
;;
;; There used to be ONE module a shell named, which had to import every widget
;; class so they could be looked up there -- which is what a plugin cannot do: it
;; is not imported by anything.  A qualified name says where its class is, so
;; there is nothing to set up and nothing a plugin has to register with.
(define (widget-class-named name)
  "The class NAME denotes.  NAME is a qualified name,
'(scheme-desktop widgets network <network-panel-desktop-widget>), or a class.

THE MODULE IS LOADED IF IT IS NOT ALREADY -- `resolve-interface' does that, from
the load path, which is how a plugin's widgets come to exist.

A name with no class RAISES and says which name and why, because the alternative
-- a widget that silently is not there -- is the bug this whole section is about."
  (cond
   ((is-a? name <class>) name)
   ((and (list? name) (>= (length name) 2) (symbol? (last name)))
    (let* ((module-name (drop-right name 1))
           (iface (catch #t
                    (lambda () (resolve-interface module-name))
                    (lambda (key . args)
                      (error "no module for widget" name key args)))))
      (or (catch #t (lambda () (module-ref iface (last name))) (lambda args #f))
          (error "the module does not export the widget class" module-name (last name)))))
   (else (error "not a qualified widget name -- (module ... <class>)" name))))

(define-class <root-desktop-widget> (<desktop-widget>)
  ;; THE LIST, and it is an ordinary config option like any other: it appears in
  ;; the file, it is overridable from the user's own code, and changing it ticks.
  ;; The DEFAULT belongs to the shell -- it is the set that shell ships -- so a
  ;; shell subclasses this and gives the slot its own `#:init-value'; an empty
  ;; default here would mean a shell with no widgets until someone wrote a file.
  (widgets #:init-value '() #:init-keyword #:widgets
           #:accessor root-widgets #:setter root-widgets-set!
           #:config '(list) #:label "Which widgets are live"))

;; THE ROOT'S NAME IS FIXED, NOT DERIVED, and it is the one widget that can say
;; so.  Every other name comes from the class -- `<clock-desktop-widget>' is
;; "clock" -- which is what lets a shell add a widget without naming it twice.
;; The root cannot: a shell SUBCLASSES this class to give it the shipped list,
;; and its subclass cannot also be called `<root-desktop-widget>' without
;; colliding with the class it is subclassing.  So the name is a property of the
;; ROLE -- there is one root, the config file says `(root (widgets ...))', and a
;; name a user writes in a file must not depend on what a shell called its
;; subclass.
;; The root is `root': it is the shell's entry point rather than a widget anyone
;; installs, and a config path starts from it -- '(() root widgets ()).
(define-method (widget-name (w <root-desktop-widget>)) 'root)

(define-method (root-sync! (r <root-desktop-widget>))
  "Make the registry equal what R lists: create what is missing, drop the rest.

IDEMPOTENT, and that matters more than it looks: this runs at startup, on every
reload, and whenever the list itself changes, and it must be safe to run when
nothing has changed -- which is the usual case.

ONLY THE WIDGETS THAT CHANGED ARE TOUCHED.  A widget whose name is still in the
list keeps the object it had, so an unchanged list costs a walk of the names and
nothing else -- no teardown, no construction.  A widget added to the list is
made; a widget removed from it is dropped.

THE ROOT IS NEVER DROPPED, even if its own list omits it.  A root that removed
itself would leave nothing to consult the list, so the list is about what the
root loads, not about the root.

A widget being dropped is DISPOSED FIRST -- its windows destroyed -- because a
widget that is no longer live must not leave a window behind.  Dropping the
registry entry alone would be the quiet kind of leak: the widget stays on screen
and nothing can reach it."
  ;; THE NAMES ARE QUALIFIED, and each is resolved to its class by loading its
  ;; module.  A NAME THAT CANNOT BE RESOLVED -- a plugin that was removed, a
  ;; module with an error in it -- COSTS THAT WIDGET, NOT THE SHELL: it is
  ;; reported and left out, and every other widget is still made.  One broken
  ;; plugin taking the bar down with it would make installing plugins a gamble.
  (let* ((resolved (filter-map
                    (lambda (name)
                      (catch #t
                        (lambda () (cons name (widget-class-named name)))
                        (lambda (key . args)
                          (format (current-error-port)
                                  "scheme-toolkit: cannot load widget ~s: ~a ~s~%"
                                  name key args)
                          #f)))
                    (root-widgets r)))
         (want (map car resolved)))
    ;; OUT first, so a name that moved is created fresh rather than mistaken for
    ;; one that is already there.
    (for-each (lambda (n)
                (unless (or (member n want) (equal? n (widget-name r)))
                  (let ((w (desktop-widget-named n)))
                    (when w
                      (catch #t (lambda () (widget-destroy-windows! w)) (lambda args #f))
                      (unregister-desktop-widget! n)))))
              (desktop-widget-names))
    ;; IN, one instance per name, given its qualified name BEFORE it is registered
    ;; -- the registry keys it by that name.
    (for-each (lambda (pair)
                (unless (desktop-widget-named (car pair))
                  (let ((w (make (cdr pair))))
                    (widget-qualified-name-set! w (car pair))
                    (register-desktop-widget! w))))
              resolved)
    (desktop-widget-names)))

;;; ---------------------------------------------------------------------------
;;; The widget set changed
;;; ---------------------------------------------------------------------------
;;
;; THE OTHER ROOT-LEVEL EVENT.  A teardown says "everything you built is gone";
;; this says "the set of widgets is different now" -- one was added, one was
;; dropped -- and a widget that builds trees from the registry has to look again.
;;
;; IT IS WHAT REPLACED REBUILDING THE SHELL.  A change to the root's list used to
;; call the shell's rebuild, which tore down every bar to make one widget appear.
;; The bar can now reconcile its own sections, so the honest message is the one
;; above: the model changed, re-look.
;;
;; DEFAULT NO-OP, like `widget-decommission!': most widgets build their trees
;; from their own options and have nothing to re-look at.
(define-generic widget-registry-changed!)
(define-method (widget-registry-changed! (w <desktop-widget>))
  "The set of live widgets changed; re-look at whatever W built from it."
  #t)

(define (widgets-registry-changed!)
  "Tell every registered widget that the set of widgets changed.

AFTER the sync, never before: a widget re-looks by asking the registry what
exists, so the registry has to be right first.

Each is caught separately, for the same reason the teardown's are: one widget
that mishandles the news must not stop the rest of them hearing it."
  (for-each (lambda (w)
              (catch #t (lambda () (widget-registry-changed! w)) (lambda args #f)))
            (desktop-widgets))
  (length (desktop-widgets)))

;; The shell's rebuild, and whether one is already queued.
;;
;; STILL CALLED, BUT NO LONGER FOR THIS.  A shell may register something here to
;; run after a set change -- re-presenting windows, say -- but the change itself
;; no longer needs a rebuild, and no shell this toolkit ships asks for one.
(define %root-on-change #f)
(define %root-change-pending #f)

(define (%root-set-changed! r)
  "The list changed: sync the registry, then tell the widgets, ONCE.

DEFERRED, and that is not tidiness.  The tick fires from inside whatever changed
the slot -- a config file being applied, a poke from the REPL, the user's own
code -- and doing this THERE would destroy windows in the middle of that work,
with a file loader still walking it.

COALESCED: the flag makes the second and later ticks no-ops, so several changes
to one list are one pass.

MEASURED, AND IT IS WHY THE PROPAGATION IS PART OF THIS RATHER THAN A REBUILD.
Syncing the registry WITHOUT doing anything about the views SEGFAULTS the shell
-- not a warning, a core dump.  Dropping a widget destroys its windows, and the
bar's resolved layout and the trees it built still hold that widget, so the next
thing that walks them dereferences freed memory.  What fixes that is not a
rebuild but this message: the bar re-looks, sees the widget is gone, and drops
the tree that referred to it.  The order is the whole of it -- SYNC, then tell."
  (unless %root-change-pending
    (set! %root-change-pending #t)
    (g-idle-add
     (lambda ()
       (set! %root-change-pending #f)
       (catch #t
         (lambda ()
           ;; THE MODEL, IN THE ROOT'S OWN HANDS.  It is the root's list, so the
           ;; root is what makes the registry match it.
           (root-sync! r)
           ;; THEN THE VIEWS.  Every widget that built something out of the
           ;; registry re-looks and reconciles -- which is what the bar does, and
           ;; what makes this a set change rather than a teardown.
           (widgets-registry-changed!)
           ;; AND LAST, WHATEVER A SHELL REGISTERED.  Optional now: the change
           ;; itself no longer needs a shell to do anything.
           (when %root-on-change (%root-on-change)))
         (lambda (key . rest)
           (log-error (cons key rest) "changing the live widget set")))
       ;; GLib drops a source that returns #f.
       #f))))

(define* (root-start! r #:key on-change)
  "Start R: make the live set match its list, and keep it matching.

CALLED ONCE by the shell, just after it has made its root, and it does the two
things a custodian has to do.

IT SYNCS NOW, so the shell has its widgets before anything tries to use them --
in particular before the config file is read, because several of those widgets
are what the file's options are applied TO.

IT SUBSCRIBES TO ITS OWN `widgets' TICK, which is what makes the list a live
option rather than a startup setting.  A change -- from a settings widget, from
the user's own code, or from the file -- syncs and then asks the shell to
rebuild.

ON-CHANGE IS THE SHELL'S REBUILD -- its own reload outlet, the same one its bar
layout option uses.  It is a THUNK rather than something this module reaches for,
because rebuilding the views is a shell's business: the toolkit knows the widget
model and nothing about centerboxes or layer surfaces."
  (set! %root-on-change on-change)
  (root-sync! r)
  (create-root
   (lambda (dispose)
     ;; `widget-config-tick' answers the accessor and its setter as a PAIR --
     ;; `car' is the accessor, which is what a subscriber reads through.
     (subscribe (car (widget-config-tick r 'widgets))
                (lambda () (%root-set-changed! r)))))
  #t)
