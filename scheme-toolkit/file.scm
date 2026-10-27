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

;; Gio's g_file_monitor, called through FFI rather than through G-Golf.
;;
;; Three problems stack up here, and this is the shortest way past all of them:
;;
;;   1. GFile.monitor_file and this module's own `monitor-file' share a name, so
;;      importing both makes the wrapper call itself -- an infinite loop rather
;;      than an error.  GFile.monitor has the same name problem with nothing, so
;;      it is the one to use.
;;   2. G-Golf binds Gio's methods but they do not DISPATCH.  The specializers
;;      are right -- (<g-file> <top> <boolean>) -- and <g-file> is in the
;;      instance's class precedence list, yet every call answers "No applicable
;;      method", for a boolean, a real GCancellable, and #f alike.  Custom
;;      classes defined with define-class dispatch correctly, so this is
;;      specific to methods bound from a typelib.
;;   3. There is no top-level `g_file_monitor' to import by name: GIR declares it
;;      a method, so gi-import-by-name cannot find it.
;;
;; g_file_monitor(file, flags, cancellable, error) returns a GFileMonitor*.  The
;; flags are 0 because G_FILE_MONITOR_WATCH_MOVES is not needed: this watches a
;; single config or stylesheet file, and the plain event kinds cover write and
;; rename.
(define %g-file-monitor
  (let ((lib (catch #t (lambda () (dynamic-link "libgio-2.0.so.0"))
                    (lambda args #f))))
    (and lib
         (catch #t
           (lambda ()
             (pointer->procedure '*
                                 (dynamic-func "g_file_monitor" lib)
                                 (list '* int '* '*)))
           (lambda args #f)))))

(define (make-file-monitor path)
  "A GFileMonitor for PATH, or #f when g_file_monitor is unavailable."
  (if (not %g-file-monitor)
      #f
      (let ((p (%g-file-monitor (!g-inst (g-file-new-for-path path))
                                0 %null-pointer %null-pointer)))
        (and p (not (null-pointer? p)) p))))

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

(define %monitor-warning-shown? #f)

(define* (monitor-file path proc #:key (recursive? #f) (rate-limit 200))
  "Call PROC with (kind path) whenever PATH changes.  Returns a procedure that
stops this callback.

Watching the same path twice adds a second callback to the same monitor rather
than starting a second watch.  Returns a no-op stopper, having logged once, if
file watching is unavailable on this system -- see the note above on why that
can happen.

G-Golf CANNOT BE USED FOR THIS, which is worth stating plainly because it took
a long time to establish and the workaround is not obvious:

  - GFile.monitor_file and this module's own `monitor-file' share a name, so
    importing both makes the wrapper call itself -- an infinite loop, not an
    error.  GFile.monitor avoids that collision.
  - But G-Golf's methods bound from a TYPELIB DO NOT DISPATCH.  The
    specializers are correct -- (monitor file cancellable) is
    (<g-file> <top> <boolean>) -- and <g-file> IS in the instance's class
    precedence list, yet every call answers \"No applicable method\", for a
    boolean, a real GCancellable, and #f alike.  Classes defined here with
    define-class dispatch fine, so this is specific to typelib-bound methods.
  - And there is no top-level `g_file_monitor' to import by name, because the
    GIR declares it a method.

So the monitor is created through the C symbol directly.  That needs no GOOPS
dispatch and is verified working."
  (let* ((path (expand-path path))
         (key (if recursive? (string-append path ":r") path))
         (entry (hash-ref %monitors key)))
    (if entry
        (begin
          (set-cdr! entry (cons proc (cdr entry)))
          (lambda () (%remove-watch! key proc)))
        (let ((m (make-raw-file-monitor path)))
          (if (not m)
              (begin
                (unless %monitor-warning-shown?
                  (set! %monitor-warning-shown? #t)
                  (log-error "file watching unavailable: g_file_monitor not found"
                             "monitor-file"))
                (lambda () #f))
              (begin
                (hash-set! %monitors key (cons m (list proc)))
                (%connect-monitor! m
                                   (lambda (kind)
                                     (let ((e (hash-ref %monitors key)))
                                       (when e
                                         (for-each (lambda (cb) (cb kind path))
                                                   (cdr e))))))
                (lambda () (%remove-watch! key proc))))))))

(define (%remove-watch! key proc)
  (let ((entry (hash-ref %monitors key)))
    (when entry
      (set-cdr! entry (delq proc (cdr entry)))
      (when (null? (cdr entry))
        (hash-remove! %monitors key)
        (let ((m (car entry)))
          (if (procedure? m)
              (catch #t (lambda () (m)) (lambda args #f))   ; an FFI stopper
              (catch #t (lambda () (g-file-monitor-cancel m)) (lambda args #f))))))))

;;; ---------------------------------------------------------------------------
;;; File watching, through the C symbol
;;; ---------------------------------------------------------------------------

(define %gio-library
  (catch #t (lambda () (dynamic-link "libgio-2.0.so.0")) (lambda args #f)))

(define %g-file-monitor
  (and %gio-library
       (catch #t
         (lambda ()
           (pointer->procedure '*
                               (dynamic-func "g_file_monitor" %gio-library)
                               (list '* int '* '*)))
         (lambda args #f))))

(define %g-signal-connect-data
  (and %gio-library
       (catch #t
         (lambda ()
           (pointer->procedure 'unsigned-long
                               (dynamic-func "g_signal_connect_data" %gio-library)
                               (list '* '* '* '* '* int)))
         (lambda args #f))))

(define %g-file-monitor-cancel
  (and %gio-library
       (catch #t
         (lambda ()
           (pointer->procedure void
                               (dynamic-func "g_file_monitor_cancel" %gio-library)
                               (list '*)))
         (lambda args #f))))

(define (make-raw-file-monitor path)
  "A GFileMonitor* for PATH, or #f.  See monitor-file for why this is FFI."
  (and %g-file-monitor
       (let ((p (%g-file-monitor (!g-inst (g-file-new-for-path path))
                                 0 %null-pointer %null-pointer)))
         (and p (not (null-pointer? p)) p))))

;; A GClosure over a Scheme procedure, which is how a raw-pointer object gets a
;; signal handler without going through GOOPS dispatch.
(define (%connect-monitor! monitor proc)
  (and %g-signal-connect-data
       (let* ((closure (make <closure>
                         #:function (lambda (m file other kind) (proc kind))
                         #:return-type 'none
                         #:param-types (list '* '* '*)))
              (g-closure (!g-closure closure)))
         (%g-signal-connect-data monitor
                                 (string->pointer "changed")
                                 g-closure
                                 %null-pointer
                                 %null-pointer
                                 0))))

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
