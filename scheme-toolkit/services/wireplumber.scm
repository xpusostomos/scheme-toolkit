;;; (scheme-toolkit services wireplumber) -- audio (AstalWp)
;;;
;;; The WirePlumber service: the default speaker and microphone, every other
;;; endpoint the machine has, and the two accessors a volume widget binds to.
;;;
;;; TWO TRAPS, BOTH MEASURED, AND THE FIRST ONE MAKES EVERYTHING LOOK BROKEN:
;;;
;;;   1. ASTALWP IS POPULATED ASYNCHRONOUSLY.  A bare `guile -c' script that asks
;;;      for the default speaker gets an object whose every property is the GIR
;;;      default -- `description' #f, `volume' 0.0, `id' 0 -- and an empty
;;;      `speakers' list, while `wpctl status' shows four sinks.  There is no main
;;;      loop in such a script, so the D-Bus round trip never happens.  Inside the
;;;      shell, where there is a loop, the same calls answer properly:
;;;
;;;        default speaker  "…HDMI / DisplayPort 2 Output [Q16NB] (Stereo)"  1.0  default
;;;        speakers         ("Ryzen HD Audio Controller Speaker" 0.85 muted) …
;;;
;;;      So if these are called from anywhere without a main loop, they are
;;;      answering about an endpoint that has not been filled in yet -- not about
;;;      a machine without audio.
;;;
;;;   2. THE LISTS ARE GList-VALUED PROPERTIES, so through `slot-ref' they come
;;;      back as a raw pointer and `as-list' of that is '() -- the same trap as
;;;      the bluetooth and hyprland devices.  The METHODS (`get-speakers',
;;;      `get-microphones', `get-devices') convert.  `(get-speakers audio)', not
;;;      `(slot-ref wp 'speakers)'.
;;;
;;; AND `name' IS #f ON AN ENDPOINT.  The human label is `description'; `name' is
;;; the internal pipewire node name and is empty on this machine.

(define-module (scheme-toolkit services wireplumber)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  ;; regexp-substitute/global, for Omarchy's label cleaning.  Caught missing by
  ;; `check-unbound'.
  #:use-module (ice-9 regex)

  #:export (wp wp-default wp-audio
            speaker-volume speaker-muted? speaker-volume-set! speaker-mute-toggle!
            microphone-volume microphone-muted? microphone-volume-set!
            audio-speakers audio-microphones audio-devices
            audio-default-speaker audio-default-microphone
            audio-endpoints-watch
            endpoint-ref endpoint-label endpoint-volume endpoint-muted?
            endpoint-default? endpoint-device-label endpoint-route-label
            endpoint-set-default! endpoint-set-volume! endpoint-set-muted!
            audio-friendly-label))

(define (wp) (service-instance 'wp))

(define (wp-default prop)
  (let ((w (wp)))
    (and w
         (catch #t (lambda () (slot-ref w (string->symbol prop)))
                (lambda args #f)))))

(define (wp-audio)
  "The Audio object, which is where the endpoint LISTS live.

`(wp)' itself has no `speakers' -- the filter object does, and it is reached
through the `audio' property.  Both are GObject properties and both convert."
  (wp-default "audio"))

;;; ---------------------------------------------------------------------------
;;; The default speaker and microphone
;;; ---------------------------------------------------------------------------

;; THE BINDINGS FOLLOW THE CHAIN, which is the whole point of
;; `create-binding-path': AstalWp is populated ASYNCHRONOUSLY, so at bar-build
;; time there is often no default speaker yet -- and `bind-obj' on a missing
;; object gives a CONSTANT accessor of #f that never notices the speaker
;; arriving.  A bar item built from that shows nothing for the life of the
;; shell, which is exactly what was reported.  Following the path re-subscribes
;; when the endpoint appears.
(define (speaker-volume)
  "The default sink's volume, 0-1, FOLLOWING the endpoint as it appears."
  (create-binding-path (wp-audio) '("default-speaker" "volume") 'speaker-volume))

(define (speaker-muted?)
  "The default sink's mute flag, following the endpoint."
  (create-binding-path (wp-audio) '("default-speaker" "mute") 'speaker-muted?))

(define (speaker-volume-set! v)
  "Set the default sink's volume.  A COMMAND, not a reactive setter -- hence the
bang -- because the value lives in WirePlumber, not in this process."
  (let ((sink (wp-default "default-speaker")))
    (when sink
      (catch #t (lambda () (slot-set! sink 'volume v)) (lambda args #f)))))

(define (speaker-mute-toggle!)
  "Flip the default sink's mute flag.  Returns the new state, or #f.

A COMMAND, like speaker-volume-set!: the flag lives in WirePlumber, and reading
it back here would report a stale value until the notify arrives.  The new
state is what was written, which is what a caller wants to report."
  (let ((sink (wp-default "default-speaker")))
    (and sink
         (catch #t
           (lambda ()
             (let ((muted (not (slot-ref sink 'mute))))
               (slot-set! sink 'mute muted)
               muted))
           (lambda args #f)))))

(define (microphone-volume)
  (create-binding-path (wp-audio) '("default-microphone" "volume") 'microphone-volume))

(define (microphone-muted?)
  (create-binding-path (wp-audio) '("default-microphone" "mute") 'microphone-muted?))

(define (microphone-volume-set! v)
  "Set the default source's volume."
  (let ((mic (wp-default "default-microphone")))
    (when mic
      (catch #t (lambda () (slot-set! mic 'volume v)) (lambda args #f)))))

;;; ---------------------------------------------------------------------------
;;; Every endpoint
;;; ---------------------------------------------------------------------------

(define (audio-default-speaker)
  "The default sink AS AN OBJECT, for code that wants to work on it."
  (wp-default "default-speaker"))

(define (audio-default-microphone)
  (wp-default "default-microphone"))

(define (endpoint-ref ep prop)
  "EP's property PROP as a Scheme value, or #f.  THE VALUE, read now.

`name' IS NOT IN THE LIST ON PURPOSE, because it is #f on every endpoint on this
machine and reading it is how a caller ends up with blank rows.  `description' is
the label; `endpoint-label' is the one place that decides."
  (and ep
       (catch #t
         (lambda ()
           (case prop
             ((description) (slot-ref ep 'description))
             ((volume) (slot-ref ep 'volume))
             ((mute) (slot-ref ep 'mute))
             ((is-default) (slot-ref ep 'is-default))
             ((volume-icon) (slot-ref ep 'volume-icon))
             ((id) (slot-ref ep 'id))
             (else #f)))
         (lambda args #f))))

(define (endpoint-label ep)
  "What to call EP on screen: its description, cleaned up, and WITH THE CARD'S
NAME STRIPPED OFF THE FRONT.

WHY THE SECOND HALF MATTERS, and it is what made every row say the same thing
twice.  PipeWire builds an endpoint's description by prefixing the card's name:

    card:  \"Ryzen HD Audio Controller\"
    sink:  \"Ryzen HD Audio Controller Stereo Microphone\"

so a row showing both lines shows the same words twice.  Dropping the prefix
leaves the part that distinguishes one endpoint from another -- \"Stereo
Microphone\" beside \"Digital Microphone\", and \"HDMI / DisplayPort 2 Output
[Q16NB] (Stereo)\" beside its DisplayPort 1 and 3 siblings."
  (let* ((full (audio-friendly-label (endpoint-ref ep 'description)))
         (card (or (endpoint-device-label ep) "")))
    (if (and (> (string-length card) 0)
             (string-prefix? card full))
        (let ((rest (string-trim (substring full (string-length card)))))
          (if (string-null? rest) full rest))
        full)))

(define (endpoint-volume ep) (endpoint-ref ep 'volume))
(define (endpoint-muted? ep) (and (endpoint-ref ep 'mute) #t))
(define (endpoint-default? ep) (and (endpoint-ref ep 'is-default) #t))

(define (endpoint-device ep)
  "The CARD EP belongs to, or #f."
  (and ep (catch #t (lambda () (slot-ref ep 'device)) (lambda args #f))))

(define (endpoint-device-label ep)
  "The card's name -- the second line of Omarchy's device rows."
  (let ((d (endpoint-device ep)))
    (and d (catch #t (lambda () (slot-ref d 'description)) (lambda args #f)))))

(define (endpoint-route-label ep)
  "The name of EP's active route -- the port, which is what a person recognises."
  (and ep
       (catch #t
         (lambda ()
           (let ((r (slot-ref ep 'route)))
             (and r (slot-ref r 'description))))
         (lambda args #f))))

;;; ---------------------------------------------------------------------------
;;; Omarchy's label cleaning
;;; ---------------------------------------------------------------------------
;;
;; COPIED FROM OMARCHY'S Model.js `friendlyDeviceLabel', which does the same five
;; replacements.  PipeWire's own descriptions are prefixed with the driver and
;; suffixed with the direction -- "sof-soundwire built-in audio Analog Stereo
;; Output" -- and a panel row is not the place for the driver's name.

(define (audio-friendly-label text)
  (if (not (string? text))
      ""
      (let ((label (string-trim-both text)))
        (fold (lambda (rule acc)
                (let ((pattern (car rule)) (replacement (cdr rule)))
                  (if (procedure? pattern)
                      (pattern acc)
                      (catch #t (lambda () (regexp-substitute/global #f pattern acc 'pre replacement 'post))
                             (lambda args acc)))))
              label
              (list (cons "^sof-soundwire +" "")
                    (cons "^built-?in audio +" "")
                    (cons " +Output$" "")
                    (cons " +Input$" "")
                    (cons "\\bMicrophones\\b" "Microphone"))))))

;;; ---------------------------------------------------------------------------
;;; The lists
;;; ---------------------------------------------------------------------------

(define (audio-list getter)
  "The endpoints GETTER returns, or '().  Through the METHOD -- see the header."
  (let ((a (wp-audio)))
    (and a (catch #t (lambda () (as-list (getter a))) (lambda args '())))))

(define (audio-speakers) (audio-list get-speakers))
(define (audio-microphones) (audio-list get-microphones))
(define (audio-devices) (audio-list get-devices))

(define (audio-endpoints-watch)
  "An ACCESSOR that changes when the set of endpoints changes.

LISTENING FOR THE LIST PROPERTY IS NOT ENOUGH, exactly as with Bluetooth: the
`Audio' object emits `speaker-added', `speaker-removed', `microphone-added',
`microphone-removed' and their device and stream counterparts, and those are what
say the machine's audio situation changed.  The value published is a SUMMARY
rather than the list of objects -- `create-connection' notifies only on an
`equal?' change, and a list of the same objects compares equal to itself, so
publishing the objects would notify nothing."
  (let ((a (wp-audio)))
    (if (not a)
        (create-accessor (lambda () '()) 'audio-endpoints)
        (let-values (((acc publish!) (create-connection '() 'audio-endpoints)))
          (define (summary)
            (map (lambda (ep)
                   (list (endpoint-label ep) (endpoint-volume ep)
                         (endpoint-muted? ep) (endpoint-default? ep)))
                 (append (audio-speakers) (audio-microphones))))
          (for-each (lambda (signal)
                      (connect a signal (lambda args (publish! (summary)))))
                    '("speaker-added" "speaker-removed"
                      "microphone-added" "microphone-removed"
                      "device-added" "device-removed"
                      "stream-added" "stream-removed"))
          (publish! (summary))
          acc))))

;;; ---------------------------------------------------------------------------
;;; Changing things
;;; ---------------------------------------------------------------------------
;;
;; ALL COMMANDS, all named with a bang.  They live in WirePlumber, so nothing
;; here reads a value back -- the notify does that, and the panel binds to it.

(define (endpoint-set-default! ep)
  "Make EP the default for its direction.  #t when the write went out.

`is-default' IS WRITABLE, which is what makes clicking a device row a plain
property write with no subprocess.  Its own documentation notes that setting it
FALSE has no effect -- it is a one-way switch, which is exactly what a picker
needs."
  (and ep
       (catch #t (lambda () (slot-set! ep 'is-default #t) #t) (lambda args #f))))

(define (endpoint-set-volume! ep v)
  (and ep (catch #t (lambda () (slot-set! ep 'volume v) #t) (lambda args #f))))

(define (endpoint-set-muted! ep muted)
  (and ep (catch #t (lambda () (slot-set! ep 'mute (and muted #t)) #t) (lambda args #f))))
