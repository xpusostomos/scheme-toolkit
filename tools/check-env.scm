#!/usr/bin/env guile
!#
;;; tools/check-env.scm -- standalone environment diagnostic
;;;
;;; Deliberately self-contained: it must run and report even when
;;; (scheme-toolkit gi) cannot be loaded, because "the module won't load" is
;;; itself one of the failures worth diagnosing.  Run it directly:
;;;
;;;   scheme-toolkit/check-env
;;;
;;; or without any environment at all, to see what a bare guile does:
;;;
;;;   env -u LD_PRELOAD -u LD_LIBRARY_PATH -u GI_TYPELIB_PATH \
;;;       scheme-toolkit/check-env

(eval-when (expand load eval)
  (default-duplicate-binding-handler
    '(merge-generics replace warn-override-core warn last)))

(use-modules (ice-9 format) (srfi srfi-1) (oop goops) (g-golf))

(define (say fmt . args)
  (apply format #t fmt args)
  (newline))

;; Guile's format has no left-justify flag, so pad by hand.  Taking the label
;; and the detail as separate arguments keeps the call sites readable and
;; avoids splitting a formatted string back apart.
(define (pad-right s width)
  (let ((s (if (string? s) s (format #f "~a" s))))
    (if (>= (string-length s) width)
        s
        (string-append s (make-string (- width (string-length s)) #\space)))))

(define (fail label detail)
  (display "  ")
  (display (pad-right label 26))
  (display detail)
  (newline))

(define (getenv-non-empty name)
  (let ((v (getenv name)))
    (and v (not (string=? v "")) v)))

(define (path-contains? path needle)
  (and path
       (let ((n (string-length needle)) (len (string-length path)))
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

;;; ---------------------------------------------------------------------------

(define problems '())
(define (problem! fmt . args)
  (set! problems (cons (apply format #f fmt args) problems)))

(say "== environment ==")
(say "  Guile             ~a" (version))
(say "  LD_LIBRARY_PATH   ~a" (or (getenv-non-empty "LD_LIBRARY_PATH") "(unset)"))
(say "  GI_TYPELIB_PATH   ~a" (or (getenv-non-empty "GI_TYPELIB_PATH") "(unset)"))
(say "  LD_PRELOAD        ~a" (or (getenv-non-empty "LD_PRELOAD") "(unset)"))
(say "  XDG_RUNTIME_DIR   ~a" (or (getenv-non-empty "XDG_RUNTIME_DIR") "(unset)"))
(say "  WAYLAND_DISPLAY   ~a" (or (getenv-non-empty "WAYLAND_DISPLAY") "(unset)"))

(say "")
(say "== required paths ==")

(unless (path-contains? (getenv-non-empty "LD_LIBRARY_PATH") "/usr/local/lib")
  (problem! "LD_LIBRARY_PATH lacks /usr/local/lib (astal is not in ldconfig)")
  (fail "LD_LIBRARY_PATH" "MISSING /usr/local/lib"))
(unless (path-contains? (getenv-non-empty "GI_TYPELIB_PATH")
                        "/usr/local/lib/girepository-1.0")
  (problem! "GI_TYPELIB_PATH lacks /usr/local/lib/girepository-1.0")
  (fail "GI_TYPELIB_PATH" "MISSING /usr/local/lib/girepository-1.0"))

(let* ((pre (getenv-non-empty "LD_PRELOAD"))
       (has? (and pre
                  (any (lambda (p) (string=? (basename p) "libgtk4-layer-shell.so"))
                       (string-split pre #\:)))))
  (if has?
      (fail "LD_PRELOAD" "libgtk4-layer-shell.so present")
      (begin
        (problem! "libgtk4-layer-shell.so is not preloaded")
        (fail "LD_PRELOAD" "MISSING libgtk4-layer-shell.so")
        (fail "" "-> anchors/exclusivity will silently no-op"))))

(unless (getenv-non-empty "XDG_RUNTIME_DIR")
  (problem! "XDG_RUNTIME_DIR is unset; the REPL socket has nowhere safe to live")
  (fail "XDG_RUNTIME_DIR" "MISSING (needed for the REPL socket)"))

(say "")
(say "== gsettings schemas ==")
(if (file-exists? "/usr/local/share/glib-2.0/schemas/gschemas.compiled")
    (fail "gschemas.compiled" "present")
    (begin
      (problem! "Astal GSettings schema is not compiled; AstalNotifd will abort")
      (fail "gschemas.compiled" "MISSING")
      (fail "" "fix: sudo glib-compile-schemas /usr/local/share/glib-2.0/schemas/")))

;;; ---------------------------------------------------------------------------
;;; Typelib import, with binding-count assertions
;;; ---------------------------------------------------------------------------

(say "")
(say "== typelibs ==")

;; G-Golf binds a type under a Scheme name derived from its GI name.  The rule
;; is <kebab(namespace + type)>, so Astal.Window is <astal-window> and
;; AstalBattery.UPower is <astal-battery-upower>.  AstalIO.Process is the one
;; exception on this machine (<astal-io-process>, from its C prefix).
;;
;; Rather than encode a rule with exceptions, try the plausible names and see
;; which one appeared.  "Imported but nothing new appeared" is exactly the
;; silent enum-only degradation, and a candidate list detects it without having
;; to be right about the naming rule.
(define (camel->kebab name)
  "CamelCase to kebab-case: a dash goes before an uppercase letter only when it
follows a lowercase letter, so the IO in AstalIO does not produce a double
dash.  Underscores become dashes, so find_output_by_gdk_monitor ->
find-output-by-gdk-monitor.  Digits stay attached to the word they follow, so
AstalWl4 -> astal-wl4."
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
           ;; lowercase and digits alike continue the current word
           (loop (cdr chars)
                 (cons (car chars) out)
                 (char-lower-case? (car chars)))))))

(define (candidate-names namespace type-name)
  "Every plausible Scheme name G-Golf might have bound TYPE-NAME under.  The
general rule is namespace+type (<astal-wp-wp>, <gtk-application>), but two
cases differ on this machine: AstalIO.Process binds as <astal-io-process>
(its C type name, not namespace+type) and a function binds without angle
brackets under the namespace prefix (astal-wl4-find-output-by-gdk-monitor).
Rather than be right about the rule, try the shapes and see which appeared."
  (let* ((kebab (camel->kebab (string-append namespace type-name)))
         ;; G-Golf binds namespace+type, so AstalBattery.UPower is
         ;; <astal-battery-upower>.  AstalIO.Process is an exception: it binds
         ;; under its C type name, <astal-io-process>, which splitting the
         ;; namespace at its CamelCase boundary reproduces.
         (ns-kebab (camel->kebab namespace))
         (concat (string-append ns-kebab "-" (camel->kebab type-name))))
    (list (string->symbol (string-append "<" concat ">"))
          (string->symbol (string-append "<" kebab ">"))
          (string->symbol concat)
          (string->symbol kebab))))

(define (import-and-ref namespace type-name)
  "Require NAMESPACE and import TYPE-NAME.  Return the Scheme name it bound, or
#f if nothing new appeared (the silent enum-only degradation)."
  (g-irepository-require namespace)
  (gi-import-by-name namespace type-name)
  (find (lambda (cand) (module-bound? (current-module) cand))
        (candidate-names namespace type-name)))

;; A namespace that imports but binds nothing is the silent "enums only"
;; degradation, so each one is checked for a known class rather than for
;; "did the require succeed".
(define (check namespace class-name)
  (call-with-values
    (lambda ()
      (catch #t
        (lambda ()
          (let ((sym (import-and-ref namespace class-name)))
            (if sym
                (values 'ok (format #f "~a bound as ~a" class-name sym))
                (values 'enum-only class-name))))
        (lambda (key . args) (values 'error (car args)))))
    (lambda (status detail)
      (case status
        ((ok) (fail namespace detail))
        ((enum-only)
         (problem! (format #f "~a imported but ~a is not bound (enum-only mode)"
                          namespace detail))
         (fail namespace (format #f "ENUM-ONLY, ~a missing" detail)))
        (else
         (problem! (format #f "~a failed to load: ~a" namespace detail))
         (fail namespace (format #f "FAILED: ~a" detail)))))))

;; (namespace . a class to prove the import really worked)
(for-each (lambda (pair) (check (car pair) (cdr pair)))
          '(("Gtk"                . "Application")
            ("Astal"              . "Window")
            ("AstalIO"            . "Process")
            ("AstalHyprland"      . "Hyprland")
            ("AstalBattery"       . "UPower")
            ("AstalNetwork"       . "Network")
            ("AstalBluetooth"     . "Bluetooth")
            ("AstalWp"            . "Wp")
            ("AstalMpris"         . "Mpris")
            ("AstalTray"          . "Tray")
            ("AstalPowerProfiles" . "PowerProfiles")
            ("AstalApps"          . "Apps")
            ("AstalWorkspace"     . "WorkspaceManager")
            ("AstalWl4"           . "find_output_by_gdk_monitor")
            ("AstalBrightness"    . "Brightness")))

;;; ---------------------------------------------------------------------------
;;; Compositor protocols
;;; ---------------------------------------------------------------------------

(say "")
(say "== compositor protocols ==")

(define (support namespace proc-name)
  (catch #t
    (lambda ()
      (let ((sym (import-and-ref namespace proc-name)))
        (if (not sym)
            "not bound"
            (let ((p (module-ref (current-module) sym)))
              (if (and (procedure? p) (p)) "yes" "no")))))
    (lambda args "unavailable")))

(fail "ext-workspace-v1" (support "AstalWorkspace" "is_supported"))
(fail "ext-idle-notify-v1" (support "AstalIdleNotify" "is_supported"))

;;; ---------------------------------------------------------------------------
;;; Live services
;;; ---------------------------------------------------------------------------

(say "")
(say "== live services ==")

;; Reaching get_default() also proves the daemon on the other end of the bus is
;; actually running, which a typelib check cannot.
(define (service namespace proc-name)
  (catch #t
    (lambda ()
      (let ((sym (import-and-ref namespace proc-name)))
        (if (not sym)
            "not bound"
            (let ((p (module-ref (current-module) sym)))
              (if (not (procedure? p))
                  "not callable"
                  (let ((obj (p)))
                    (if obj
                        (format #f "ok (~a)" (class-name (class-of obj)))
                        "returned nothing")))))))
    (lambda (key . args) (format #f "unavailable: ~a" (car args)))))

(fail "Hyprland" (service "AstalHyprland" "get_default"))
(fail "Battery" (service "AstalBattery" "get_default"))
(fail "Network" (service "AstalNetwork" "get_default"))
(fail "Wp (audio)" (service "AstalWp" "get_default"))
(fail "WorkspaceManager" (service "AstalWorkspace" "get_default"))

;;; ---------------------------------------------------------------------------

(say "")
(if (null? problems)
    (begin (say "ALL GREEN") (exit 0))
    (begin
      (say "~a problem~:p:" (length problems))
      (for-each (lambda (p) (say "  - ~a" p)) (reverse problems))
      (exit 1)))
