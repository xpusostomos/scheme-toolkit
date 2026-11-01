;;; (scheme-toolkit config-splice) -- put a value into a config, and take it out
;;;
;;; A config is a nested list as `read' gives it back from config.scm:
;;;
;;;   ((root (widgets (A B)))
;;;    (B (width 380))
;;;    (BAR (position top) (layout ((left (A)) (center ()) (right (B))))))
;;;
;;; and a widget enabling itself has to put its name in the right lists in that
;;; tree -- the root's list of live widgets, a section of the bar -- and take it
;;; out again when it is disabled.  These do that, functionally: each returns a
;;; NEW config and leaves the one it was given alone.
;;;
;;; THE PATH.  A list of steps, read left to right, from the top of the config:
;;;
;;;   KEY   pick the form whose head is KEY
;;;   ()    step into the current form's VALUE -- the one unkeyed list it holds
;;;
;;; so '(() root widgets ()) is: into the config itself, the `root' form, its
;;; `widgets' form, and that form's list.  A KEY is anything compared with
;;; `equal?' -- a symbol, or a widget's qualified name, which is a list.
;;;
;;; THE WALK KNOWS WHERE IT IS STANDING, AND THAT IS THE POINT.  At any step it is
;;; either ON A FORM -- `(widgets (A B))', a key and what follows it -- or IN A
;;; LIST -- `(A B)'.  A key on a form searches the form's options; a key in a
;;; list searches the list; `()' steps from a form into its value.  It cannot be
;;; decided by looking: `(media tray network)' looks exactly like a form headed
;;; by `media', and only the path knows it is a list of three names.
;;;
;;; WHAT IS MISSING IS MADE.  A path through a config that does not have that
;;; form yet creates it on the way -- `(root)', then `(widgets ())' -- so a widget
;;; can enable itself into an empty config.  That is how a first run writes the
;;; config from nothing.
;;;
;;; IDEMPOTENT BOTH WAYS.  Splicing in a value that is already there changes
;;; nothing, and deleting one that is not there changes nothing, so `enable' run
;;; twice is `enable' run once.

