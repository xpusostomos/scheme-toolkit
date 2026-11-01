;;; (scheme-toolkit services notifd) -- notifications (AstalNotifd)
;;;
;;; The notification service (scheme-toolkit notify) is built on.

(define-module (scheme-toolkit services notifd)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (scheme-toolkit service-helpers)
  #:export (notifd))

(define (notifd) (service-instance 'notifd))
