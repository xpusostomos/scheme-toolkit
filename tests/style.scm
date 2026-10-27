;;; tests/style.scm -- CSS generation and provider management
;;;
;;; Two things matter here and neither is the CSS text itself: that a stylesheet
;;; is DATA a Scheme program builds, and that a bad rule reports WHERE it is.  A
;;; parser that says "your stylesheet is broken" without a line sends the reader
;;; through a whole file.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit style))
(use-modules (oop goops))
(use-modules (srfi srfi-64))

(define-gi-imports "Gtk" "Label" "Window" "CssProvider")
(gtk-bootstrap!)

(test-begin "style")

(test-group "the AST"
  (test-assert "a rule renders"
    (string-contains (css-rule->string '(".Bar" (padding "0 6px")))
                     ".Bar {"))
  (test-assert "declarations get their colon and semicolon"
    (string-contains (css-rule->string '(".a" (padding "1px")))
                     "padding: 1px;"))
  ;; A rule applying to several selectors is ONE rule, not a copy per selector:
  ;; splitting it is how a stylesheet stops being maintainable.
  (test-assert "a selector list renders as one rule"
    (let ((out (css-rule->string '(( ".a" ".b") (color "red")))))
      (and (string-contains out ".a,\n.b {")
           (= 1 (let loop ((i 0) (n 0))
                   (if (>= i (string-length out)) n
                       (loop (+ i 1)
                             (if (char=? (string-ref out i) #\{) (+ n 1) n))))))))
  ;; Underscores become hyphens, so a Scheme program writing CSS does not have to
  ;; remember which separator the property uses.
  (test-assert "a symbol property is kebabed"
    (string-contains (css-rule->string '(".a" (background_color "red")))
                     "background-color:"))
  (test-assert "numbers render without decoration"
    (string-contains (css-rule->string '(".a" (opacity 0.5)))
                     "opacity: 0.5;"))
  ;; A Cairo-style rgba quad, since a palette will naturally produce these.
  (test-assert "an rgba quad renders as a colour"
    (string-contains (css-rule->string '(".a" (color (1.0 0.0 0.0 1.0))))
                     "rgba(255, 0, 0, 1.0)"))
  (test-assert "important survives"
    (string-contains (css-rule->string '(".a" (color "red" "!important")))
                     "!important")))

(test-group "a whole stylesheet"
  ;; A stylesheet is a LIST OF RULES, and a rule is ((SELECTOR ...) DECL ...).
  ;; The extra parens that make it a list-of-lists are the easy thing to get
  ;; wrong -- one too many and a whole rule is read as a selector.
  (let ((css (css-rules->string
              '((".Bar" (background "#1a1a20") (padding "0 6px"))
                (".Bar button" (border "none"))))))
    (test-assert "both rules are present"
      (and (string-contains css ".Bar {")
           (string-contains css ".Bar button {")))
    (test-assert "and the declaration order is preserved"
      (< (string-contains css "background")
         (string-contains css "padding")))))

(test-group "applying to a widget"
  (let* ((w (make <gtk-window>))
         (errors (apply-css! w ".Good { color: red; }")))
    (test-equal "valid css reports nothing" '() errors)))

(test-group "a bad rule reports where it is"
  ;; This is the feature.  GTK reports the message; the SECTION is what gives the
  ;; line and column, and gtk_css_section_to_string is how to get them.
  (let* ((w (make <gtk-window>))
         (errors (apply-css! w ".Bad { colour: red; }")))   ; colour, not color
    (test-assert "the error is reported" (pair? errors))
    (when (pair? errors)
      (test-assert "with a location"
        (string-prefix? "<data>:" (car errors)))
      ;; The message names the offending property, which is what makes the
      ;; location useful.
      (test-assert "and the message names the property"
        (string-contains (car errors) "colour")))))

(test-group "a partly invalid stylesheet still applies its good rules"
  ;; Refusing a whole stylesheet because of one typo is how a one-character
  ;; mistake takes the shell's entire appearance with it.
  (let* ((w (make <gtk-window>))
         (errors (apply-css! w ".Good { color: red; }\n.Bad { nope: 1; }")))
    (test-assert "the bad rule is reported" (pair? errors))
    (test-assert "and the good one did not stop the load"
      (not (any (lambda (e) (string-contains e "load failed")) errors)))))

(test-group "providers are held"
  ;; A GtkCssProvider nothing references is collected and its styles stop
  ;; applying, silently and later.  This is the guard against that.
  (let ((before (length %css-providers)))
    (css-provider-for ".Held { color: red; }")
    (test-assert "a new provider is kept" (> (length %css-providers) before))
    (reset-css!)
    (test-equal "reset drops them" 0 (length %css-providers))))

(test-end "style")
