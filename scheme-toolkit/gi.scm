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
  (let loop ((chars (string->list name)) (out '()) (prev-lower #f))
    (cond ((null? chars) (list->string (reverse out)))
          ((char-upper-case? (car chars))
           (loop (cdr chars)
                 (cons (char-downcase (car chars))
                       (if prev-lower (cons #\- out) out))
                 #f))
          (else
           (loop (cdr chars) (cons (car chars) out) #t)))))

(define (gi-scheme-name namespace type-name)
  "The Scheme name G-Golf will bind for TYPE-NAME in NAMESPACE:
(g-golf-name \"Astal\" \"Window\") => astal-window."
  (string->symbol
   (camel->kebab (string-append namespace type-name))))

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

;; The Astal typelibs live in /usr/local and are NOT in the ldconfig cache, so
;; GI loads them only in "enums only" mode: no error, but <astal-window> and
;; every other class is simply missing.  Asserting a known class exists catches
;; the degradation that a "did it load?" test would not.
(define (assert-typelib-path!)
  (let ((p (getenv-non-empty "GI_TYPELIB_PATH")))
    (unless (and p (path-contains? p "/usr/local/lib/girepository-1.0"))
      (error (error-list
              "GI_TYPELIB_PATH does not include /usr/local/lib/girepository-1.0."
              "Astal's typelibs are installed there, and they are not in the"
              "ldconfig cache; without the path GI imports enums only and all"
              "Astal classes are missing.")))))

(define (assert-library-path!)
  (let ((p (getenv-non-empty "LD_LIBRARY_PATH")))
    (unless (and p (path-contains? p "/usr/local/lib"))
      (error (error-list
              "LD_LIBRARY_PATH does not include /usr/local/lib."
              "The astal shared libraries are not in the ldconfig cache, so"
              "GI must be told where they are.")))))

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
    (catch #t
      (lambda ()
        (when (module-bound? (current-module) 'adw-init)
          (adw-init)))
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

(define (astal-supported? feature)
  "Return #t if the compositor behind FEATURE ('workspace or 'idle-notify)
supports the protocol.  Returns #f if the namespace is absent altogether."
  (let ((ns (assq-ref %supported-namespaces feature)))
    (unless ns
      (error "astal-supported?: unknown feature" feature))
    (catch #t
      (lambda ()
        (g-irepository-require ns)
        ;; Each of these namespaces exports <ns>_is_supported().
        (gi-import-by-name ns "is_supported")
        (let ((p (module-ref (current-module) (gi-scheme-name ns "is_supported"))))
          (and (procedure? p) (p))))
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
         (format port "  ~-24a ~a\n" ns (if ok? "ok" "MISSING"))
         (unless ok? (set! missing (cons ns missing)))))
     %required-namespaces)
    (unless (null? missing)
      (format (current-error-port) "missing typelibs: ~a\n" (reverse missing)))
    (null? missing)))
