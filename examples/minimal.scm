;;; examples/minimal.scm -- the smallest thing that puts a window on screen
;;;
;;; This is a TOOLKIT example: it shows what the toolkit does, not what a shell
;;; decides.  The bar this project is building lives in scheme-desktop, because
;;; a bar's layout, its CSS classes and which modules it holds are that shell's
;;; decisions -- a different shell would want a bar, but not that one.
;;;
;;; What this demonstrates, in order, is the whole stack:
;;;
;;;   (make <gtk-label> ...)     G-Golf's own constructor, for a static leaf
;;;   (element <gtk-box> ...)    children, slots, signals, bound properties
;;;   (create-poll ...)          a cold accessor, live only while bound
;;;   (layer-window ...)         a layer surface with anchors
;;;   (for-each-monitor ...)     one root per monitor, disposed on hotplug
;;;   (run-shell ...)            the application and its main loop
;;;
;;; Run with:  bin/scheme-toolkit run examples/minimal.scm

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit reactive))
(use-modules (scheme-toolkit widget))
(use-modules (scheme-toolkit app))
(use-modules (scheme-toolkit time))
(use-modules (scheme-toolkit process))

(define-gi-imports "Gtk" "Box" "CenterBox" "Label" "Button")
(define-gi-imports "Astal" "Window")

;; A cold accessor over a command's output.  It runs only while a widget is
;; subscribed, so a clock that is not on screen costs nothing.
(define clock (create-poll 1000 '("date" "+%H:%M:%S")))

(define (main)
  (for-each-monitor
   (lambda (monitor name)
     (layer-window
      "demo"
      #:anchor '(top left right)
      #:exclusivity 'exclusive
      #:gdkmonitor monitor
      #:class "Demo"
      (element <gtk-center-box>
               ;; A child's #:slot says where it goes: start, center or end.
               (element <gtk-box> #:slot 'start
                        ;; A static leaf needs nothing from `element'.
                        (make <gtk-button>
                          #:label "Hello"
                          #:on-clicked (lambda (b)
                                         (exec-async '("notify-send" "hello")))))
               (element <gtk-box> #:slot 'center
                        ;; A bound property: the label follows the accessor.
                        (element <gtk-label> #:label clock))
               (element <gtk-box> #:slot 'end
                        ;; The monitor's own name, so you can tell two of
                        ;; these apart at a glance.
                        (make <gtk-label> #:label name)))))))

(run-shell #:instance "scheme-toolkit-demo" #:main main)
