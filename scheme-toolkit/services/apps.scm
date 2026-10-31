;;; (scheme-toolkit services apps) -- the application list (AstalApps)
;;;
;;; An application database: name, icon, exec line, and a fuzzy search over
;;; it.  The shell's launcher imports AstalApps directly (see
;;; (scheme-desktop plugins)); what is here is what MORE THAN ONE widget wants.
;;;
;;; **WHICH APPLICATION A WINDOW BELONGS TO**, which is the dock's question: a
;;; window has a class and a title, and an icon belongs to an application, so a
;;; dock that shows the class as an icon name shows a generic glyph for every
;;; window whose class is not also an icon's name -- `com.mitchellh.ghostty',
;;; `Slack' with a capital.  `app-for-window' is ags2-shell's `match_client_app'
;;; (`lib/apps.ts'), and it is in the toolkit because it is a fact about desktop
;;; files and window classes, not about any one shell.

(define-module (scheme-toolkit services apps)
  #:use-module (scheme-toolkit gi)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (apps-catalog app-for-window app-icon-name))

;;; ---------------------------------------------------------------------------
;;; The catalogue
;;; ---------------------------------------------------------------------------

;; IMPORTED HERE, AT LOAD, AND LOOKED UP BY NAME -- the same arrangement as
;; (scheme-toolkit service-helpers), and for its reason: `gi-import-by-name'
;; binds into whichever module is CURRENT when it runs, so importing from inside
;; a procedure binds the names in the CALLER's module and this one never sees
;; them.  Measured: written the obvious way, `<astal-apps-apps>' was an unbound
;; variable and the catalogue was always empty.
(define %self (current-module))

(eval-when (load eval)
  (catch #t
    (lambda ()
      (g-irepository-require "AstalApps" #:version "0.1")
      (gi-import-by-name "AstalApps" "Apps")
      (gi-import-by-name "AstalApps" "Application"))
    (lambda args #f)))

(define (gi-name sym)
  "SYM as this module bound it at load, or #f when AstalApps is not installed."
  (catch #t (lambda () (module-ref %self sym)) (lambda args #f)))

;; BUILT ONCE AND KEPT: constructing it scans every .desktop file.  Note the
;; constructor is `astal_apps_apps_new', NOT a `get_default' -- AstalApps has no
;; default instance, which every other Astal namespace has.
(define %apps-db #f)

(define (apps-db)
  "The AstalApps database, or #f when the namespace is unavailable."
  (or %apps-db
      (let* ((class (gi-name '<astal-apps-apps>))
             (db (and class
                      (catch #t
                        (lambda () (make class))
                        (lambda (key . args)
                          (format (current-error-port)
                                  "scheme-toolkit: no application database: ~a~%" key)
                          #f)))))
        (set! %apps-db db)
        db)))

(define (apps-catalog)
  "Every application, as a list of AstalApps.Application, or '().

THROUGH `get-list' AND NOT `(slot-ref db 'list)': a GList PROPERTY reads as an
opaque pointer through `slot-ref', while the method's return is converted to a
Scheme list.  The same trap as the MPRIS and WirePlumber lists."
  (let ((db (apps-db))
        (get-list (gi-name 'get-list)))
    (or (and db get-list (catch #t (lambda () (get-list db)) (lambda args #f)))
        '())))

(define (prop app name)
  "APP's property NAME as a string, or #f."
  (let ((v (catch #t (lambda () (slot-ref app name)) (lambda args #f))))
    (and (string? v) (not (string=? v "")) v)))

(define (app-icon-name app)
  "APP's icon name, or #f."
  (prop app 'icon-name))

;;; ---------------------------------------------------------------------------
;;; Which application a window is
;;; ---------------------------------------------------------------------------

(define (normalise s)
  (and (string? s)
       (let ((t (string-downcase (string-trim-both s))))
         (and (not (string=? t "")) t))))

;; THE FOUR FIELDS ags2-shell compares a window's class against, IN ITS ORDER:
;; the desktop file's `StartupWMClass', the desktop file's name, the same without
;; `.desktop', and the executable's basename.  The order is the point -- a
;; `StartupWMClass' is the one field written FOR this question, so it is asked
;; first, and the executable is the last resort it is.
(define (class-fields app)
  (let ((entry (prop app 'entry))
        (exec (prop app 'executable)))
    (list (prop app 'wm-class)
          entry
          (and entry (if (string-suffix-ci? ".desktop" entry)
                         (string-drop-right entry 8)
                         entry))
          (and exec
               (let ((program (car (string-tokenize exec))))
                 (last (string-split program #\/)))))))

(define (by-class apps classes)
  "The first app whose fields, in order, match one of CLASSES; or #f."
  (any (lambda (field-index)
         (find (lambda (app)
                 (let ((v (normalise (list-ref (class-fields app) field-index))))
                   (and v (member v classes))))
               apps))
       (iota 4)))

;; THE TITLE FALLBACK: an application whose NAME is the whole title, or one end
;; of it after one of these separators -- "Document - LibreOffice Writer".
(define %title-separators '(" - " " | " " — "))

(define (title-names-app? title name)
  (and title
       (or (string=? title name)
           (any (lambda (sep)
                  (or (string-prefix? (string-append name sep) title)
                      (string-suffix? (string-append sep name) title)))
                %title-separators))))

(define (by-title apps titles)
  "The ONE app whose name a title names, or #f -- #f when two do.

A NAME UNDER FOUR LETTERS IS NOT TRIED: \"Vim\" would claim every title ending
in \" - Vim\", which is fine, but \"Go\" would claim far more than it should.
AND AMBIGUITY IS #f, NOT THE FIRST: ags2-shell returns null the moment a second
app matches, because a wrong icon is worse than a generic one."
  (let ((hits (filter (lambda (app)
                        (let ((name (normalise (prop app 'name))))
                          (and name (>= (string-length name) 4)
                               (any (lambda (t) (title-names-app? t name)) titles))))
                      apps)))
    (and (= (length hits) 1) (car hits))))

(define* (app-for-window class #:key (initial-class #f) (title #f)
                         (initial-title #f) (apps (apps-catalog)))
  "The AstalApps.Application a window belongs to, or #f.

ags2-shell's `match_client_app': the window's CLASS (and initial class) against
each app's desktop-file fields, in a fixed order; failing that, its TITLE (and
initial title) against each app's name.  APPS defaults to the whole catalogue
and is a keyword so a caller matching many windows reads the catalogue once."
  (let ((classes (filter-map normalise (list class initial-class)))
        (titles (filter-map normalise (list title initial-title))))
    (or (and (pair? classes) (by-class apps classes))
        (and (pair? titles) (by-title apps titles)))))
