;;; tools/check-unbound.scm -- compile every module and report names that do
;;; not exist.
;;;
;;; WHY THIS IS A TOOL AND NOT A NOTE.  `docs/known-issues.md' already recorded
;;; four bugs found by grepping compiler warnings, and then the same class of
;;; bug cost hours more, so the check is now something to run rather than
;;; something to remember:
;;;
;;;   scheme-toolkit check-unbound
;;;
;;; THE ONE THAT PROMPTED IT.  A procedure -- `refresh-bluetooth-panel-later!'
;;; -- was called in six places whose definition had been lost in an edit.  Every
;;; call raised `Unbound variable' FROM INSIDE A SIGNAL HANDLER, and Guile
;;; unwinding that through `g_signal_emit' left a dangling entry in GObject's
;;; list of in-progress emissions.  The shell then died in `emission_find' while
;;; emitting an unrelated signal (`GtkAdjustment::changed', during a layout), on
;;; a stack with NO Scheme frame in it -- so the crash named no code at all, and
;;; the warning that said exactly where the problem was sat in the shell's own
;;; log, unread.  See the "unbound variable" entry in `docs/known-issues.md'.
;;;
;;; WHAT IT DOES NOT CATCH.  A name that exists but is the WRONG name (a misspelt
;;; GI import that a `catch' then swallows) compiles clean.  This finds "there is
;;; no such binding", not "the binding is not the one you meant".
;;;
;;; Exit status is 0 when there is nothing to report, 1 when there is, so it can
;;; be used as a gate.

(use-modules (system base compile)   ; compile-file -- this tool's whole job
             (ice-9 format)
             (ice-9 ftw)          ; scandir.  Its absence is itself a
                                  ; "possibly unbound variable" warning, which
                                  ; this tool would report if it could run.
             (srfi srfi-1)
             (srfi srfi-13))

