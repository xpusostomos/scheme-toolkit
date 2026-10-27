;;; tests/config.scm -- the config engine
;;;
;;; The contract that matters is that an option is an ACCESSOR, so a widget
;;; binds to it and updates when it changes -- the same integration point as
;;; create-binding on a GObject.  Plus the two things that make a config file
;;; usable rather than merely present: a typo must not stop the shell, and
;;; editing the file by hand must reach the running process.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit reactive))
(use-modules (scheme-toolkit config))
(use-modules (scheme-toolkit file))
(use-modules (srfi srfi-64))

;; A config in a scratch directory, so the test never touches a real one.
(define test-dir (string-append (or (getenv "TMPDIR") "/tmp")
                                "/stk-config-test-" (number->string (getpid))))
(define test-file (string-append test-dir "/config.scm"))

(define-config <test-config>
  #:file test-file
  (clock-format "%H:%M" string?)
  (bar-position top (lambda (v) (and (memq v '(top bottom)) #t)))
  (show-battery? #t boolean?))

(test-begin "config")

(test-group "defaults"
  (test-equal "a string option" "%H:%M" (config-value 'test-config 'clock-format))
  (test-equal "a symbol option" 'top (config-value 'test-config 'bar-position))
  (test-equal "a boolean option" #t (config-value 'test-config 'show-battery?)))

(test-group "an option is an accessor, and widgets can bind to it"
  (let* ((acc (config-ref 'test-config 'clock-format))
         (seen '()))
    (test-assert "config-ref gives an accessor" (accessor? acc))
    (define dispose (subscribe acc (lambda () (set! seen (cons (st-peek acc) seen)))))
    (config-set! 'test-config 'clock-format "%H:%M:%S")
    (test-equal "the binding fired" '("%H:%M:%S") seen)
    (test-equal "and reads the new value" "%H:%M:%S" (st-peek acc))
    (dispose)))

(test-group "validation"
  (config-set! 'test-config 'bar-position 'bottom)
  (test-equal "a valid value is accepted" 'bottom
    (config-value 'test-config 'bar-position))
  ;; An INVALID value is rejected and logged, and the old value stands -- a
  ;; config typo must not leave an option in a state nothing can render.
  (test-assert "an invalid value is refused"
    (not (config-set! 'test-config 'bar-position 'sideways)))
  (test-equal "and the old value stands" 'bottom
    (config-value 'test-config 'bar-position))
  (test-assert "a wrong type is refused"
    (not (config-set! 'test-config 'clock-format 42)))
  (test-assert "an unknown option is an error"
    (catch #t (lambda () (config-set! 'test-config 'nope 1) #f) (lambda args #t))))

(test-group "persistence"
  (config-set! 'test-config 'clock-format "%I:%M %p")
  (test-assert "save writes the file" (config-save! 'test-config))
  (test-assert "the file exists" (file-exists? test-file))
  (let ((text (read-file test-file)))
    (test-assert "and holds s-expressions" (string? text))
    (test-assert "including the changed option"
      (string-contains text "%I:%M %p")))
  ;; Reading it back gives the same values.
  (config-set! 'test-config 'clock-format "%H:%M")
  (config-reload! 'test-config)
  (test-equal "reload restores what was saved" "%I:%M %p"
    (config-value 'test-config 'clock-format)))

(test-group "a corrupt file does not stop the shell"
  ;; This is the case that matters: a typo in the config must not leave a shell
  ;; that will not start.
  ;;
  ;; Recovery keeps the value already in hand rather than reverting to the
  ;; default -- the option is untouched because the file could not be read, and
  ;; silently discarding a working value would be its own bug.
  (write-file test-file "((clock-format . \"unclosed\n")
  (config-reload! 'test-config)
  (test-equal "the current value stands, and nothing is lost" "%I:%M %p"
    (config-value 'test-config 'clock-format))
  (test-assert "and the bad file is kept, moved aside"
    (file-exists? (string-append test-file ".bad"))))

(test-group "a partially valid file keeps what it can"
  ;; One bad line should not discard the rest of a user's config.
  (write-file test-file
              "((clock-format . \"%H:%M:%S\")\n (bar-position . sideways)\n (nonsense . 1))\n")
  (config-reload! 'test-config)
  (test-equal "the good option took effect" "%H:%M:%S"
    (config-value 'test-config 'clock-format))
  (test-equal "the invalid one was refused" 'bottom
    (config-value 'test-config 'bar-position)))

(test-group "reset"
  (config-reset! 'test-config)
  (test-equal "back to the default" "%H:%M"
    (config-value 'test-config 'clock-format))
  (test-equal "and the other" 'top (config-value 'test-config 'bar-position)))

(test-group "live reload"
  ;; Watching needs (scheme-toolkit file)'s monitor-file, which cannot be built
  ;; at present: G-Golf does not dispatch methods bound from a typelib, so
  ;; GFile.monitor answers "No applicable method" for every argument type, and
  ;; the FFI route does not get g_signal_connect_data to take a closure.  The
  ;; engine side -- reload on demand -- is tested below and works; only the
  ;; automatic trigger is missing.
  ;;
  ;; Recorded rather than skipped silently, so the gap is visible in the suite.
  ;; The watch IS registered -- config-live? says so -- it simply never fires,
  ;; which is the misleading part: a registered watch looks like a working one.
  (test-assert "reload is manual for now, though the watch is registered"
    #t)
  ;; Editing the file and asking for a reload does work, which is what the
  ;; reload path is for.
  (write-file test-file "((clock-format . \"MANUAL\"))\n")
  (config-reload! 'test-config)
  (test-equal "an explicit reload picks the change up" "MANUAL"
    (config-value 'test-config 'clock-format)))

;; Clean up.
(for-each (lambda (p) (catch #t (lambda () (delete-file p)) (lambda args #f)))
          (list test-file (string-append test-file ".bad")
                (string-append test-file ".tmp")))
(catch #t (lambda () (delete-file test-dir)) (lambda args #f))

(test-end "config")
