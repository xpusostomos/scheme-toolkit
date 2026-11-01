;;; (scheme-toolkit services greet) -- greetd (AstalGreet)
;;;
;;; A greeter's side of greetd. Not built -- the plan's suggested second
;;; consumer of this toolkit.

(define-module (scheme-toolkit services greet)
  #:use-module (scheme-toolkit gi)
  #:export ())

;; Nothing yet: no code in this project uses this service.
;;
;; An empty module rather than no module, so that the list of services is
;; one directory listing and the next person to need this one has somewhere
;; obvious to start.
