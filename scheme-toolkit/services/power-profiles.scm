;;; (scheme-toolkit services power-profiles) -- power saver / balanced / performance
;;;
;;; AstalPowerProfiles, which is a wrapper over the POWER PROFILES DAEMON
;;; (org.freedesktop.UPower.PowerProfiles) -- so the profiles and the switching
;;; are a D-Bus property and method, with no `powerprofilesctl' subprocess.
;;;
;;; THAT IS A REAL DIFFERENCE FROM OMARCHY'S PANEL, which shells out to
;;; `omarchy-powerprofiles-list' and `omarchy-powerprofiles-set' and parses their
;;; output.  Nothing here does: the daemon is the source, the profiles arrive as
;;; a property, and setting one is a method call.

(define-module (scheme-toolkit services power-profiles)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (scheme-toolkit file)      ; the kernel's profile list
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)

  #:export (power-profiles
            power-profiles-supported?
            power-profile power-profile-live power-profiles-list
            power-profile-set! power-profile-next!
            power-profile-icon power-profile-label))

(define (power-profiles) (service-instance 'power-profiles))

(define (supported? prop)
  (let ((p (power-profiles)))
    (and p (catch #t (lambda () (slot-ref p prop)) (lambda args #f)))))

(define (power-profiles-supported?)
  "Whether the power-profiles daemon is there and has profiles to offer."
  (and (power-profiles) (pair? (power-profiles-list)) #t))

(define (power-profile)
  "The active profile, as a SYMBOL, or #f.  A plain read, not an accessor.

CONVERTED FROM A STRING, because Astal's `active-profile' property answers the
string \"performance\" and everything else here speaks symbols: the list from the
kernel is symbols, `(eq? \"performance\" 'performance)' is #f, and comparing the two
against each other marked NOTHING as selected in the battery menu -- which is what
its three buttons were doing.

NOT AN ACCESSOR, and that is a compromise.  `bind-obj' would give one, but a
`create-computed' over it inside this module throws `Unbound variable:
performance' -- a symbol out of my own data being evaluated as code, which is not
a shape I have explained yet.  Since the battery menu rebuilds itself when it
opens, a plain read is enough for it; a widget that wanted to FOLLOW the daemon
would want the accessor, and that is the piece still to fix."
  (let ((p (power-profiles)))
    (if (not p)
        #f
        (let ((v (catch #t (lambda () (slot-ref p 'active-profile)) (lambda args #f))))
          (cond ((string? v) (string->symbol v))
                ((symbol? v) v)
                (else #f))))))

(define (power-profile-live)
  "An ACCESSOR over the daemon's active profile, as a STRING, for watching.

THE LIVE ONE, and the reason `power-profile' above is a plain read: this module's
symbols are the convenience, and an accessor that CONVERTS would have to be a
`create-computed' -- which, inside this module, throws `Unbound variable:
performance' (a symbol out of my own data, evaluated as code; see above).  A
widget does not need the conversion to WATCH: it needs the change, and the string
it arrives as is irrelevant when the reaction is \"rebuild and re-read\"."
  (bind-obj (power-profiles) "active-profile" 'power-profile-live))

(define (power-profiles-list)
  "Every profile this machine offers, as a list of symbols, or '().

READ FROM THE KERNEL, NOT FROM ASTAL.  AstalPowerProfiles declares a
`get_profiles' method and calling it takes the whole process down -- measured:
`free(): invalid size' and a core dump, from a fresh interpreter, with no error a
`catch' can hold.  A method that segfaults is not something to call and guard; it
is something not to call.

The kernel's own list is the same source the daemon reads:
/sys/firmware/acpi/platform_profile_choices, space-separated.  It names them
`low-power' and `balanced' and `performance' where the daemon says `power-saver',
so the translation is here.  A machine with none -- a desktop -- answers '(),
which is the truth and is what the widgets test."
  (let ((choices (catch #t (lambda () (read-file "/sys/firmware/acpi/platform_profile_choices"))
                          (lambda args #f))))
    (if (not choices)
        '()
        (filter-map (lambda (word)
                      (case (string->symbol (string-trim-both word))
                        ((low-power) 'power-saver)
                        ((balanced) 'balanced)
                        ((performance) 'performance)
                        (else #f)))
                    (string-split (string-trim-both choices) #\space)))))

(define (power-profile-set! profile)
  "Ask the daemon to switch to PROFILE (a symbol).  Returns whether the call went
out.

PROFILE IS A SYMBOL, not an accessor: `power-profile' answers an ACCESSOR (so a
widget can bind to it), and handing that to the setter is `wrong-type-arg' --
which is what `power-profile-next!' did until it was told to read the value.

SENT AS A STRING, because the daemon's method takes one and this module's names
are symbols; the conversion is here rather than at every call site."
  (let ((p (power-profiles)))
    (and p (catch #t (lambda () (set-active-profile p (if (symbol? profile)
                                               (symbol->string profile)
                                               profile))
                      #t)
                  (lambda (key . rest)
                    (format (current-error-port)
                            "scheme-toolkit: power profiles: cannot set ~a: ~a~%" profile key)
                    #f)))))

(define (power-profile-next!)
  "Step to the next profile, wrapping.  For a one-click bar item.

Nothing happens when the daemon offers no profiles, which is the case on a
machine without platform profile support -- a desktop, an older laptop -- and a
button that does nothing is the right answer there."
  (let* ((all (power-profiles-list))
         ;; THE VALUE, not the accessor.
         (now (st-peek (power-profile))))
    (and (pair? all)
         (power-profile-set!
          (or (and now (let ((rest (memq now all)))
                         (and (pair? rest) (or (and (pair? (cdr rest)) (cadr rest))
                                               (car all)))))
              (car all))))))

(define (power-profile-icon profile)
  "A Nerd Font glyph for PROFILE, from Omarchy's own mapping.

`integer->char' AND NOT `\"\\U000F032A\"', which is not a Unicode escape in Guile:
it reads as a six-digit hex escape plus the literal text `2A', so these buttons
read `༃2A Power saver'.  The codepoints are Omarchy's, read out of its Model.js
with `ord'."
  (glyph (case profile
           ((power-saver) #x0F032A)
           ((balanced)    #x0F029A)
           ((performance) #x0F04C5)
           (else          #x0F0084))))

(define (glyph codepoint) (string (integer->char codepoint)))

(define (power-profile-label profile)
  "PROFILE as a person reads it."
  (case profile
    ((power-saver) "Power saver")
    ((balanced) "Balanced")
    ((performance) "Performance")
    (else "")))
