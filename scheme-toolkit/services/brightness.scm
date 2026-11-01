;;; (scheme-toolkit services brightness) -- backlight and keyboard brightness (AstalBrightness)
;;;
;;; Screens, keyboards and LEDs. Nothing reads it yet.

(define-module (scheme-toolkit services brightness)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (scheme-toolkit service-helpers)
  #:export (brightness))

(define (brightness) (service-instance 'brightness))
