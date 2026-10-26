;;; tests/reactive.scm -- behavioural spec for the reactive core
;;;
;;; These are translated from the semantics the reference shells depend on
;;; (ags2-shell tests/lib/core.test.ts exercises the real Gnim).  The point of
;;; each case is the comment above it: this is the contract M1 and every widget
;;; built on it assumes.

(use-modules (scheme-toolkit reactive))
(use-modules (srfi srfi-64))

(test-begin "reactive")

;; An accessor must be callable AND distinguishable from a plain lambda: the
;; element runtime has to tell a bound prop from an event handler, and both are
;; procedures.
(test-group "accessor type"
  (define-values (n set-n!) (create-state 0))
  (test-assert "state accessor is an accessor" (accessor? n))
  (test-assert "a plain lambda is not" (not (accessor? (lambda () 1))))
  (test-equal "reads its value" 0 (n)))

(test-group "create-state"
  (define-values (n set-n!) (create-state 0))
  (set-n! 5)
  (test-equal "setter takes a value" 5 (n))
  (set-n! 1+)
  (test-equal "setter takes an updater procedure" 6 (n))
  ;; Setting an equal value must not notify, or every recompute would cascade.
  (let ((fired 0))
    (define dispose (subscribe n (lambda () (set! fired (1+ fired)))))
    (set-n! 6)
    (test-equal "equal value does not notify" 0 fired)
    (set-n! 7)
    (test-equal "different value notifies" 1 fired)
    (dispose)))

(test-group "create-computed"
  (define-values (n set-n!) (create-state 1))
  (define double (create-computed (lambda () (* (n) 2))))
  (test-equal "computes on read" 2 (double))
  (set-n! 3)
  (test-equal "recomputes after a dependency changes" 6 (double)))

(test-group "chained computeds"
  (define-values (n set-n!) (create-state 1))
  (define plus1 (create-computed (lambda () (1+ (n)))))
  (define times10 (create-computed (lambda () (* 10 (plus1)))))
  (test-equal "chain" 20 (times10))
  (set-n! 5)
  (test-equal "chain propagates" 60 (times10)))

(test-group "peek does not track"
  ;; (peek acc) is the read for a procedure that must NOT re-run when acc
  ;; changes; the common case is reading a value for its side effect only.
  (define-values (n set-n!) (create-state 1))
  (define const (create-computed (lambda () (peek n) 'constant)))
  (let ((fired 0))
    (define dispose (subscribe const (lambda () (set! fired (1+ fired)))))
    (set-n! 2)
    (test-equal "peeking source did not subscribe" 0 fired)
    (dispose)))

(test-group "subscribe and dispose"
  (define-values (n set-n!) (create-state 0))
  (let ((seen '()))
    (define dispose (subscribe n (lambda () (set! seen (cons (n) seen)))))
    (set-n! 1)
    (set-n! 2)
    (test-equal "fires per change" 2 (length seen))
    (dispose)
    (set-n! 3)
    (test-equal "dispose stops it" 2 (length seen))))

(test-group "derived accessor"
  ;; (acc f) is Gnim's shorthand for a computed, used constantly in the shells
  ;; as (time (lambda (t) ...)).
  (define-values (n set-n!) (create-state 6))
  (define label (n (lambda (v) (format #f "n=~a" v))))
  (test-equal "one-argument call derives a computed" "n=6" (label))
  (set-n! 7)
  (test-equal "and tracks" "n=7" (label)))

(test-group "cold accessors"
  ;; The property that makes binding hundreds of Astal properties cheap: with
  ;; no subscriber, a computed does not hold subscriptions to its sources.
  (define-values (n set-n!) (create-state 0))
  (define reads 0)
  (define c (create-computed (lambda () (set! reads (1+ reads)) (n))))
  (c)
  (test-equal "computed once on cold read" 1 reads)
  (set-n! 1)
  (c)
  (test-equal "recomputes when read while still cold" 2 reads))

(test-group "create-memo"
  (define-values (n set-n!) (create-state 1))
  (define sign (create-memo (lambda () (if (> (n) 0) 'pos 'nonpos))))
  (let ((fired 0))
    (define dispose (subscribe sign (lambda () (set! fired (1+ fired)))))
    (set-n! 2)
    (set-n! 3)
    (test-equal "equal results are suppressed" 0 fired)
    (set-n! -1)
    (test-equal "a changed result notifies" 1 fired)
    (dispose)))

(test-group "create-root disposes cleanups"
  (define cleaned 0)
  (define dispose
    (create-root (lambda (_dispose)
                   (on-cleanup (lambda () (set! cleaned (1+ cleaned)))))))
  (test-equal "not cleaned before dispose" 0 cleaned)
  (dispose)
  (test-equal "cleaned on dispose" 1 cleaned)
  ;; A second dispose must not run them twice.
  (dispose)
  (test-equal "dispose is idempotent" 1 cleaned))

(test-group "on-mount runs after the tree is built"
  (define order '())
  (create-root (lambda (_dispose)
                 (on-mount (lambda () (set! order (cons 'mounted order))))
                 (set! order (cons 'build order))))
  ;; The mount must NOT have run while proc was still building -- that is the
  ;; whole point of deferring it, since a mount typically reconfigures widgets
  ;; that do not exist yet.  So 'build was recorded first and 'mounted after.
  (test-equal "mount runs after the build, not during it"
    '(build mounted) (reverse order)))

(test-group "create-connection"
  (define-values (acc set-value!) (create-connection 0))
  (test-equal "initial value" 0 (acc))
  (let ((fired 0))
    (define dispose (subscribe acc (lambda () (set! fired (1+ fired)))))
    (set-value! 1)
    (test-equal "push notifies" 1 fired)
    (test-equal "and updates the value" 1 (acc))
    (dispose)))

(test-group "contexts"
  (define-values (provide use-ctx) (create-context 'default))
  (create-root (lambda (_dispose)
                 (provide 'provided)))
  ;; Outside the root that provided it, the default shows through.
  (test-equal "default outside the providing scope" 'default (use-ctx)))

(test-end "reactive")
