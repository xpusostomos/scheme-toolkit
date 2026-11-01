;;; (scheme-toolkit services cava) -- audio visualiser (AstalCava)
;;;
;;; The spectrum data a cava widget draws. Nothing reads it yet.

(define-module (scheme-toolkit services cava)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (scheme-toolkit service-helpers)
  #:export (cava))

(define (cava) (service-instance 'cava))
