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
  #:use-module (ice-9 format)

  #:export (run-shell quit-shell
            app-instance
            layer-window window-set-anchored!
            windows window windows-named window-visible?
            toggle-window
            monitors for-each-monitor monitor-name monitor-geometry
            on-monitors-changed
            inspect
            unset-layer-shell-preload!))

(define-gi-imports "Gtk" "Application" "Window" "Settings")
(define-gi-imports "Gdk" "Display" "Monitor")
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
(define %windows '())

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
(define (unset-layer-shell-preload!)
  (catch #t
    (lambda () (g-unsetenv "LD_PRELOAD"))
    (lambda args #f)))

;;; ---------------------------------------------------------------------------
;;; Layer windows
;;; ---------------------------------------------------------------------------

(define* (layer-window name #:key
                       (anchor '(top left right))
                       (exclusivity 'exclusive)
                       (layer 'top)
                       (keymode 'none)
                       (gdkmonitor #f)
                       (namespace #f)
                       (class "Shell")
                       (margins #f)         ; (top right bottom left), or #f
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
                      #:application %app #:class class)
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
    (set! %windows (cons (cons name win) %windows))
    win))

(define (window-set-anchored! win anchor)
  "Set a window's anchor after construction, which is how a bar changes edge."
  (catch #t (lambda () (slot-set! win 'anchor anchor)) (lambda args #f))
  win)

(define (windows-named name)
  "Every window registered as NAME.  A per-monitor window has one per monitor."
  (filter (lambda (pair) (equal? (car pair) name)) %windows))

(define (window name)
  "The first window registered as NAME, or #f.  Use windows-named for all of
them."
  (let ((pair (assoc name %windows)))
    (and pair (cdr pair))))

(define (windows)
  "Every registered window, newest first."
  (map cdr %windows))

(define (window-visible? w)
  (catch #t (lambda () (slot-ref w 'visible)) (lambda args #f)))

(define (toggle-window name)
  "Show every window named NAME if all are hidden, hide them if any is shown.

This is the whole of AGS's `ToggleWindow' verb, and it is an ordinary procedure:
`scheme-toolkit eval '(toggle-window \"launcher\")'.

All the windows sharing a name move together, which is what a per-monitor bar
wants -- `(toggle-window \"bar\")' should not leave one monitor's bar behind."
  (let ((ws (windows-named name)))
    (if (null? ws)
        (begin
          (format (current-error-port)
                  "scheme-toolkit: toggle-window: no window named ~a~%" name)
          #f)
        (let ((target (not (any window-visible? (map cdr ws)))))
          (for-each (lambda (pair)
                      (catch #t
                        (lambda () (slot-set! (cdr pair) 'visible target))
                        (lambda args #f)))
                    ws)
          target))))

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

The Wayland output name where AstalWl4 can supply one, so that a bar can be
keyed by connector rather than by an index that shifts when a monitor is
unplugged.  Falls back to the geometry, which is at least stable while the
monitor is attached."
  (or (catch #t
        (lambda ()
          (g-irepository-require "AstalWl4")
          (gi-import-by-name "AstalWl4" "find_output_by_gdk_monitor")
          (let* ((f (module-ref (current-module) 'astal-wl4-find-output-by-gdk-monitor))
                 (out (f mon)))
            (and out (catch #t (lambda () (slot-ref out 'name)) (lambda args #f)))))
        (lambda args #f))
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

(define (for-each-monitor proc)
  "Call PROC with each connected monitor, keyed so that a monitor coming back
keeps its identity.

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
                  (unless (hash-ref %monitor-roots name)
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
;;; Starting
;;; ---------------------------------------------------------------------------

(define (inspect)
  "Open GTK's interactive inspector on the running shell."
  (catch #t
    (lambda ()
      (set-interactive-debugging #t)
      #t)
    (lambda (key . args)
      (format (current-error-port) "scheme-toolkit: cannot open the inspector: ~a~%"
              (car args))
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
  (when (catch #t (lambda () (register %app)) (lambda args #f))
    (format (current-error-port)
            "scheme-toolkit: ~a is already running; use `scheme-toolkit eval' to talk to it~%"
            instance)
    (exit 0))
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
                    (catch #t
                      (lambda () (present w))
                      (lambda (key . args)
                        (format (current-error-port)
                                "scheme-toolkit: cannot present window ~s: ~a ~s~%"
                                (catch #t (lambda () (slot-ref w 'name)) (lambda a '?))
                                key args))))
                  (windows))))))
  (run %app '()))

(define (try-start-repl! instance)
  "Start the back door if (scheme-toolkit repl) is loadable.

Resolved at run time rather than imported, so that a shell works even when that
module is not on the load path -- it is a development affordance, not a
dependency."
  (catch #t
    (lambda ()
      (let ((m (resolve-module '(scheme-toolkit repl) #:ensure #f)))
        (if m
            ((module-ref m 'start-repl!) #:instance instance)
            (begin
              (format (current-error-port)
                      "scheme-toolkit: (scheme-toolkit repl) not found; no back door~%")
              #f))))
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
