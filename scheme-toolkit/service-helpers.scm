;;; (scheme-toolkit service-helpers) -- the Astal service machinery
;;;
;;; Astal is TWENTY LIBRARIES, one per service, each with its own typelib: the
;;; battery, the network, the tray, Hyprland, WirePlumber, and so on.  This
;;; module is the part they all share -- finding a service's singleton, and the
;;; two helpers the service modules are written with -- and each service's own
;;; interface lives in (scheme-toolkit services THAT-SERVICE).
;;;
;;; NAMED FOR WHAT IT DOES AND NOT FOR ASTAL, because that is what this is: a
;;; sensible
;;; split of the functionality, which happens to be Astal's split today.  A
;;; module here may grow to answer more than its Astal library does -- the
;;; battery one is the obvious candidate -- and nothing about the names would
;;; have to change when it does.
;;;
;;; ONE MODULE PER LIBRARY, INCLUDING THE ONES NOTHING USES YET.  An empty one
;;; is a note to the next reader that the library exists and where its interface
;;; would go, which is worth more than the absence of a file.

(define-module (scheme-toolkit service-helpers)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit result)   ; `attempt', which service-instance guards with
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)

  #:export (service-instance bind-obj as-list print-services))

;;; ---------------------------------------------------------------------------
;;;
;;; (key namespace get-default-function class)
;;;
;;; The function name is the kebab-cased C identifier, which is how G-Golf
;;; names a function bound from a namespace whose prefix differs from it --
;;; e.g. AstalWl4's functions are astal-wl4-*.

(define %services
  '((hyprland         "AstalHyprland"      "astal-hyprland-get-default")
    (battery          "AstalBattery"       "astal-battery-get-default")
    (network          "AstalNetwork"       "astal-network-get-default")
    (bluetooth        "AstalBluetooth"     "astal-bluetooth-get-default")
    (wp               "AstalWp"            "astal-wp-get-default")
    (mpris            "AstalMpris"         "astal-mpris-get-default")
    (tray             "AstalTray"          "astal-tray-get-default")
    (notifd           "AstalNotifd"        "astal-notifd-get-default")
    (power-profiles   "AstalPowerProfiles" "astal-power-profiles-get-default")
    (workspace-manager "AstalWorkspace"    "astal-workspace-get-default")
    (brightness       "AstalBrightness"    "astal-brightness-get-default")
    (cava             "AstalCava"          "astal-cava-get-default")))

;; Import every get_default at LOAD time, into THIS module.
;;
;; Two things make the obvious version wrong.  gi-import-by-name binds into
;; whatever module is current when it runs, and `current-module' is dynamic --
;; calling it from a procedure that a user invoked from (guile-user) binds the
;; names there, and then module-ref here does not find them.  And GI needs the
;; importing module to have G-Golf's full surface in scope, which (scheme-toolkit
;; gi) now re-exports.  Importing here, once, at load, avoids both: the module
;; that ends up holding the bindings is this one, always.
(define %self (current-module))

(eval-when (load eval)
  (for-each (lambda (entry)
              (let ((ns (cadr entry)))
                (catch #t
                  (lambda ()
                    (g-irepository-require ns)
                    (gi-import-by-name ns "get_default"))
                  (lambda (key . args)
                    ;; A namespace that is not installed is an ordinary state,
                    ;; not an error: the service simply reports unavailable.
                    #f))))
            %services)
  ;; The Hyprland methods this module calls beyond get_default.  get_workspaces
  ;; is the one that matters: it returns a proper Scheme list where the
  ;; GList-valued `workspaces' property returns an opaque pointer.
  (catch #t
    (lambda ()
      (g-irepository-require "AstalHyprland")
      (for-each (lambda (m) (gi-import-by-name "AstalHyprland" m))
                '("get_workspaces" "get_clients" "get_monitors"
                  "get_focused_workspace" "get_focused_client")))
    (lambda args #f)))

(define %instances (make-hash-table))

(define (service-instance key)
  "The get_default() singleton for KEY ('battery, 'network, ...).

Returns #f when the namespace is not installed or the service is not running,
having logged why.  A desktop with no battery should not force every caller to
special-case it; the caller gets #f and moves on.

  (service-instance 'battery)   => the UPower object, or #f"
  (or (hashq-ref %instances key)
      (let ((entry (assq key %services)))
        (unless entry
          (error "service-instance: unknown service" key))
        (let* ((fn (caddr entry))
               (r (attempt
                   (lambda ()
                     (let ((f (module-ref %self (string->symbol fn))))
                       (f))))))
          (cond
           ((and (result-ok? r) (result-value r))
            (hashq-set! %instances key (result-value r))
            (result-value r))
           (else
            ;; Not cached: a service that is down now may be up later, and a
            ;; shell should notice without a restart.
            (when (and (result-ok? r) (not (result-value r)))
              (log-error (format #f "~a: get_default returned nothing" key)))
            #f))))))

;; Named accessors, so a shell writes (battery) rather than
;; (service-instance 'battery).

;;; ---------------------------------------------------------------------------
;;; A Binding that tolerates a missing service
;;; ---------------------------------------------------------------------------

(define* (bind-obj obj prop #:optional (name 'binding))
  "create-binding on OBJ, or an accessor of #f when OBJ is #f.

This is the shape most call sites want: the service may be absent, and a
widget bound to it should show nothing rather than fail to build."
  (if obj
      (create-binding obj prop name)
      (create-accessor (lambda () #f) name)))

(define (as-list value)
  "VALUE as a list, because G-Golf answers an EMPTY GList with #f and not '().

WHICH IS NOT WHAT ANY OF THESE PROMISE.  Every list getter here says \"as a list,
or '()\" and then hands back #f for an empty one, and the `catch' around each
getter does not cover it -- an empty list is not an error.

WHAT IT COSTS: `(filter-map ... (wifi-access-points))' with the radio switched off
died with `In procedure car: Wrong type argument in position 1 (expecting pair):
#f', and it took the whole shell with it -- the bar builds this list while it is
being assembled, so the crash is during startup and there is nothing above it to
catch it.  That is the bug that made `scheme-desktop' stop starting after the
switch turned the wifi off."
  (if (list? value) value '()))



(define* (print-services #:optional (port (current-output-port)))
  "Report which services are actually reachable.  The live version of
tools/check-env.scm's service section, for a running shell."
  (for-each (lambda (entry)
              (let ((obj (service-instance (car entry))))
                (format port "  ~a ~a~%"
                        (let ((s (symbol->string (car entry))))
                          (string-append s (make-string (max 1 (- 20 (string-length s))) #\space)))
                        (if obj
                            (format #f "ok (~a)" (class-name (class-of obj)))
                            "unavailable"))))
            %services))
