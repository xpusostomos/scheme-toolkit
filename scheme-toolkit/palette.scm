;;; (scheme-toolkit palette) -- colours as data, and as CSS variables
;;;
;;; A shell's appearance is a palette applied to a stylesheet, and the reason
;;; this is its own module rather than a string in a style file is that a
;;; palette has three jobs:
;;;
;;;   - be READ from whatever produces colours on this machine (Omarchy's
;;;     colors.toml, pywal's colors.css, matugen's JSON, or a hand-written
;;;     file), without the shell caring which;
;;;   - be VALIDATED, because a theme file is user-editable and a half-written
;;;     one must not take the shell's appearance with it;
;;;   - be EMITTED as CSS custom properties, so a stylesheet says
;;;     `background: var(--bg)' and a theme change recolours it without the
;;;     stylesheet being regenerated.
;;;
;;; Verified against GTK 4.24: custom properties and var() are parsed, and a
;;; malformed reference is REPORTED (var(x) errors, var(--x) does not), which is
;;; what makes the variable route worth taking rather than string-stitching
;;; colours into every rule.

(define-module (scheme-toolkit palette)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit file)
  #:use-module (scheme-toolkit result)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:export (make-palette palette? palette-ref palette-keys
            colour-string?
            palette->css-vars
            read-colors-toml
            read-colors-css
            read-palette
            find-palette-file
            default-palette))

;;; ---------------------------------------------------------------------------
;;; The palette
;;; ---------------------------------------------------------------------------
;;
;; An association list of SYMBOL -> "#rrggbb".  Symbols rather than strings so
;; (palette-ref p 'accent) is checked at read time by the reader, and an alist
;; rather than a hash so a palette prints readably in an error message -- which
;; is most of what a palette is ever used for when something is wrong.

(define-record-type <palette>
  (make-palette-raw entries source)
  palette?
  (entries palette-entries)
  (source  palette-source))

(define* (make-palette alist #:key (source "literal"))
  "A palette from ALIST, an association list of symbol to colour string."
  (make-palette-raw alist source))

(define* (palette-ref palette key #:optional (fallback #f))
  "KEY's colour, or FALLBACK."
  (let ((hit (assq key (palette-entries palette))))
    (if hit (cdr hit) fallback)))

(define (palette-keys palette)
  (map car (palette-entries palette)))

;;; ---------------------------------------------------------------------------
;;; Colour validation
;;; ---------------------------------------------------------------------------

;; GTK accepts a great deal, but a THEME FILE is user-editable and the failure
;; mode of a bad colour is silent: the rule simply does not apply.  Accepting
;; only the two forms the theme generators actually emit keeps a typo visible
;; at load time instead of as a widget that is the wrong colour or no colour.
(define (colour-string? s)
  (and (string? s)
       (let ((n (string-length s)))
         (cond
          ;; #rgb and #rrggbb, and the #rrggbbaa form matugen can emit.
          ((and (> n 1) (char=? (string-ref s 0) #\#)
                (memv n '(4 5 7 9))
                (every (lambda (c) (memv c '(#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9
                                             #\a #\b #\c #\d #\e #\f
                                             #\A #\B #\C #\D #\E #\F)))
                       (string->list (substring s 1))))
           #t)
          ;; rgb()/rgba()/hsl() -- passed through, since a generator may prefer
          ;; them and this is not a CSS parser.
          ((string-prefix? "rgb" s) #t)
          ((string-prefix? "hsl" s) #t)
          ;; A bare named colour from the small set that appears in themes.
          ((member s '("transparent" "none" "white" "black" "red" "green" "blue"))
           #t)
          (else #f)))))

;; Theme files carry a little metadata beside the colours -- Omarchy writes
;; `mode = "dark"'.  Those keys are KNOWN not to be colours, so warning about
;; them would train the reader to ignore warnings, which is worse than not
;; warning at all.
(define %metadata-keys '(mode scheme name variant author))

(define (valid-colour-or! key value source)
  "VALUE for KEY if it looks like a colour; otherwise #f with a message.

A theme file with one bad entry should lose that entry, not the whole theme --
and a metadata entry is not bad, it is simply not a colour."
  (cond ((memq key %metadata-keys) #f)
        ((colour-string? value) value)
        (else
         (format (current-error-port)
                 "scheme-toolkit: palette: ~a: ~s is not a colour, ignoring~%"
                 source value)
         #f)))

;;; ---------------------------------------------------------------------------
;;; Reading: colors.toml (Omarchy and others)
;;; ---------------------------------------------------------------------------

(define (strip-comment line)
  "LINE without its trailing comment, respecting a # inside a value.

A colour literal starts with #, so a strip that removes from the first # would
delete every value in the file -- exactly how a palette reader ends up
reporting an empty theme.  Two cases cover the formats read here:

  key = \"#7d82d9\"   # comment     a # inside QUOTES is part of the value
  --key: #7d82d9;                 a # after ':' is part of the value

Outside both, a # starts a comment.  A line whose first non-blank character is
# is a whole-line comment, which the ':' rule alone would otherwise keep, since
  a bare comment contains no colon."
  (let* ((trimmed (string-trim line))
         (leading (substring line 0 (- (string-length line)
                                       (string-length trimmed)))))
    ;; A whole-line comment: nothing before it on the line.
    (if (and (> (string-length trimmed) 0)
             (char=? (string-ref trimmed 0) #\#))
        ""
        (let loop ((i 0) (in-string? #f) (after-colon? #f))
          (cond ((>= i (string-length line)) line)
                ((char=? (string-ref line i) #\")
                 (loop (+ i 1) (not in-string?) after-colon?))
                ((and (not in-string?) (char=? (string-ref line i) #\:))
                 (loop (+ i 1) in-string? #t))
                ((and (not in-string?) (not after-colon?)
                      (char=? (string-ref line i) #\#))
                 (substring line 0 i))
                (else (loop (+ i 1) in-string? after-colon?)))))))

(define (parse-toml-pair line)
  "A (KEY . VALUE) for a simple `key = \"value\"' line, or #f."
  (let* ((line (string-trim-both (strip-comment line)))
         (eq (string-index line #\=)))
    (and eq
         (let* ((key (string-trim-both (substring line 0 eq)))
                (raw (string-trim-both (substring line (+ eq 1))))
                (value (if (and (>= (string-length raw) 2)
                                (char=? (string-ref raw 0) #\")
                                (char=? (string-ref raw (- (string-length raw) 1)) #\"))
                           (substring raw 1 (- (string-length raw) 1))
                           raw)))
           (and (not (string=? key ""))
                (cons (string->symbol key) value))))))

(define* (read-colors-toml path #:key (fallback #f))
  "A palette from PATH, a simple TOML of `name = \"#rrggbb\"' pairs.

This reads the shape Omarchy writes to
~/.local/state/omarchy/current/theme/colors.toml, which is what a Omarchy
machine already has -- so the shell follows the system theme rather than
shipping a second colour engine that disagrees with it.  Only flat key/value
pairs are understood, which is all these files contain."
  (let ((text (read-file path)))
    (if (not text)
        fallback
        (let* ((lines (string-split text #\newline))
               (pairs (filter-map parse-toml-pair lines))
               (colours (filter-map
                         (lambda (pair)
                           (let ((v (valid-colour-or! (car pair) (cdr pair) path)))
                             (and v (cons (car pair) v))))
                         pairs)))
          (and (pair? colours) (make-palette colours #:source path))))))

;;; ---------------------------------------------------------------------------
;;; Reading: colors.css (pywal)
;;; ---------------------------------------------------------------------------

(define (parse-css-var line)
  "A (KEY . VALUE) for `--name: #rrggbb;', or #f."
  (let* ((line (string-trim-both (strip-comment line)))
         (colon (string-index line #\:)))
    (and colon
         (string-prefix? "--" line)
         (let ((key (string-trim-both (substring line 2 colon)))
               (value (string-trim-both
                       (string-delete #\; (substring line (+ colon 1))))))
           (and (not (string=? key ""))
                (cons (string->symbol key) value))))))

(define* (read-colors-css path #:key (fallback #f))
  "A palette from PATH, a pywal-style colors.css of `--name: value;' lines.

Read from the CSS, not colors.json: pywal writes both, the CSS is what pywal's
own templates consume, and it needs no JSON parser."
  (let ((text (read-file path)))
    (and text
         (let* ((lines (string-split text #\newline))
                (colours (filter-map
                          (lambda (line)
                            (let ((pair (parse-css-var line)))
                              (and pair
                                   (let ((v (valid-colour-or! (car pair) (cdr pair) path)))
                                     (and v pair)))))
                          lines)))
           (and (pair? colours) (make-palette colours #:source path))))))

;;; ---------------------------------------------------------------------------
;;; Discovery
;;; ---------------------------------------------------------------------------

;; Tried in order.  Omarchy first because it is what this machine runs, and a
;; shell that ignores the desktop's own theme in favour of pywal's stale output
;; is worse than one with no theming at all.
(define %palette-paths
  '(;; Omarchy: the system's own theme output.
    (".local/state/omarchy/current/theme/colors.toml" . toml)
    ;; pywal16 / pywal
    (".cache/wal/colors.css" . css)
    (".config/wal/colors.css" . css)))

(define (find-palette-file)
  "A (PATH . FORMAT) for the first palette file this machine has, or #f."
  (let ((home (or (getenv "HOME") "")))
    (let loop ((rest %palette-paths))
      (cond ((null? rest) #f)
            (else
             (let ((path (string-append home "/" (caar rest))))
               (if (file-exists? path)
                   (cons path (cdar rest))
                   (loop (cdr rest)))))))))

(define* (read-palette #:key (path #f) (fallback #f))
  "The palette this machine provides, or FALLBACK.

PATH overrides discovery.  The format is taken from the extension, so a caller
does not have to say which reader to use."
  (let* ((found (if path (cons path (if (string-suffix? ".css" path) 'css 'toml))
                    (find-palette-file)))
         (reader (and found
                      (case (cdr found)
                        ((css) read-colors-css)
                        (else read-colors-toml)))))
    (or (and reader (reader (car found)))
        fallback)))

;;; ---------------------------------------------------------------------------
;;; The fallback palette
;;; ---------------------------------------------------------------------------

;; Used when nothing on the machine provides colours.  Deliberately close to
;; the Omarchy default so a fresh machine does not look broken, and complete:
;; every name a stylesheet might reference exists, so a missing theme file
;; changes colours rather than making rules fail.
(define default-palette
  (make-palette
   '((mode              . "dark")
     (accent            . "#7d82d9")
     (selection         . "#252e56")
     (muted             . "#6d7db6")
     (background        . "#060B1E")
     (dark-background   . "#040816")
     (darker-background . "#030610")
     (lighter-background . "#131a3a")
     (foreground        . "#ffcead")
     (dark-foreground   . "#6d7db6")
     (light-foreground  . "#c9b8a6")
     (red               . "#ED5B5A")
     (yellow            . "#E9BB4F")
     (orange            . "#eb8b54")
     (green             . "#92a593")
     (cyan              . "#a3bfd1")
     (blue              . "#7d82d9")
     (magenta           . "#c89dc1"))
   #:source "built-in default"))

;;; ---------------------------------------------------------------------------
;;; Emitting CSS
;;; ---------------------------------------------------------------------------

(define* (palette->css-vars palette #:optional (selector ":root"))
  "PALETTE as a CSS custom-property block for SELECTOR.

  :root { --accent: #7d82d9; ... }

A selector is needed because GTK has no document root: `:root' matches every
widget, which is what makes the variables visible throughout the tree."
  (string-append
   selector " {\n"
   (apply string-append
          (map (lambda (entry)
                 ;; Underscores become hyphens.  Omarchy writes
                 ;; dark_background and bright_foreground, and the CSS
                 ;; convention -- which every rule a caller writes will follow
                 ;; -- is --dark-background.  Emitting the underscore form
                 ;; declares variables nothing references, and looks correct
                 ;; because the source file uses underscores too.
                 (format #f "  --~a: ~a;\n"
                         (list->string (map (lambda (c)
                                              (if (char=? c #\_) #\- c))
                                            (string->list (symbol->string (car entry)))))
                         (cdr entry)))
               (palette-entries palette)))
   "}\n"))
