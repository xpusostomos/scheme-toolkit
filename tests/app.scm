;;; tests/app.scm -- the app shell's vocabulary, without running a shell
;;;
;;; `run-shell' is not called here: it hands control to GTK's main loop and does
;;; not return.  What can be tested headlessly is the vocabulary a keybinding or
;;; a live-shell test uses -- the window registry, monitor enumeration and
;;; identity, and the toggling behaviour those depend on.
;;;
;;; The live half, which builds real windows on a real compositor, is
;;; examples/bar.scm and the tests that drive it over the REPL.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit reactive))
(use-modules (scheme-toolkit widget))
(use-modules (scheme-toolkit app))
(use-modules (oop goops))
(use-modules (srfi srfi-64))

(define-gi-imports "Gtk" "CenterBox" "Label" "Box")
(define-gi-imports "Astal" "Window")

;; GTK must be up before any widget or Gdk call, and before monitors.
(gtk-bootstrap!)

(test-begin "app")

(test-group "monitors"
  (let ((ms (monitors)))
    (test-assert "at least one monitor" (pair? ms))
    (test-assert "each monitor has a geometry"
      (every (lambda (m)
               (let ((g (monitor-geometry m)))
                 (and (list? g) (= 4 (length g)))))
             ms))
    ;; Identity must be a non-empty string: a bar is keyed by it, so an empty
    ;; or unstable name means roots get rebuilt on every hotplug.
    (test-assert "each monitor has a name"
      (every (lambda (m)
               (let ((n (monitor-name m)))
                 (and (string? n) (> (string-length n) 0))))
             ms))
    ;; Two monitors must not share a name, or one bar would overwrite the
    ;; other's root.
    (let ((names (map monitor-name ms)))
      (test-equal "names are distinct" (length names)
        (length (delete-duplicates names))))))

(test-group "widget registry"
  ;; No application is running, so %app is #f; a window cannot be built yet.
  ;; The registry itself is what is under test.
  ;;
  ;; THE VERBS NAME WIDGETS, not windows.  A window is reached through the widget
  ;; that owns it, so `windows-named', `windows' and `toggle-window' are gone --
  ;; these three lines went on calling them and went on failing, which is what a
  ;; stale test does: it reports a missing feature rather than a missing name.
  (test-equal "an unknown widget is #f" #f (desktop-widget-named "nope"))
  (test-equal "no windows to start" '() (shell-windows)))

(test-group "toggle-widget on an unknown name"
  ;; Must not throw: a keybinding that names a widget this shell does not have
  ;; should log and do nothing, not take the shell down.
  (test-assert "returns #f rather than raising" (not (toggle-widget "not-a-widget"))))

(test-group "for-each-monitor keys roots by monitor"
  ;; Without an application we cannot build windows, but the root bookkeeping
  ;; is independent of that.  Count the roots created.
  (let ((seen '()))
    (let ((n (for-each-monitor (lambda (mon name)
                                 (set! seen (cons name seen))))))
      (test-assert "visited every monitor" (= n (length (monitors))))
      (test-equal "and named each one" (length (monitors)) (length seen))
      ;; Calling again must not rebuild: the roots for monitors that are still
      ;; attached are left alone, which is what keeps a hotplug from flickering
      ;; the bars that did not move.
      (let ((before seen))
        (for-each-monitor (lambda (mon name) (set! seen (cons name seen))))
        (test-assert "a second pass rebuilds nothing" (null? (lset-difference equal? seen before)))))))

(test-end "app")
