;;; (scheme-toolkit services io) -- processes and timers (AstalIO)
;;;
;;; AstalIO.Process and AstalIO.Time are what (scheme-toolkit process) and
;;; (scheme-toolkit time) wrap; those two modules ARE this library's
;;; interface, and they are where its code lives.

(define-module (scheme-toolkit services io)
  #:use-module (scheme-toolkit gi)
  #:export ())

;; Nothing yet: no code in this project uses this service.
;;
;; An empty module rather than no module, so that the list of services is
;; one directory listing and the next person to need this one has somewhere
;; obvious to start.
