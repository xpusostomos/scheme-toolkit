;;; (scheme-toolkit services wl) -- Wayland outputs (AstalWl)
;;;
;;; AstalWl and AstalWl4: the registry, and the mapping from a GdkMonitor to
;;; the output behind it. The shell's monitor identity wants Wl4's
;;; find_output_by_gdk_monitor; it is not wired up yet.

(define-module (scheme-toolkit services wl)
  #:use-module (scheme-toolkit gi)
  #:export ())

;; Nothing yet: no code in this project uses this service.
;;
;; An empty module rather than no module, so that the list of services is
;; one directory listing and the next person to need this one has somewhere
;; obvious to start.