;; THE NAMES TO IGNORE, and every one of them is a deliberate override or a
;; name GI binds at runtime -- reporting those would train a reader to ignore
;; the tool, which is the one failure mode a checker cannot survive.
;;
;;   for-each map connect member append member assq ... G-Golf's merged generics
;;                                              (see the duplicate-binding
;;                                              handler in gi.scm)
;;   gtk-init adw-init                           bound by `gtk-bootstrap!' when
;;                                              it imports the class
(define ignored
  '("for-each" "map" "connect" "member" "append" "max" "min" "filter" "sort"
    "gtk-init" "adw-init"))

(define (ignored? name) (member name ignored))

;; A dangling symlink -- an editor's lock file, `.#foo.scm' -- makes `stat'
;; raise and takes the whole walk with it.
(define (dir? p) (catch #t (lambda () (file-is-directory? p)) (lambda args #f)))
(define (source? name)
  (and (string-suffix? ".scm" name) (not (string-prefix? ".#" name))))

(define (modules-under dir)
  (let loop ((entries (sort (scandir dir) string<?)) (acc '()))
    (if (null? entries)
        (reverse acc)
        (let ((name (car entries)) (path (string-append dir "/" (car entries))))
          (cond ((member name '("." "..")) (loop (cdr entries) acc))
                ((source? name) (loop (cdr entries) (cons path acc)))
                ((dir? path) (loop (cdr entries) (append (reverse (modules-under path)) acc)))
                (else (loop (cdr entries) acc)))))))

;; WHERE TO LOOK.  Both projects when they sit side by side -- the sibling walk
;; is the same one `bin/run-tests' does -- or just this checkout.
(define toolkit-root (string-append (dirname (dirname (car (command-line)))) ""))
(define (candidate-roots)
  (let ((cwd (getcwd)))
    (filter (lambda (p) (and p (dir? p)))
            (list (getenv "SCHEME_TOOLKIT_ROOT")
                  (string-append toolkit-root "/scheme-toolkit")
                  (string-append cwd "/scheme-toolkit")
                  (string-append (dirname cwd) "/scheme-toolkit/scheme-toolkit")
                  (string-append cwd "/../scheme-desktop/scheme-desktop")))))

(define roots (delete-duplicates (candidate-roots)))
(define files (append-map modules-under roots))

(format #t "check-unbound: compiling ~a modules from source~%" (length files))

;; The name in "possibly unbound variable `foo'" (or with a straight quote, or
;; double, depending on the Guile build).
(define (unbound-name line)
  (or (and (string-contains line "unbound variable")
           (let* ((start (or (string-rindex line #\`) (string-rindex line #\'))))
             (and start (substring line (+ start 1) (1- (string-length line))))))
      #f))

;; WHAT A FAILED COMPILE MEANS, in two kinds, and the difference is the point.
;;
;; A SYNTAX ERROR -- `syntax-error', `read-error' -- is a fault IN THE FILE: a
;; `let' with no body, an unbalanced bracket.  It is a finding, and it fails the
;; check.  It used to be dropped instead: the failure line went through the same
;; filter as the warnings, which keeps only lines that NAME an unbound variable,
;; so the module was reported clean -- and the worse a module was, the quieter
;; this tool became about it.  Measured: a power-menu module with a malformed
;; `let' did not compile, so its unbound `let-values' (`(srfi srfi-11)' not
;; imported) was never warned about, the check said "nothing to report" over 109
;; modules, and the shell then would not start.
;;
;; ANYTHING ELSE is usually THIS TOOL'S OWN DOING, and is reported as NOT CHECKED
;; rather than as a fault.  Every module is compiled in one process, and compiling
;; a module CREATES its module object without running its body -- so a later file
;; importing it finds it half-empty and fails with "Unbound variable:
;; <popup-widget>" or similar.  Measured on 2026-10-31: `api.scm', `reload.scm'
;; and `shell.scm' fail that way here and each compiles cleanly in a fresh
;; process.  They were never checked before either; the difference now is that
;; the tool SAYS so, instead of counting them as clean.
(define %syntax-keys '(syntax-error read-error))

(define (compile-report file)
  "FILE's warnings and failure, as (LINES . NOT-CHECKED-REASON-or-#f)."
  (let* ((failure #f)
         (text (with-output-to-string
                 (lambda ()
                   (catch #t
                     (lambda ()
                       (parameterize ((current-warning-port (current-output-port)))
                         (compile-file file)))
                     (lambda (key . rest)
                       (set! failure (cons key rest)))))))
         (warnings (filter-map
                    (lambda (line)
                      (let ((name (unbound-name line)))
                        (and name (not (ignored? name)) (string-trim-both line))))
                    (string-split text #\newline))))
    (cond ((not failure) (cons warnings #f))
          ((memq (car failure) %syntax-keys)
           (cons (append warnings
                         (list (format #f "~a: COMPILE FAILED: ~a ~s"
                                       file (car failure) (cdr failure))))
                 #f))
          (else (cons warnings
                      (format #f "~a ~s" (car failure) (cdr failure)))))))

(define reports (map (lambda (f) (cons f (compile-report f))) files))
(define findings (filter (lambda (r) (pair? (cadr r))) reports))
(define unchecked (filter (lambda (r) (cddr r)) reports))

(for-each (lambda (r)
            (format #t "~%=== ~a~%" (car r))
            (for-each (lambda (l) (format #t "    ~a~%" l)) (cadr r)))
          findings)

;; NOT A FAILURE, AND NOT SILENCE EITHER: a module this pass could not compile
;; was not checked, and a reader has to be told which.
(unless (null? unchecked)
  (format #t "~%check-unbound: ~a module(s) NOT CHECKED -- they did not compile in this shared process (the reason is under each); run `guild compile' on one to check it alone:~%"
          (length unchecked))
  (for-each (lambda (r) (format #t "    ~a~%      ~a~%" (car r) (cddr r))) unchecked))

(if (null? findings)
    (begin
      (format #t "check-unbound: nothing to report~%")
      (exit 0))
    (begin
      (format (current-error-port)
              "check-unbound: ~a module(s) refer to names that do not exist, or do not compile~%"
              (length findings))
      (exit 1)))
