;;; (scheme-toolkit services tray) -- StatusNotifier (AstalTray)
;;;
;;; The tray service OPPOSITE (scheme-toolkit tray), which is the widget
;;; machinery that draws it.

(define-module (scheme-toolkit services tray)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (scheme-toolkit service-helpers)
  #:export (tray))

(define (tray) (service-instance 'tray))
