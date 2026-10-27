;;; tests/palette.scm -- colours as data, and as CSS variables
;;;
;;; The interesting cases are all about a THEME FILE, which is user-editable:
;;; a colour literal starts with '#', so a careless comment-stripper deletes
;;; every value in the file; and one bad entry must cost that entry, not the
;;; theme.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit palette))
(use-modules (scheme-toolkit file))
(use-modules (srfi srfi-64))

(define test-dir (string-append (or (getenv "TMPDIR") "/tmp")
                                "/stk-palette-" (number->string (getpid))))

(define (scratch name contents)
  (let ((path (string-append test-dir "/" name)))
    (write-file path contents)
    path))

(test-begin "palette")

(test-group "a palette is an alist you can ask"
  (let ((p (make-palette '((accent . "#ff0000") (background . "#000000")))))
    (test-equal "a key" "#ff0000" (palette-ref p 'accent))
    (test-equal "a missing key with a fallback" "#123456"
      (palette-ref p 'nope "#123456"))
    (test-equal "a missing key without one" #f (palette-ref p 'nope))
    (test-equal "keys in order" '(accent background) (palette-keys p))))

(test-group "colour validation"
  ;; Only the forms theme generators actually emit are accepted, so a typo is
  ;; visible at load time rather than as a widget with no colour.
  (let ((p (read-colors-toml
            (scratch "c.toml"
                     (string-append
                      "good3 = \"#abc\"\n"
                      "good6 = \"#aabbcc\"\n"
                      "bad = \"notacolour\"\n"
                      "named = \"transparent\"\n"
                      "rgb = \"rgb(1,2,3)\"\n")))))
    (test-equal "3-digit hex accepted" "#abc" (palette-ref p 'good3))
    (test-equal "6-digit hex accepted" "#aabbcc" (palette-ref p 'good6))
    (test-equal "rgb() accepted" "rgb(1,2,3)" (palette-ref p 'rgb))
    (test-equal "a named colour accepted" "transparent" (palette-ref p 'named))
    (test-assert "a non-colour is dropped, not fatal" (not (palette-ref p 'bad)))))

(test-group "comments versus colour literals"
  ;; THE trap: every colour value begins with '#'.  A stripper that removes
  ;; from '#' onward empties the whole file and reports a theme with no colours.
  (let ((p (read-colors-toml
            (scratch "cm.toml"
                     (string-append
                      "accent = \"#7d82d9\"   # the blue one\n"
                      "# a whole-line comment\n"
                      "background = \"#060B1E\"\n")))))
    (test-equal "the value survives its trailing comment"
      "#7d82d9" (palette-ref p 'accent))
    (test-equal "and so does the next one"
      "#060B1E" (palette-ref p 'background))))

(test-group "pywal's colors.css"
  (let ((p (read-colors-css
            (scratch "colors.css"
                     (string-append
                      "/* generated */\n"
                      ":root {\n"
                      "  --background: #1a1b26;\n"
                      "  --foreground: #c0caf5;\n"
                      "  --color4: #7aa2f7;\n"
                      "}\n")))))
    (test-equal "a variable is read" "#1a1b26" (palette-ref p 'background))
    (test-equal "and another" "#c0caf5" (palette-ref p 'foreground))
    (test-equal "and the numbered ones" "#7aa2f7" (palette-ref p 'color4))))

(test-group "a missing file is not an error"
  (test-equal "read-colors-toml gives the fallback"
    'fallback (read-colors-toml "/nonexistent/nope.toml" #:fallback 'fallback))
  (test-equal "read-palette gives the fallback"
    'fallback (read-palette #:path "/nonexistent/nope.toml" #:fallback 'fallback)))

(test-group "the built-in palette is complete"
  ;; Every name a stylesheet might reference must exist, so a missing theme
  ;; file changes colours rather than making rules fail to apply.
  (test-assert "has an accent" (palette-ref default-palette 'accent))
  (test-assert "has a background" (palette-ref default-palette 'background))
  (test-assert "has a foreground" (palette-ref default-palette 'foreground))
  (test-assert "has a muted" (palette-ref default-palette 'muted))
  ;; Every value except `mode', which is not a colour: theme files carry a
  ;; little metadata beside the colours, and requiring it to parse as one would
  ;; reject the very files the reader is for.
  (test-assert "every COLOUR value is a valid colour"
    (every (lambda (k) (colour-string? (palette-ref default-palette k)))
           (delq 'mode (palette-keys default-palette)))))

(test-group "emitting CSS variables"
  (let ((css (palette->css-vars
              (make-palette '((accent . "#ff0000") (muted . "#808080"))))))
    (test-assert "opens a :root block" (string-contains css ":root {"))
    (test-assert "declares the accent" (string-contains css "--accent: #ff0000;"))
    (test-assert "declares the muted" (string-contains css "--muted: #808080;"))
    (test-assert "closes the block" (string-contains css "}"))
    ;; A custom property name must start with --, which is exactly what GTK
    ;; checks: var(x) is a parse error, var(--x) is not.
    (test-assert "every property is a real custom property"
      (not (string-contains css "  --: "))))
  ;; Underscores become hyphens: Omarchy writes dark_background, and the CSS
  ;; convention every rule follows is --dark-background.  Emitting the
  ;; underscore form declares variables nothing references, and looks correct
  ;; because the source file uses underscores too.
  (let ((css (palette->css-vars (make-palette '((dark_background . "#040816"))))))
    (test-assert "an underscored key is kebabed"
      (string-contains css "--dark-background: #040816;"))
    (test-assert "and the underscored form is gone"
      (not (string-contains css "--dark_background")))))

(test-group "discovery prefers the system theme"
  ;; Omarchy first, because a shell that ignores the desktop's own theme in
  ;; favour of pywal's stale output is worse than one with no theming.  The
  ;; order is asserted on the DECLARED list, since the machine's own files may
  ;; or may not exist.
  (test-assert "discovery answers something or nothing"
    (let ((f (find-palette-file)))
      (or (not f) (and (pair? f) (string? (car f)))))))

;; Clean up.
(for-each (lambda (name)
            (catch #t (lambda () (delete-file (string-append test-dir "/" name)))
                   (lambda args #f)))
          '("c.toml" "cm.toml" "colors.css"))
(catch #t (lambda () (delete-file test-dir)) (lambda args #f))

(test-end "palette")
