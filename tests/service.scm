;;; tests/service.scm -- define-service
;;;
;;; The contract that matters: a property declared with #:g-param must behave
;;; exactly like a built-in one, because that is what makes create-binding work
;;; on it.  And the singleton must be memoised, because that is what
;;; get_default() means everywhere else in the toolkit.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit reactive))
(use-modules (scheme-toolkit service))
(use-modules (oop goops))
(use-modules (srfi srfi-64))

(gtk-bootstrap!)

;; A service with two properties and a signal -- the shape a shell's own
;; service takes.
(define-service <test-service>
  #:g-type-name "StTestService"
  (enabled     #:g-param '(boolean #:default #f) #:accessor !enabled)
  (temperature #:g-param '(uint #:minimum 1000 #:maximum 10000 #:default 4000)
               #:accessor !temperature)
  ;; ONE signal: see the note in (scheme-toolkit service) -- G-Golf's
  ;; define-class takes exactly one #:g-signal.
  #:signals ((changed))
  (extra #:g-param '(int #:default 0) #:accessor !extra))

(test-begin "service")

(test-group "the class is a GObject"
  (let ((s (make <test-service>)))
    (test-assert "is a gobject" (is-a? s <gobject>))
    ;; NOTE: the GType name derives from the CLASS name, not from
    ;; #:g-type-name -- G-Golf silently ignores that option.  So <test-service>
    ;; registers as "TestService".  This matters because GLib requires a type
    ;; name of at least three characters, which is why a class named <t1> fails
    ;; to define at all.
    (test-equal "the GType name derives from the class name"
      "TestService"
      (catch #t
        (lambda () (g-type-name (!g-type (class-of s))))
        (lambda a "?")))))

(test-group "properties behave like built-in ones"
  (let ((s (make <test-service>)))
    (test-equal "default is honoured" #f (slot-ref s 'enabled))
    (test-equal "and for the other slot" 4000 (slot-ref s 'temperature))
    ;; The important one: notify:: must fire, or create-binding cannot work.
    (let ((fired 0))
      (connect s 'notify::enabled (lambda (o p) (set! fired (1+ fired))))
      (slot-set! s 'enabled #t)
      (test-equal "slot-set! fires notify" 1 fired)
      (test-assert "and the value changed" (slot-ref s 'enabled))
      ;; A GObject property notifies on every set, equal value or not, unless
      ;; it is declared with explicit-notify.  Worth pinning: a widget bound to
      ;; this will re-read once per set, so a service that must not churn
      ;; should not set an unchanged value.
      (slot-set! s 'enabled #t)
      (test-equal "an equal value still notifies" 2 fired))
    ;; The accessor G-Golf generated from #:accessor.
    (set! (!temperature s) 5000)
    (test-equal "the #:accessor works" 5000 (!temperature s))))

(test-group "create-binding works on a declared property"
  (let* ((s (make <test-service>))
         (acc (service-bind s 'temperature 'temp))
         (seen '()))
    (define dispose (subscribe acc (lambda () (set! seen (cons (st-peek acc) seen)))))
    (set! (!temperature s) 4500)
    (set! (!temperature s) 4600)
    (test-equal "the binding saw both changes" '(4600 4500) seen)
    (test-equal "and reads the current value" 4600 (st-peek acc))
    (dispose)
    (set! (!temperature s) 4700)
    (test-equal "dispose stops it" '(4600 4500) seen)))

(test-group "singleton"
  (service-reset! <test-service>)
  (let ((a (test-service-default))
        (b (test-service-default)))
    (test-assert "the same instance comes back" (eq? a b))
    (test-assert "service-ref finds it" (eq? a (service-ref <test-service>)))
    (set! (!enabled a) #t)
    (test-assert "and state persists on it" (slot-ref (test-service-default) 'enabled)))
  (service-reset! <test-service>)
  (test-assert "reset makes a fresh one" (not (slot-ref (test-service-default) 'enabled))))

(test-group "signals are declared and connectable"
  ;; A declared signal can be connected to, which is what a widget does.  It
  ;; cannot be EMITTED from Scheme: G-Golf generates no emitter for a
  ;; #:g-signal, and g_signal_emitv needs a hand-built GValue array.  Nothing in
  ;; the toolkit needs to emit -- a widget binds to a PROPERTY, whose notify::
  ;; GObject supplies -- so this is a documented gap rather than a blocker.
  (let ((s (make <test-service>)))
    (test-assert "connecting to a declared signal works"
      (let ((id (connect s 'changed (lambda (o) #f))))
        (and id (number? id))))
    ;; Connecting to something undeclared is an error, which is the useful
    ;; signal that #:signals did not take.
    (test-assert "connecting to an undeclared signal raises"
      (catch #t (lambda () (connect s 'nope (lambda (o) #f)) #f)
             (lambda args #t)))))

(test-end "service")
