;;; (scheme-toolkit services hyprland) -- Hyprland (AstalHyprland)
;;;
;;; Monitors, clients and workspaces, read through AstalHyprland. Acting on
;;; Hyprland is not here -- that is the shell's (scheme-desktop hyprland),
;;; which owns the dispatch syntax.

(define-module (scheme-toolkit services hyprland)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:export (hyprland hyprland-focused-client hyprland-clients hyprland-monitors hyprland-client-list workspaces focused-workspace))

(define (hyprland-focused-client)
  (bind-obj (hyprland) "focused-client" 'focused-client))

(define (hyprland-clients)
  (bind-obj (hyprland) "clients" 'clients))

;; THE MONITORS AND THE CLIENT LIST AS ROOMS FULL OF THINGS, not as accessors.
;;
;; Two different questions need two different shapes. `hyprland-clients' above
;; is an accessor, for a widget that wants to re-render when the list changes.
;; These return the list NOW, for code that has to look at every monitor or
;; every window to decide what to draw -- which monitor is showing which
;; workspace, and which workspaces have windows on them.
;;
;; Both go through the METHOD rather than the property: the property versions
;; are GList-valued and G-Golf hands back an opaque pointer, which is the same
;; trap `workspaces' documents below.
;; --- the Wi-Fi device ------------------------------------------------------
;;
;; `get_default' is all the service table imports, and the wifi device is a
;; property of the NetworkManager object. These wrap the AccessPoint methods a
;; wifi list needs, so a shell reads `access-point-ref' rather than naming
;; G-Golf's `get-ssid' and hoping the module in scope has it.

(eval-when (load eval)
  (catch #t
    (lambda ()
      (g-irepository-require "AstalNetwork")
      (for-each (lambda (m) (gi-import-by-name "AstalNetwork" m))
                '("get_wifi" "get_access_points" "get_active_access_point"
                  "activate" "deactivate_connection" "get_ssid" "get_strength"
                  "get_frequency" "get_requires_password" "get_bssid"
                  "get_max_bitrate" "get_last_seen" "get_scanning"
                  "get_enabled" "get_icon_name" "get_connectivity"
                  "get_rsn_flags" "set_enabled" "scan")))
    (lambda args #f)))

(define (hyprland-monitors)
  "The connected Hyprland monitors, as a list, or '()."
  (let ((h (hyprland)))
    (if (not h)
        '()
        (catch #t (lambda () (as-list (get-monitors h))) (lambda args '())))))

(define (hyprland-client-list)
  "Every window Hyprland knows about, as a list, or '()."
  (let ((h (hyprland)))
    (if (not h)
        '()
        (catch #t (lambda () (as-list (get-clients h))) (lambda args '())))))

;; Workspaces come from AstalHyprland, NOT AstalWorkspace, even though
;; astal-supported? 'workspace answers #t on this machine.
;;
;; AstalWorkspace's `workspaces' property is a GList-valued boxed type, and
;; G-Golf has no converter for it: both (slot-ref wm 'workspaces) and the
;; generated getter fail with "Unimplemented boxed type".  The protocol is
;; there; the binding cannot read it.  AstalHyprland's `workspaces' returns a
;; GList that G-Golf DOES convert, so the fallback path is the working one and
;; is what this uses.
;;
;; If G-Golf gains a GList boxed-type converter, or AstalWorkspace exposes the
;; model differently, revisit: AstalWorkspace is the compositor-agnostic answer
;; and strictly better where it works.
(define (workspaces-source)
  "Which object to bind workspaces to.  Kept as a procedure so the choice is in
one place and visible when it changes."
  'hyprland)

(define (workspaces)
  "An accessor over the workspace list.  (st-peek (workspaces)) => a list of
workspace objects.

NOT a plain create-binding, because `workspaces' is a GList-valued property with
no notify signal, and (slot-ref h 'workspaces) returns an opaque foreign pointer
rather than a list.  The METHOD (get-workspaces h) does convert properly -- that
is the GList handling the plan predicted but which only the method implements.

So this reads through the method and re-reads on Hyprland's `event' signal,
filtering to the events that change the workspace set.  Re-reading on every
event would be wasteful: a window title change fires constantly and cannot
alter the list."
  (let ((value '())
        (subs (make-subs))
        (handler #f))

    (define (read)
      (catch #t
        (lambda ()
          (let ((v (get-workspaces (hyprland))))
            (if (list? v) v '())))
        (lambda args '())))

    (define (refresh!)
      (let ((new (read)))
        (unless (equal? (map workspace-name new) (map workspace-name value))
          (set! value new)
          (subs-notify! subs))))

    (let ((acc (create-accessor read 'workspaces
                                #:subscribe-fn
                                (lambda (thunk)
                                  (subs-add! subs thunk)
                                  (unless handler
                                    (set! value (read))
                                    (set! handler
                                          (connect (hyprland) 'event
                                                   (lambda (h event args)
                                                     (when (workspace-event? event)
                                                       (refresh!))))))
                                  (lambda ()
                                    (subs-remove! subs thunk)
                                    (when (and handler (zero? (subs-count subs)))
                                      (catch #t (lambda () (disconnect (hyprland) handler))
                                             (lambda a #f))
                                      (set! handler #f)))))))
      acc)))

(define (workspace-name ws)
  (catch #t (lambda () (slot-ref ws 'name)) (lambda args #f)))

;; Hyprland event names, from the hyprland socket2 protocol.  Only these can
;; change which workspaces exist or which one is focused; `activewindow' and
;; `windowtitle' fire constantly and cannot.
(define %workspace-events
  '("workspace" "workspacev2" "createworkspace" "createworkspacev2"
    "destroyworkspace" "destroyworkspacev2" "moveworkspace" "moveworkspacev2"
    "renameworkspace" "activespecial" "focusedmon"))

(define (workspace-event? event)
  (and (string? event) (member event %workspace-events) #t))

(define (focused-workspace)
  "An accessor over the focused workspace object.

`focused-workspace' reads through the property directly because it is an OBJECT
(unlike the GList list), and G-Golf converts objects fine.  It is refreshed on
the same events that move focus."
  (let ((subs (make-subs))
        (handler #f))
    (define (read)
      (catch #t (lambda () (slot-ref (hyprland) 'focused-workspace))
             (lambda args #f)))
    (define (refresh!)
      (subs-notify! subs))
    (create-accessor read 'focused-workspace
                     #:subscribe-fn
                     (lambda (thunk)
                       (subs-add! subs thunk)
                       (unless handler
                         (set! handler
                               (connect (hyprland) 'event
                                        (lambda (h event args)
                                          (when (workspace-event? event)
                                            (refresh!))))))
                       (lambda ()
                         (subs-remove! subs thunk)
                         (when (and handler (zero? (subs-count subs)))
                           (catch #t (lambda () (disconnect (hyprland) handler))
                                  (lambda a #f))
                           (set! handler #f)))))))

(define (hyprland) (service-instance 'hyprland))
