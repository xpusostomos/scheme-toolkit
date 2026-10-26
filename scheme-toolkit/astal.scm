;;; (scheme-toolkit astal) -- singletons and accessors for the Astal services
;;;
;;; Thin by design.  Astal is the backend and is not reimplemented: what a shell
;;; needs from a service namespace is (a) the one get_default() instance, (b)
;;; confirmation that the namespace works on this machine at all, and (c) an
;;; accessor or two so a widget can bind to a property.  Anything more belongs
;;; in the shell, which knows which properties its UI actually shows.
;;
;;; The counter-example that shapes this: the HyprYou shell hand-rolls network
;;; (911 lines), tray (557), mpris (425) and upower (248) because it does not
;;; use Astal.  None of that is here, and none of it should be.
;;;
;;; Singletons are memoised.  get_default() is cheap but not free, and calling
;;; it from a widget's build path on every rebuild is a needless dbus round
;;; trip.

(define-module (scheme-toolkit astal)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (ice-9 format)

  #:export (service-instance
            hyprland battery network bluetooth wp mpris tray notifd
            power-profiles workspace-manager brightness cava
            ;; convenience accessors, bound to a property and returning an
            ;; accessor that a widget can drop straight into #:label
            battery-percentage battery-charging? battery-state
            speaker-volume speaker-muted? speaker-volume-set!
            microphone-volume microphone-muted?
            hyprland-focused-client hyprland-clients
            workspaces focused-workspace
            print-services))

;;; ---------------------------------------------------------------------------
;;; The service table
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
            %services))

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
(define (hyprland) (service-instance 'hyprland))
(define (battery) (service-instance 'battery))
(define (network) (service-instance 'network))
(define (bluetooth) (service-instance 'bluetooth))
(define (wp) (service-instance 'wp))
(define (mpris) (service-instance 'mpris))
(define (tray) (service-instance 'tray))
(define (notifd) (service-instance 'notifd))
(define (power-profiles) (service-instance 'power-profiles))
(define (workspace-manager) (service-instance 'workspace-manager))
(define (brightness) (service-instance 'brightness))
(define (cava) (service-instance 'cava))

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

;;; ---------------------------------------------------------------------------
;;; Convenience accessors
;;; ---------------------------------------------------------------------------
;;;
;;; Each returns an ACCESSOR, so it can be dropped straight into a widget
;;; property and will update: (label #:label (battery-percentage)).

(define (battery-percentage)
  "Battery charge as a number 0-1, or #f."
  (bind-obj (battery) "percentage" 'battery-percentage))

(define (battery-charging?)
  (bind-obj (battery) "charging" 'battery-charging?))

(define (battery-state)
  (bind-obj (battery) "state" 'battery-state))

;; The sink and source are separate objects reached through Wp, so these go
;; one level deeper than the rest.  `slot-ref' on the object's own property,
;; with #f when there is no audio server at all.
(define (wp-default prop)
  (let ((w (wp)))
    (and w
         (catch #t (lambda () (slot-ref w (string->symbol prop)))
                (lambda args #f)))))

(define (speaker-volume)
  "The default sink's volume, 0-1."
  (bind-obj (wp-default "default-speaker") "volume" 'speaker-volume))

(define (speaker-muted?)
  (bind-obj (wp-default "default-speaker") "mute" 'speaker-muted?))

(define (speaker-volume-set! v)
  "Set the default sink's volume.  A COMMAND, not a reactive setter -- hence the
bang -- because the value lives in WirePlumber, not in this process."
  (let ((sink (wp-default "default-speaker")))
    (when sink
      (catch #t (lambda () (slot-set! sink 'volume v)) (lambda args #f)))))

(define (microphone-volume)
  (bind-obj (wp-default "default-microphone") "volume" 'microphone-volume))

(define (microphone-muted?)
  (bind-obj (wp-default "default-microphone") "mute" 'microphone-muted?))

(define (hyprland-focused-client)
  (bind-obj (hyprland) "focused-client" 'focused-client))

(define (hyprland-clients)
  (bind-obj (hyprland) "clients" 'clients))

(define (workspaces)
  "The workspace list, from AstalWorkspace when the compositor supports
ext-workspace-v1 and from AstalHyprland otherwise.

That fallback is the whole reason this is a procedure rather than a binding:
which object to bind to is decided at run time."
  (if (astal-supported? 'workspace)
      (bind-obj (workspace-manager) "workspaces" 'workspaces)
      (bind-obj (hyprland) "workspaces" 'workspaces)))

(define (focused-workspace)
  (if (astal-supported? 'workspace)
      (bind-obj (workspace-manager) "focused-workspace" 'focused-workspace)
      (bind-obj (hyprland) "focused-workspace" 'focused-workspace)))

;;; ---------------------------------------------------------------------------
;;; Diagnostics
;;; ---------------------------------------------------------------------------

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