(define-module (scheme-toolkit config-splice)
  #:use-module (srfi srfi-1)
  ;; `let-values', in `insert'.  Not core Guile.
  #:use-module (srfi srfi-11)
  #:export (config-splice config-splice-delete config-ref))

;;; ---------------------------------------------------------------------------
;;; The walk
;;; ---------------------------------------------------------------------------

(define (keyed-by? key)
  "A predicate: is this element a form whose head is KEY?"
  (lambda (e) (and (pair? e) (equal? (car e) key))))

(define (update-form-in elements key proc)
  "ELEMENTS with the form keyed by KEY replaced by (PROC form).  A missing form is
made as (KEY) first and added at the end."
  (if (any (keyed-by? key) elements)
      (map (lambda (e) (if ((keyed-by? key) e) (proc e) e)) elements)
      (append elements (list (proc (list key))))))

(define (walk node standing path at-end)
  "NODE, with AT-END applied to the list PATH leads to.

STANDING is 'form when NODE is a keyed form and 'list when it is an unkeyed list.
AT-END is a procedure from that final list to its replacement."
  (cond
   ((null? path)
    (if (eq? standing 'list)
        (at-end node)
        ;; A path must END in a list -- the thing a value goes into -- so it must
        ;; end with `()'.  Saying so names the mistake; inserting into a form's
        ;; options instead would put a widget name where an option belongs.
        (error "config-splice: the path ends on a form, not a list -- end it with ()"
               node)))
   ((null? (car path))
    (if (eq? standing 'form)
        ;; Into the form's value: its second element, made '() when it has none.
        (let ((value (if (pair? (cdr node)) (cadr node) '())))
          (cons* (car node)
                 (walk value 'list (cdr path) at-end)
                 (if (pair? (cdr node)) (cddr node) '())))
        (error "config-splice: `()' in a list -- there is no form to step into"
               node)))
   (else
    (let ((key (car path))
          (descend (lambda (form) (walk form 'form (cdr path) at-end))))
      (if (eq? standing 'form)
          ;; A key on a form searches its OPTIONS -- everything after the head.
          (cons (car node) (update-form-in (cdr node) key descend))
          (update-form-in node key descend))))))

(define (run config path at-end)
  ;; THE TOP OF THE CONFIG IS A FORM WITH NO HEAD: a path begins with `()' to
  ;; step into the config itself, so the walk starts standing on a pseudo-form
  ;; whose value is the config, and unwraps it at the end.
  (cadr (walk (list '%top config) 'form path at-end)))

;;; ---------------------------------------------------------------------------
;;; Inserting and deleting
;;; ---------------------------------------------------------------------------

;; WHAT COUNTS AS "ALREADY THERE" IS THE CALLER'S TO SAY, and it cannot be read
;; off the data.  In a list of NAMES the entries are compared whole.  Among the
;; top-level OPTIONS FORMS they are compared by their head: `(B)' is already there
;; when `(B (width 380))' is.  A first version guessed -- two lists with the same
;; head were the same entry -- and every qualified name begins `(scheme-desktop
;; ...', so enabling the bluetooth PANEL found the bluetooth BAR ITEM "already
;; there" and added nothing.  The test that would have caught it now does.
(define (present? value lst key)
  (let ((k (key value)))
    (any (lambda (e) (equal? (key e) k)) lst)))

(define (insert value position lst key)
  "LST with VALUE at POSITION: 'beginning, 'end, (after X) or (before X).

AN ANCHOR THAT IS NOT THERE puts it at the end, rather than nowhere: a widget
asking to sit after one that is disabled still wants to be in the bar."
  (cond
   ((present? value lst key) lst)
   ((eq? position 'beginning) (cons value lst))
   ((eq? position 'end) (append lst (list value)))
   ((and (pair? position) (memq (car position) '(after before)))
    (let ((anchor (cadr position)))
      (if (not (member anchor lst))
          (append lst (list value))
          (let-values (((head tail) (break (lambda (e) (equal? e anchor)) lst)))
            (if (eq? (car position) 'after)
                (append head (list (car tail) value) (cdr tail))
                (append head (list value) tail))))))
   (else (error "config-splice: no such position" position))))

(define* (config-splice config path value #:optional (position 'end)
                        #:key (key identity))
  "CONFIG with VALUE added to the list PATH leads to, at POSITION.

  (config-splice cfg '(() root widgets ()) name 'end)
  (config-splice cfg (list '() bar 'layout '() 'right '()) name 'beginning)
  (config-splice cfg '(()) (list name) 'end #:key car)     ; an options form

POSITION is 'end (the default), 'beginning, (after X) or (before X).  Already
there -- as decided by KEY, the whole entry by default -- it is left where it is."
  (run config path (lambda (lst) (insert value position lst key))))

(define* (config-splice-delete config path value #:key (key identity))
  "CONFIG with every entry whose KEY is VALUE taken out of the list PATH leads to.
KEY is the whole entry by default; `car' deletes the options form a name heads."
  (run config path
       (lambda (lst) (remove (lambda (e) (equal? (key e) value)) lst))))

(define (config-ref config path)
  "The list PATH leads to in CONFIG, or '() when it is not there.  For a caller
that only wants to look -- what is in the bar's right section -- without making
anything."
  (let loop ((node (list '%top config)) (standing 'form) (path path))
    (cond ((null? path) (if (eq? standing 'list) node '()))
          ((null? (car path))
           (if (and (eq? standing 'form) (pair? (cdr node)))
               (loop (cadr node) 'list (cdr path))
               '()))
          (else
           (let* ((elements (if (eq? standing 'form) (cdr node) node))
                  (hit (find (keyed-by? (car path)) elements)))
             (if hit (loop hit 'form (cdr path)) '()))))))
