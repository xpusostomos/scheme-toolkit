;;; examples/bar.scm -- the AGS starter bar, in Scheme
;;;
;;; This is ~/GIT/ags/cli/data/gtk4/Bar.tsx reproduced: a window with
;;; name/class/gdkmonitor/exclusivity/anchor, a centerbox with start, centre and
;;; end children, a button with an on-clicked handler, and a menubutton whose
;;; popover holds a calendar.
;;;
;;; It is the D1 acceptance test because it exercises every part of the element
;;; runtime in thirty lines -- child slots, signal props, nesting, and a
;;; non-intrinsic GI class -- and because "the AGS hello-world runs in Scheme"
;;; is a claim that is either true or visibly not.
;;;
;;; Run with:  bin/scheme-toolkit run examples/bar.scm

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit reactive))
(use-modules (scheme-toolkit widget))
(use-modules (scheme-toolkit app))
(use-modules (scheme-toolkit process))
(use-modules (scheme-toolkit time))

;; The widgets this file names, imported the way any consumer would.
(define-gi-imports "Gtk"
  "Box" "CenterBox" "Label" "Button" "MenuButton" "Popover" "Calendar"
  "EventControllerKey")
(define-gi-imports "Astal" "Window")

;; D1 keeps the clock STATIC, as the plan specifies: the milestone is about the
;; element runtime and the window, and a live clock is D2.  The AGS template
;; takes its text from
;;
;;   const time = Variable("", { poll: [1000, "date +%H:%M"] })
;;
;; and the Scheme equivalent is (create-poll 1000 '("date" "+%H:%M")), which
;; (scheme-toolkit time) provides -- but wiring a poll into a widget property
;; hits a bug that is being tracked separately, so this is a fixed string for
;; now.  Nothing else in the bar depends on it.
(define clock-text "00:00")

(define (build-bar monitor name)
  "One bar per monitor.  NAME comes from for-each-monitor and is the output's
own name where AstalWl4 can supply one, so a bar keeps its identity across a
hotplug."
  (layer-window
   "bar"
   #:anchor '(top left right)
   #:exclusivity 'exclusive
   #:gdkmonitor monitor
   #:class "Bar"
   (element <gtk-center-box>
            #:name (string-append "bar-" name)

            ;; start
            (element <gtk-box> #:slot 'start
                     (element <gtk-button>
                              #:label "Welcome"
                              #:on-clicked (lambda (b)
                                             ;; AGS's template runs a shell
                                             ;; command here.
                                             (exec-async '("notify-send" "hello from Scheme")))))

            ;; centre
            (element <gtk-box> #:slot 'center
                     (element <gtk-label>
                              #:label clock-text
                              #:class "clock"))

            ;; end
            (element <gtk-menu-button> #:slot 'end
                     (element <gtk-label> #:label "Calendar")
                     (element <gtk-popover>
                              (element <gtk-calendar>))))))

(define (main)
  (for-each-monitor
   (lambda (monitor name)
     (build-bar monitor name))))

(run-shell #:instance "scheme-example-bar" #:main main)
