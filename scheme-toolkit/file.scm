;;; (scheme-toolkit file) -- read, write, and watch files
;;;
;;; The one that is not just a wrapper is `monitor-file', which is what makes
;;; live config reload and hot stylesheet reload work.  It keeps the monitor
;;; referenced: a Gio.FileMonitor that nothing holds is collected, and the watch
;;; then stops with no error at all, which is a genuinely confusing failure to
;;; diagnose.

(define-module (scheme-toolkit file)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-13)

  #:export (read-file read-file-lines
            write-file append-file
            mkdir-p expand-path
            monitor-file
            xdg-config-home xdg-cache-home xdg-state-home))

(eval-when (expand load eval)
  (use-modules (g-golf))
  (g-irepository-require "Gio" #:version "2.0")
  (gi-import-by-name "Gio" "File")
  (gi-import-by-name "Gio" "FileMonitor"))

;; Gio's GFile.monitor_file, imported under an ALIAS.
;;
;; The alias is the whole reason this is not a one-liner: Gio binds a method
;; named `monitor-file' on GFile, and this module exports a procedure of the same
;; name.  Importing both into one module means the wrapper's own definition
;; shadows Gio's, so calling `(monitor-file file ...)' from inside it recurses --
;; an infinite loop with no error to show for it.
;;
;; gi-import-by-name cannot rename, so the import is done into a module of its
;; own and the method fetched from there.
;;
;; There is no dispatch problem here.  An earlier version of this file claimed
;; G-Golf fails to dispatch typelib methods; that was wrong, and the mistake cost
;; hours.  The method takes (file, flags, cancellable) -- THREE arguments -- and
;; it was being called with two, which correctly answers "No applicable method".
;; Read the specializer COUNT, not just the classes.
(define %g-file-monitor-file
  (let ((m (resolve-module '(scheme-toolkit file gio) #:ensure #t)))
    (module-use! m (resolve-interface '(g-golf)))
    (eval '(g-irepository-require "Gio") m)
    (eval '(gi-import-by-name "Gio" "File") m)
    (module-ref m 'monitor-file)))

(define (make-file-monitor path flags)
  "A GFileMonitor for PATH with FLAGS, or #f.

FLAGS is a list, not a symbol: G-Golf's bitfield conversion maps over the value,
so a bare 'watch-moves fails with \"Wrong type argument: map\", naming neither
the flag nor the call."
  (%g-file-monitor-file (g-file-new-for-path path) flags #f))

;;; ---------------------------------------------------------------------------
;;; Reading and writing
;;; ---------------------------------------------------------------------------

(define* (read-file path #:key (fallback #f))
  "PATH's contents, or FALLBACK when it cannot be read.

Returns FALLBACK rather than throwing: a missing config file is an ordinary
state for a shell, not an error."
  (let ((r (attempt (lambda ()
                      (call-with-input-file path
                        (lambda (port) (read-string port)))))))
    (if (result-ok? r) (result-value r) fallback)))

(define* (read-file-lines path #:key (fallback '()))
  "PATH's lines, without their newlines, or FALLBACK."
  (let ((r (attempt (lambda ()
                      (call-with-input-file path
                        (lambda (port)
                          (let loop ((out '()))
                            (let ((line (read-line port)))
                              (if (eof-object? line)
                                  (reverse! out)
                                  (loop (cons line out)))))))))))
    (if (result-ok? r) (result-value r) fallback)))

(define (mkdir-p dir)
  "mkdir -p.  Guile's mkdir is one level, and the difference bites when a
config path has two missing components."
  (unless (or (string=? dir "") (string=? dir "/") (file-exists? dir))
    (mkdir-p (dirname dir))
    (catch #t (lambda () (mkdir dir)) (lambda args #f))))

(define* (write-file path contents #:key (parents? #t))
  "Write CONTENTS to PATH, creating parent directories when PARENTS?.

Returns #t on success, #f on failure -- and the failure is logged, because a
config that silently fails to save is worse than one that says so."
  (let ((r (attempt
            (lambda ()
              (when parents? (mkdir-p (dirname path)))
              (call-with-output-file path
                (lambda (port) (display contents port))
                #:encoding "UTF-8")
              #t))))
    (if (result-ok? r)
        (result-value r)
        (begin (log-error (result-value r) (format #f "writing ~a" path)) #f))))

(define* (append-file path contents #:key (parents? #t))
  "Add CONTENTS to the end of PATH, creating it (and its parents) if needed."
  (let ((r (attempt
            (lambda ()
              (when parents? (mkdir-p (dirname path)))
              ;; open-file with \"a\", not call-with-output-file: the latter has
              ;; no append mode and would truncate the file.
              (let ((port (open-file path "a")))
                (display contents port)
                (close-port port))
              #t))))
    (if (result-ok? r)
        (result-value r)
        (begin (log-error (result-value r) (format #f "appending to ~a" path)) #f))))

(define (expand-path path)
  "PATH with a leading ~ expanded to the home directory."
  (if (and (> (string-length path) 0) (char=? (string-ref path 0) #\~))
      (string-append (or (getenv "HOME") "") (substring path 1))
      path))

;;; ---------------------------------------------------------------------------
;;; Watching
;;; ---------------------------------------------------------------------------

;; A Gio.FileMonitor that nothing references is collected, and the watch stops
;; silently.  AGS keeps a module-level set for exactly this reason
;; (lib/file.ts:83).  Keyed by path so that two widgets watching the same file
;; share one monitor instead of fighting over two.
(define %monitors (make-hash-table))

(define* (monitor-file path proc #:key (rate-limit 200))
  "Call PROC with (kind path) whenever PATH changes.  Returns a procedure that
stops this callback.

PROC is called for every event kind Gio reports -- `changed',
`changes-done-hint', `attribute-changed' and the rest.  A caller that only wants
real content changes should filter.

Watching the same path twice adds a second callback to the SAME monitor rather
than starting a second watch, so two widgets on one config file do not fight.
The monitor stays referenced for as long as any callback is registered: an
unreferenced GFileMonitor is collected and its watch then stops with no error."
  (let* ((path (expand-path path))
         (entry (hash-ref %monitors path)))
    (if entry
        (begin
          (set-cdr! entry (cons proc (cdr entry)))
          (lambda () (%remove-watch! path proc)))
        (let ((m (make-file-monitor path '(watch-moves))))
          (when rate-limit (g-file-monitor-set-rate-limit m rate-limit))
          (hash-set! %monitors path (cons m (list proc)))
          (connect m 'changed
                   (lambda (mon file other kind)
                     (let ((e (hash-ref %monitors path)))
                       (when e
                         (for-each (lambda (cb) (cb kind path)) (cdr e))))))
          (lambda () (%remove-watch! path proc))))))

(define (%remove-watch! path proc)
  (let ((entry (hash-ref %monitors path)))
    (when entry
      (set-cdr! entry (delq proc (cdr entry)))
      (when (null? (cdr entry))
        (hash-remove! %monitors path)
        (catch #t (lambda () (g-file-monitor-cancel (car entry)))
               (lambda args #f))))))

;;; ---------------------------------------------------------------------------
;;; XDG directories
;;; ---------------------------------------------------------------------------

(define (xdg-dir env-var fallback-suffix)
  (or (let ((v (getenv env-var)))
        (and v (not (string=? v "")) v))
      (string-append (or (getenv "HOME") "") fallback-suffix)))

(define (xdg-config-home) (xdg-dir "XDG_CONFIG_HOME" "/.config"))
(define (xdg-cache-home)  (xdg-dir "XDG_CACHE_HOME"  "/.cache"))
(define (xdg-state-home)  (xdg-dir "XDG_STATE_HOME"  "/.local/state"))
