;;; Tests for (scheme-toolkit config-splice).
;;;
;;;     guile -L . tests/config-splice.scm
;;;
;;; The two paths are the ones the plugin design was written with: the root's
;;; list of widgets, and a section of the bar's layout.

(use-modules (scheme-toolkit config-splice)
             (srfi srfi-64))

(define bar '(scheme-desktop widgets bar <bar-desktop-widget>))
(define bt '(scheme-desktop widgets bluetooth <bluetooth-desktop-widget>))
(define net '(scheme-desktop widgets network <network-desktop-widget>))
(define x '(scheme-widget-demo widgets x <x-desktop-widget>))

(define root-path '(() root widgets ()))
(define (bar-path section) (list '() bar 'layout '() section '()))

(define config
  `((root (widgets (,bt ,net)))
    (,bt (show-icon #t))
    (,bar (position top)
          (layout ((left ()) (center ()) (right (,net ,bt)))))))

(test-begin "config-splice")

;;; ------------------------------------------------------------------ reading

(test-equal "config-ref follows the root path"
  (list bt net)
  (config-ref config root-path))

(test-equal "and the bar path"
  (list net bt)
  (config-ref config (bar-path 'right)))

(test-equal "a path to nothing is '() and makes nothing"
  '()
  (config-ref config '(() nowhere ())))

;;; ------------------------------------------------------------------ inserting

(test-equal "into the root's widgets, at the end"
  (list bt net x)
  (config-ref (config-splice config root-path x 'end) root-path))

(test-equal "into the bar's right section, at the beginning"
  (list x net bt)
  (config-ref (config-splice config (bar-path 'right) x 'beginning) (bar-path 'right)))

(test-equal "after a named neighbour"
  (list net x bt)
  (config-ref (config-splice config (bar-path 'right) x (list 'after net))
              (bar-path 'right)))

(test-equal "before one"
  (list x net bt)
  (config-ref (config-splice config (bar-path 'right) x (list 'before net))
              (bar-path 'right)))

(test-equal "after one that is not there: at the end, not nowhere"
  (list net bt x)
  (config-ref (config-splice config (bar-path 'right) x '(after missing))
              (bar-path 'right)))

(test-equal "an empty section is filled"
  (list x)
  (config-ref (config-splice config (bar-path 'center) x 'end) (bar-path 'center)))

(test-equal "everything else is left alone"
  (cdr config)
  (cdr (config-splice config root-path x 'end)))

;;; ------------------------------------------------------------------ idempotence

(test-equal "splicing what is already there changes nothing"
  config
  (config-splice config root-path bt 'end))

(test-equal "twice is once"
  (config-splice config root-path x 'end)
  (config-splice (config-splice config root-path x 'end) root-path x 'end))

;;; ------------------------------------------------------------------ from nothing

(test-equal "an empty config gets the forms it needs"
  `((root (widgets (,x))))
  (config-splice '() root-path x 'end))

(test-equal "and a bar section the same way"
  (list x)
  (config-ref (config-splice '() (bar-path 'right) x 'end) (bar-path 'right)))

(test-equal "a widget's own options form, at the top"
  `((root (widgets (,bt ,net))) (,bt (show-icon #t)) (,bar (position top) (layout ((left ()) (center ()) (right (,net ,bt))))) (,x))
  (config-splice config '(()) (list x) 'end #:key car))

(test-equal "and not twice, even when the old one has options"
  config
  (config-splice config '(()) (list bt) 'end #:key car))

;;; ------------------------------------------------------------------ deleting

(test-equal "out of the root's widgets"
  (list net)
  (config-ref (config-splice-delete config root-path bt) root-path))

(test-equal "out of the bar"
  (list net)
  (config-ref (config-splice-delete config (bar-path 'right) bt) (bar-path 'right)))

(test-assert "and its options form goes with its name"
  (not (assoc bt (config-splice-delete config '(()) bt #:key car))))

(test-equal "deleting what is not there changes nothing"
  config
  (config-splice-delete config root-path x))

(test-equal "in, then out, is where it started"
  config
  (config-splice-delete (config-splice config root-path x 'end) root-path x))

;;; ------------------------------------------------------------------ mistakes

(test-assert "a path that ends on a form is refused, not guessed at"
  (catch #t (lambda () (config-splice config '(() root) x 'end) #f) (lambda a #t)))

;;; ------------------------------------------------------------------ the bug

;; Every qualified name is a list beginning with its package, so two names from
;; one package share a head.  A first version treated a shared head as "already
;; there", and enabling the bluetooth panel after the bluetooth bar item added
;; nothing at all.
(define bt-panel '(scheme-desktop widgets bluetooth <bluetooth-panel-desktop-widget>))

(test-equal "two names from one package are two entries"
  (list bt net bt-panel)
  (config-ref (config-splice config root-path bt-panel 'end) root-path))

(test-equal "and deleting one leaves the other"
  (list net)
  (config-ref (config-splice-delete config root-path bt) root-path))

(test-end "config-splice")
