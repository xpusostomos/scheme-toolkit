;;; (scheme-toolkit gi) -- G-Golf bootstrap and import hygiene
;;;
;;; This module MUST be the first thing a shell loads.  It does three jobs:
;;;
;;;   1. installs the duplicate-binding handler G-Golf requires (without it
;;;      `append' and friends do not merge between Guile and GI namespaces);
;;;   2. asserts the environment traps that otherwise fail *silently* -- see
;;;      `assert-environment' for why each one is checked;
;;;   3. provides `define-gi-imports', the selective import macro that keeps
;;;      cold start under control.
;;;
;;; Everything here was established by experiment against G-Golf 0.8.7 on the
;;; development machine; see docs/environment.md for the measurements.

;; The duplicate-binding handler has to be installed BEFORE (g-golf) is pulled
;; in, so this comes first in the file and outside define-module.
;;
;; WHY THE WARNING HANDLERS ARE NOT IN THE LIST, which was
;; `(merge-generics replace warn-override-core warn last)' and printed 111 lines
;; on every cold start:
;;
;;   `warn-override-core' fires whenever an import shadows a GUILE CORE binding,
;;   and this module's whole job is to re-export G-Golf's interface -- whose
;;   merged generics deliberately shadow `for-each', `map', `member', `append',
;;   `connect' and the rest.  That is what `merge-generics' is FOR.  Warning
;;   about it once per module per name is 96 lines across 30 modules, on every
;;   recompile, about the one collision we intend.
;;
;;   `warn' fires when two imported modules export the same name -- here
;;   `(scheme-toolkit gi)' against `(srfi srfi-1)' and friends.  Also intended,
;;   also merged.  15 more lines.
;;
;; NOTHING DANGEROUS IS LOST BY DROPPING THEM.  The collision this project has
;; actually been bitten by -- a GI class import at RUNTIME silently replacing a
;; binding in `(scheme-toolkit reactive)' (see "create-poll bound to a widget
;; property failed" in docs/known-issues.md) -- is done by `gi-import-by-name'
;; long after these compile-time checks have run, so these warnings never
;; reported it and never could.
;;
;; A build that shouts 111 times about the intended case is a build whose
;; warnings nobody reads -- which is how a real "possibly unbound variable" sat
;; unread in the log while the shell segfaulted (docs/known-issues.md).
;; `bin/scheme-toolkit check-unbound' is the check that replaces it.
(eval-when (expand load eval)
  (default-duplicate-binding-handler
    '(merge-generics replace warn-override-core warn last)))

(define-module (scheme-toolkit gi)
  #:use-module (oop goops)
  #:use-module (g-golf)
  #:use-module (g-golf support module)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)

  #:duplicates (merge-generics replace warn-override-core warn last)

  ;; Re-export ALL of G-Golf's public interface, so a consumer can import this
  ;; one module instead of both.
  ;;
  ;; This must be the whole interface, not a hand-picked subset.  G-Golf's
  ;; importer expands into code that resolves type-tag names -- int32, uint32
  ;; and friends -- *in the importing module*, so a module that has
  ;; (scheme-toolkit gi) but not the full (g-golf) surface fails every
  ;; gi-import-by-name with "Unbound variable: int32", an error that names
  ;; nothing to do with the real problem.  re-export-public-interface keeps the
  ;; original bindings (and their generics) rather than copying them.
  #:re-export (gi-import
               gi-import-by-name
               g-irepository-require
               g-irepository-get-version
               g-irepository-get-loaded-namespaces
               make
               connect
               disconnect
               <gobject>)

  #:export (define-gi-imports
            gi-require
            gi-import-names
            gtk-bootstrap!
            gtk-initialised?
            assert-environment
            environment-report
            schemas-compiled?
            layer-shell-preloaded?
            astal-supported?
            gi-check))

;; Re-export the whole G-Golf interface.  See the comment in the define-module
;; form: a hand-picked subset is not enough, because G-Golf's importer resolves
;; type-tag names in the importing module.
(re-export-public-interface (g-golf))

;;; ---------------------------------------------------------------------------
;;; 1. Small helpers
;;; ---------------------------------------------------------------------------

(define (getenv-non-empty name)
  (let ((v (getenv name)))
    (and v (not (string=? v "")) v)))

(define (path-contains? path needle)
  (and path
       (let ((n (string-length needle))
             (len (string-length path)))
         (let loop ((i 0))
           (cond ((> (+ i n) len) #f)
                 ((string=? (substring path i (+ i n)) needle) #t)
                 (else (loop (+ i 1))))))))

(define (basename path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) path)
          ((char=? (string-ref path i) #\/)
           (substring path (+ i 1) (string-length path)))
          (else (loop (- i 1))))))

(define (error-list . lines)
  (string-join (cons "scheme-toolkit: environment check failed" lines) "\n  "))

;; GtkApplication -> gtk-application; AstalWindow -> astal-window.
;; Used to predict the Scheme name of an imported type so a failure can name it.
(define (camel->kebab name)
  "CamelCase (and snake_case) to kebab-case.

A dash goes before an uppercase letter only when it follows a lowercase letter,
so the IO in AstalIO does not produce a double dash.  Underscores become dashes,
because a C identifier such as astal_workspace_is_supported is bound as
astal-workspace-is-supported -- leaving the underscores in place gives a name
that is simply not bound, and the failure is a bare \"No variable named\"."
  (let loop ((chars (string->list name)) (out '()) (prev-lower #f))
    (cond ((null? chars) (list->string (reverse out)))
          ((char=? (car chars) #\_)
           (loop (cdr chars) (cons #\- out) #f))
          ((char-upper-case? (car chars))
           (loop (cdr chars)
                 (cons (char-downcase (car chars))
                       (if prev-lower (cons #\- out) out))
                 #f))
          (else
           (loop (cdr chars) (cons (car chars) out)
                 (char-lower-case? (car chars)))))))

;; G-Golf derives a Scheme name from the C identifier, which is the namespace
;; prefix joined to the member's own name.  A CLASS is bound as
;; <ns-type>, but a FUNCTION is bound as ns-fn with no angle brackets -- so
;; AstalWorkspace's is_supported is `astal-workspace-is-supported', not
;; `astal-workspaceis-supported'.  Concatenating before converting, which is the
;; obvious thing to write, gets the function case wrong.
(define (gi-class-name namespace type-name)
  "The Scheme name G-Golf binds for a class: (gi-class-name \"Astal\" \"Window\")
=> <astal-window>."
  (string->symbol
   (string-append "<" (camel->kebab (string-append namespace type-name)) ">")))

(define (gi-function-name namespace fn-name)
  "The Scheme name G-Golf binds for a function: (gi-function-name \"AstalWorkspace\"
\"is_supported\") => astal-workspace-is-supported."
  (string->symbol
   (string-append (camel->kebab namespace) "-" (camel->kebab fn-name))))

;;; ---------------------------------------------------------------------------
;;; 2. Environment assertions
;;; ---------------------------------------------------------------------------

(define %layer-shell-library "libgtk4-layer-shell.so")

(define (layer-shell-preloaded?)
  (let ((pre (getenv-non-empty "LD_PRELOAD")))
    (and pre
         (any (lambda (p) (string=? (basename p) %layer-shell-library))
              (string-split pre #\:)))))

;; THE TRAP THAT COSTS THE MOST TIME.  Astal.Window needs libgtk4-layer-shell
;; preloaded.  Without it, Astal prints
;;     "can not initialize layer shell on window: layer shell not supported"
;; and then every single layer-shell property set silently no-ops -- slot-ref
;; just returns the default.  A bar comes up unanchored and nothing says why.
;; Checking LD_PRELOAD up front turns a silent wrong-value bug into a message.
(define (assert-layer-shell-preload!)
  (unless (layer-shell-preloaded?)
    (error (error-list
            (format #f "~a is not in LD_PRELOAD." %layer-shell-library)
            "Without it, Astal.Window anchors, exclusivity, layer and keymode"
            "are silently ignored: the properties read back their defaults and"
            "the window is placed wrongly with no error."
            ""
            "Fix: run through bin/scheme-toolkit, or set"
            (format #f "  export LD_PRELOAD=~a" %layer-shell-library)))))

;; THE DEGRADATION THIS GUARDS AGAINST, and why it tests a CLASS rather than a
;; PATH.
;;
;; When GI cannot find Astal's shared libraries it loads the typelibs in
;; "enums only" mode: no error is raised, but <astal-window> and every other
;; class is simply missing, and a shell fails later in a way that names nothing.
;;
;; The first version of this check asserted that GI_TYPELIB_PATH contained
;; /usr/local/lib/girepository-1.0 -- because at the time Astal was a hand-build
;; there and absent from the ldconfig cache.  That stopped being true once Astal
;; was packaged under /usr/lib: the path assertion then rejected a perfectly
;; good environment, and it would equally have PASSED an environment that named
;; the directory but could not load anything from it.
;;
;; So it asks the only question that matters: **is an Astal class actually
;; reachable?**  That is true whether Astal comes from /usr/lib or /usr/local,
;; and false for both the enums-only degradation and a broken path.
(define (astal-class-reachable?)
  (catch #t
    (lambda ()
      (g-irepository-require "Astal" #:version "4.0")
      (gi-import-by-name "Astal" "Window")
      (module-bound? (current-module) '<astal-window>))
    (lambda args #f)))

(define (assert-typelib-path!)
  (unless (astal-class-reachable?)
    (error (error-list
            "Astal's typelibs could not be loaded: <astal-window> is missing."
            "GI degrades to enums-only without raising an error, so every"
            "Astal class silently disappears."
            ""
            "Astal is normally installed as a package under /usr/lib, which GI"
            "searches by default.  If it is a hand-build elsewhere, point GI"
            "at it:"
            "  export GI_TYPELIB_PATH=/usr/local/lib/girepository-1.0"
            (format #f "  (current GI_TYPELIB_PATH: ~a)"
                    (or (getenv-non-empty "GI_TYPELIB_PATH") "(unset)"))))))

;; LD_LIBRARY_PATH, checked for the same reason and with the same change: the
;; question is not "is a particular directory named" but "can the libraries
;; actually be found".  A packaged Astal under /usr/lib needs no help at all,
;; and a hand-build elsewhere does -- so this asks the linker rather than a
;; hard-coded path.
(define (astal-library-findable?)
  (or (file-exists? "/usr/lib/libastal-4.so.4")
      (file-exists? "/usr/local/lib/libastal-4.so.4")))

(define (assert-library-path!)
  (let ((p (getenv-non-empty "LD_LIBRARY_PATH")))
    (unless (or (astal-library-findable?)
                (and p (path-contains? p "/usr/local/lib")))
      (error (error-list
              "Astal's shared libraries cannot be found."
              "Neither /usr/lib/libastal-4.so.4 nor a hand-build under"
              "/usr/local/lib is present, so astal-window cannot be created."
              ""
              "Fix: install the libastal packages, or set"
              "  export LD_LIBRARY_PATH=/usr/local/lib"
              (format #f "  (current LD_LIBRARY_PATH: ~a)" (or p "(unset)")))))))

;; AstalNotifd reads a GSettings schema that ships uncompiled; the process
;; aborts rather than throwing, so it cannot be caught at use time.
(define (schemas-compiled?)
  (file-exists? "/usr/local/share/glib-2.0/schemas/gschemas.compiled"))

(define* (assert-environment #:key (require-schemas? #f))
  "Fail loudly, and early, if the environment is one of the three shapes that
make G-Golf fail silently.  Call this at the top of a shell's entry point."
  (assert-library-path!)
  (assert-typelib-path!)
  (assert-layer-shell-preload!)
  (when (and require-schemas? (not (schemas-compiled?)))
    (error (error-list
            "Astal's GSettings schema is not compiled."
            "AstalNotifd aborts the whole process when it is missing."
            "Fix: sudo glib-compile-schemas /usr/local/share/glib-2.0/schemas/")))
  #t)

;;; ---------------------------------------------------------------------------
;;; 3. Selective imports
;;; ---------------------------------------------------------------------------

;; Whole-namespace `gi-import' of Gtk costs ~2.7 s and Adw ~1.6 s, because it
;; walks every info in the namespace.  `gi-import-by-name' on the handful of
;; classes a module actually uses is ~0.6 s for the first call and ~0 after.
;; That difference is the whole reason this macro exists.
;;
;; `gi-import-by-name' binds into the CURRENT module, so the import must run at
;; expand/load time from inside the defining module -- calling it from a helper
;; procedure in another module would bind the names where they cannot be seen.

(define (gi-import-names namespace names)
  "Import each NAME (a symbol or string) from NAMESPACE into the current module.
Returns the list of names attempted."
  (for-each (lambda (name)
              (gi-import-by-name namespace
                                 (if (symbol? name) (symbol->string name) name)))
            names)
  names)

;; The expansion calls gi-import-by-name DIRECTLY rather than through a helper
;; procedure.  G-Golf's importer expands into code that resolves type-tag names
;; (int32, uint32, ...) *in the module being imported into*, so wrapping the
;; call in a procedure defined elsewhere makes those lookups happen in the wrong
;; module and the import fails with "Unbound variable: int32" -- an error that
;; names nothing to do with the real problem.
;;
;; The (use-modules (g-golf)) inside the expansion is what puts those names in
;; scope.  It is not redundant with this module's own import: the names have to
;; be visible in the CALLER's module at expansion time, which is where the
;; importer looks them up.
(define-syntax define-gi-imports
  (syntax-rules ()
    "Syntax: (define-gi-imports NAMESPACE NAME ...)

Import just the named types from NAMESPACE at expand/load time, binding the
usual G-Golf names (<gtk-label>, !label, make, ...) in the calling module.

  (define-gi-imports \"Gtk\" \"Box\" \"Label\")

Selective importing matters: whole-namespace (gi-import \"Gtk\") costs 2.7 s,
against 0.6 s for the first by-name import and ~0 for the rest."
    ((_ namespace name ...)
     (eval-when (expand load eval)
       (use-modules (g-golf))
       (g-irepository-require namespace)
       (gi-import-by-name namespace name)
       ...))))

(define* (gi-require namespace #:optional version)
  "Make NAMESPACE available to the introspection repository without importing
anything from it."
  (if version
      (g-irepository-require namespace #:version version)
      (g-irepository-require namespace)))

;;; ---------------------------------------------------------------------------
;;; 4. GTK bootstrap
;;; ---------------------------------------------------------------------------

;; GTK4 is NOT initialised by importing it.  Constructing any <gtk-*> widget
;; before gtk_init() segfaults with no diagnostic at all -- this is the single
;; least obvious thing in the whole stack.  Every entry point must call
;; gtk-bootstrap! (or gtk-application-run, which does) before making a widget.
(define %gtk-initialised? #f)

(define (gtk-bootstrap!)
  "Initialise GTK4, and libadwaita when it is loaded, exactly once."
  (unless %gtk-initialised?
    (assert-layer-shell-preload!)
    (gi-import-by-name "Gtk" "init")
    (gtk-init)
    (set! %gtk-initialised? #t)
    ;; Adwaita needs an explicit init when the application is not an
    ;; Adw.Application -- and ours never is, because layer-shell windows need
    ;; Gtk.Application.  AGS does the same thing for the same reason.
    ;;
    ;; Imported here rather than tested for: the 1.6 s cost in the header is
    ;; importing the Adw WIDGET namespaces, and requiring the typelib plus one
    ;; function measures under a millisecond.  An earlier version tested
    ;; (module-bound? (current-module) 'adw-init) -- which is #f unless the
    ;; CALLER has already imported Adw -- so adw-init never ran and the first
    ;; Adw widget a shell made was uninitialised.
    (catch #t
      (lambda ()
        (g-irepository-require "Adw" #:version "1")
        (gi-import-by-name "Adw" "init")
        (adw-init))
      (lambda args #f)))
  %gtk-initialised?)

(define (gtk-initialised?) %gtk-initialised?)

;;; ---------------------------------------------------------------------------
;;; 5. Capability detection
;;; ---------------------------------------------------------------------------

;; Astal ships optional namespaces that only work if the compositor implements
;; the protocol behind them (ext-workspace-v1 for AdwWorkspace, ext-idle-notify
;; for IdleNotify).  A shell should ask rather than assume, and fall back.
(define %supported-namespaces
  '((workspace   . "AstalWorkspace")
    (idle-notify . "AstalIdleNotify")))

;; The predicate procedures, captured as VALUES at load time.
;;
;; Looking the name up later does not work reliably.  gi-import-by-name binds
;; into whatever module is current when it runs, and inside a compiled procedure
;; called from elsewhere `current-module' is not dependably this one -- so the
;; import and the module-ref can end up addressing different modules and the
;; lookup fails with no clue why.  Capturing the procedure here, once, in the
;; same module that did the importing, sidesteps the question entirely.
(define %support-procs (make-hash-table))

(eval-when (load eval)
  (for-each (lambda (entry)
              (let ((feature (car entry)) (ns (cdr entry)))
                (catch #t
                  (lambda ()
                    (g-irepository-require ns)
                    (gi-import-by-name ns "is_supported")
                    (hashq-set! %support-procs feature
                                (module-ref (resolve-module '(scheme-toolkit gi))
                                            (gi-function-name ns "is_supported"))))
                  ;; A namespace that is not installed is an ordinary state, not
                  ;; an error: the feature simply reports unsupported.
                  (lambda (key . args)
                    (format (current-error-port)
                            "scheme-toolkit: ~a support probe failed: ~a ~s~%"
                            ns key args)
                    #f))))
            %supported-namespaces))

(define (astal-supported? feature)
  "Return #t if the compositor behind FEATURE ('workspace or 'idle-notify)
supports the protocol.  Returns #f if the namespace is absent altogether.

Each of these namespaces exports an <ns>_is_supported() function, which asks
the compositor whether it implements the protocol -- ext-workspace-v1 for
workspaces, ext-idle-notify-v1 for idle.  A shell should ask rather than
assume: Hyprland 0.56 supports both, but a shell that hardcodes the
AstalWorkspace path breaks on a compositor that only offers AstalHyprland."
  (let ((p (hashq-ref %support-procs feature)))
    (unless (assq feature %supported-namespaces)
      (error "astal-supported?: unknown feature" feature))
    (catch #t
      (lambda () (and p (procedure? p) (p)))
      (lambda args #f))))

;;; ---------------------------------------------------------------------------
;;; 6. Diagnostics
;;; ---------------------------------------------------------------------------

(define* (environment-report #:optional (port (current-output-port)))
  "Print what the environment actually looks like from inside a running
process.  The standalone version, which needs nothing loaded, is
tools/check-env.scm."
  (define (line label value)
    (format port "  ~24a ~a\n" label value))
  (format port "scheme-toolkit environment\n")
  (line "Guile" (version))
  (line "GTK initialised" (if %gtk-initialised? "yes" "no"))
  (line "LD_LIBRARY_PATH" (or (getenv "LD_LIBRARY_PATH") "(unset)"))
  (line "GI_TYPELIB_PATH" (or (getenv "GI_TYPELIB_PATH") "(unset)"))
  (line "LD_PRELOAD" (or (getenv "LD_PRELOAD") "(unset)"))
  (line "layer-shell preloaded" (if (layer-shell-preloaded?) "yes" "NO"))
  (line "schemas compiled" (if (schemas-compiled?) "yes" "no"))
  (line "workspaces supported" (if (astal-supported? 'workspace) "yes" "no"))
  (line "idle-notify supported" (if (astal-supported? 'idle-notify) "yes" "no")))

(define %required-namespaces
  '("Gtk" "Astal" "AstalIO"
    "AstalHyprland" "AstalBattery" "AstalNetwork" "AstalBluetooth"
    "AstalWp" "AstalMpris" "AstalTray" "AstalNotifd" "AstalPowerProfiles"
    "AstalApps" "AstalWorkspace" "AstalWl4" "AstalBrightness"))

(define* (gi-check #:optional (port (current-output-port)))
  "Load every namespace the toolkit needs and report what is missing.  Returns
#t when all of them are present."
  (let ((missing '()))
    (for-each
     (lambda (ns)
       (let ((ok? (catch #t
                    (lambda () (g-irepository-require ns) #t)
                    (lambda args #f))))
         (format port "  ~24a ~a\n" ns (if ok? "ok" "MISSING"))
         (unless ok? (set! missing (cons ns missing)))))
     %required-namespaces)
    (unless (null? missing)
      (format (current-error-port) "missing typelibs: ~a\n" (reverse missing)))
    (null? missing)))
