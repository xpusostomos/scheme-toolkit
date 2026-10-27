;;; (scheme-toolkit style) -- CSS generation and provider management
;;;
;;; Two jobs, and both are about not fighting the toolkit:
;;;
;;;   - a small S-expression CSS AST, so a stylesheet is data a Scheme program
;;;     can build rather than a string it concatenates;
;;;   - provider lifetime, which is the part that bites.  A GtkCssProvider that
;;;     nothing references is collected and its styles silently stop applying.
;;;     This keeps every provider it creates.
;;;
;;; PRIORITY.  GTK's own stylesheets sit at THEME, and libadwaita's above that;
;;; USER (800) beats both, which is what a shell needs to own its appearance and
;;; what makes a palette able to recolour Adw widgets too.  AGS uses USER and
;;; colorshell uses APPLICATION (600); USER is the choice here, documented
;;; because the two differ and the difference is visible.
;;;
;;; ERROR REPORTING.  GTK reports a bad rule through `parsing-error', and the
;;; useful part is not the message but the LOCATION: gtk_css_section_to_string
;;; gives "<data>:1:8-14", which is what turns "your stylesheet is broken" into
;;; a line to look at.  Logging only the message leaves you reading a whole file.

(define-module (scheme-toolkit style)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:export (css-rules->string css-rule->string
            apply-css! apply-provider! apply-provider-for-display!
            reset-css!
            css-provider-for
            css-error->string
            %css-providers))

;; Selective, because a whole-namespace Gtk import costs 2.7 s (see gi.scm).
(define-gi-imports "Gtk" "Widget" "StyleContext" "CssProvider" "CssSection")
(define-gi-imports "Gdk" "Display")

;;; ---------------------------------------------------------------------------
;;; The AST
;;; ---------------------------------------------------------------------------
;;;
;;; A stylesheet is a list of rules.  A rule is (SELECTOR DECLARATION ...), where
;;; a declaration is (PROPERTY VALUE) or (PROPERTY VALUE "!important").
;;;
;;;   (css-rules->string
;;;     '((".Bar" (background "#1a1a20") (padding "0 6px"))
;;;       (".Bar button" (border "none"))))
;;;
;;; Nested selector lists are allowed -- ("(.a" ".b") ...) -- because a rule
;;; that applies to several selectors is one rule, and splitting it is how a
;;; stylesheet becomes unmaintainable.

(define (property->string prop)
  (let ((s (if (string? prop) prop (symbol->string prop))))
    ;; `background-color' and `background_color' both become `background-color':
    ;; a Scheme program writing CSS should not have to remember which.
    (list->string (map (lambda (c) (if (char=? c #\_) #\- c)) (string->list s)))))

(define (value->string v)
  (cond ((string? v) v)
        ((number? v) (format #f "~a" v))
        ((symbol? v) (symbol->string v))
        ;; A Cairo-ish colour triple, since a palette will produce these.
        ((and (list? v) (= 4 (length v)) (every number? v))
         (format #f "rgba(~a, ~a, ~a, ~a)"
                 (inexact->exact (round (* 255 (car v))))
                 (inexact->exact (round (* 255 (cadr v))))
                 (inexact->exact (round (* 255 (caddr v))))
                 (cadddr v)))
        ((list? v) (string-join (map value->string v) " "))
        (else (format #f "~a" v))))

(define (selector->string sel)
  (if (string? sel) sel (symbol->string sel)))

(define (declaration->string decl)
  (unless (and (list? decl) (>= (length decl) 2))
    (error "css: a declaration is (PROPERTY VALUE), got" decl))
  (format #f "  ~a: ~a~@[ ~a~];~%"
          (property->string (car decl))
          (value->string (cadr decl))
          (and (>= (length decl) 3) (value->string (caddr decl)))))

(define (css-rule->string rule)
  "One rule: ((SELECTOR ...) DECLARATION ...)."
  (unless (and (list? rule) (pair? rule))
    (error "css: a rule is ((SELECTOR ...) DECLARATION ...), got" rule))
  (let ((selectors (car rule))
        (decls (cdr rule)))
    (string-append
     (if (list? selectors)
         (string-join (map selector->string selectors) ",\n")
         (selector->string selectors))
     " {\n"
     (apply string-append (map declaration->string decls))
     "}\n")))

(define (css-rules->string rules)
  "Every RULE, one after another."
  (apply string-append (map css-rule->string rules)))

;;; ---------------------------------------------------------------------------
;;; Providers
;;; ---------------------------------------------------------------------------

;; Every provider this module has made.  A GtkCssProvider with no reference is
;; collected, and its styles then stop applying -- silently, and at some
;; unpredictable later moment.  Holding them for the process's life is the only
;; reliable answer.
(define %css-providers '())

(define (css-error->string section error)
  "A location and message for a CSS parse error.

SECTION gives the location -- gtk_css_section_to_string answers \"<data>:1:8-14\"
-- and ERROR is GLib's (domain code message-pointer) triple, whose message is
the only part worth showing."
  (let* ((where (catch #t
                  (lambda () (gtk-css-section-to-string section))
                  (lambda args "<unknown>")))
         (message (catch #t
                    (lambda ()
                      (let ((m (and (pair? error) (>= (length error) 3)
                                    (list-ref error 2))))
                        (cond ((string? m) m)
                              ((pointer? m) (pointer->string m))
                              (else (format #f "~s" error)))))
                    (lambda args (format #f "~s" error)))))
    (format #f "~a: ~a" where message)))

(define* (css-provider-for css #:key (priority 800))
  "A GtkCssProvider loaded with CSS, at PRIORITY (800 = USER).

Returns two values: the provider and a list of errors, each a string with its
location.  Errors do NOT make this fail: a stylesheet with one bad rule is still
worth using for the rest, and refusing it entirely is how a typo takes a shell's
whole appearance with it."
  (let ((provider (make <gtk-css-provider>))
        (errors '()))
    (connect provider 'parsing-error
             (lambda (p section error)
               (set! errors (cons (css-error->string section error) errors))))
    (catch #t
      (lambda () (load-from-string provider css))
      (lambda (key . rest)
        (set! errors (cons (format #f "load failed: ~a" key) errors))))
    ;; Held for the process's life; see %css-providers.
    (set! %css-providers (cons provider %css-providers))
    (values provider (reverse errors))))

(define* (apply-provider! widget provider #:key (priority 800))
  "Attach an existing PROVIDER to WIDGET's style context.  Returns #t or #f.

THIS STYLES ONLY WIDGET ITSELF.  That is GTK4's behaviour for
gtk_style_context_add_provider and it is the opposite of what GTK3 did: a
provider attached to a widget's context is NOT inherited by its children.  A
shell that calls this on a toplevel -- the obvious thing -- gets a stylesheet
that reaches the toplevel and nothing inside it, which looks exactly like a
stylesheet that failed to load.

Use `apply-provider-for-display!' for a shell's own stylesheet.  This is for the
per-widget `#:css' prop in (scheme-toolkit widget), where styling one widget is
the entire intent."
  (catch #t
    (lambda ()
      (add-provider (get-style-context widget) provider priority)
      #t)
    (lambda (key . rest)
      (format (current-error-port)
              "scheme-toolkit: css: add-provider failed: ~a ~s\n" key rest)
      #f)))

(define* (apply-provider-for-display! provider
                                      #:key (priority 800) (display #f))
  "Attach PROVIDER to the DISPLAY, so it styles EVERY widget under it.

This is what a shell's own stylesheet needs, and it is the difference between a
stylesheet that works and one that appears to do nothing:

  gtk_style_context_add_provider            styles THAT WIDGET only
  gtk_style_context_add_provider_for_display  styles every widget on the display

GTK4 does not inherit a widget-attached provider to descendants (GTK3 did), so
applying a shell's stylesheet to each toplevel's context reaches the toplevels
alone -- every button, label and image inside them keeps the theme's styling.
The symptom is a stylesheet that parses cleanly, reports no errors, and changes
nothing, which is a genuinely expensive thing to debug: the CSS is fine, it is
simply never consulted for the widgets anyone is looking at.

THE NAME IS THE TRAP.  This is a namespace FUNCTION, and G-Golf names those
after the full C identifier with the prefix kept --
`gtk-style-context-add-provider-for-display' -- while METHODS get the short name
(`add-provider').  Looking for `add-provider-for-display' therefore finds
nothing, and the obvious conclusion is that G-Golf skipped it as deprecated.  It
did not: the function is present under its long name."
  (catch #t
    (lambda ()
      (let ((d (or display (gdk-display-get-default))))
        (if (not d)
            (begin
              (format (current-error-port)
                      "scheme-toolkit: css: no display to apply a stylesheet to~%")
              #f)
            (begin
              (gtk-style-context-add-provider-for-display d provider priority)
              #t))))
    (lambda (key . rest)
      (format (current-error-port)
              "scheme-toolkit: css: add-provider-for-display failed: ~a ~s\n"
              key rest)
      #f)))

(define* (apply-css! widget css #:key (priority 800) (on-error #f))
  "Apply CSS to WIDGET's style context.  Returns a list of parse errors.

WIDGET ONLY -- see apply-provider!.  An earlier version of this docstring said
applying to a toplevel covers its whole subtree, which is GTK3's behaviour and
is wrong for GTK4.  For a whole stylesheet use apply-provider-for-display!.

ON-ERROR, when given, is called with each error string.  Otherwise they go to
stderr -- a stylesheet that silently fails to parse is indistinguishable from one
that parsed and did nothing, and that is a bad half hour."
  (let-values (((provider errors) (css-provider-for css #:priority priority)))
    (catch #t
      (lambda ()
        (add-provider (get-style-context widget) provider priority))
      (lambda (key . rest)
        (set! errors (cons (format #f "add-provider failed: ~a" key) errors))))
    (for-each (lambda (e)
                (if on-error (on-error e)
                    (format (current-error-port) "scheme-toolkit: css: ~a\n" e)))
              errors)
    errors))

(define (reset-css!)
  "Forget every provider this module created.

GTK keeps no per-provider removal for a display, so this is for tests and for a
full restyle: the providers are dropped and the next apply-css! starts fresh.
Existing widgets keep the providers they already have -- a re-apply is what
changes their appearance."
  (set! %css-providers '())
  #t)
