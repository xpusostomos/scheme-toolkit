;;; (scheme-toolkit notify) -- notifications, and who owns the bus name
;;;
;;; THE BUS NAME IS THE WHOLE DESIGN.  `org.freedesktop.Notifications' is a
;;; single-owner name: exactly one process on the session bus receives
;;; notifications.  A shell that binds it takes notifications away from whatever
;;; had them; a shell that does not bind it can only LISTEN to a rival's state,
;;; and only if that rival exposes it.
;;;
;;; On this machine Omarchy's quickshell owns the name.  AstalNotifd then cannot
;;; acquire its proxy -- it logs "cannot get proxy: quickshell is already
;;; running", its `notifications' list stays empty, and its `notified' signal
;;; never fires.  Measured, not assumed: a `notify-send' during a 1.5 s main
;;; loop produced no signal at all.
;;;
;;; So this module does NOT reimplement a daemon.  Astal already IS the daemon
;;; (AstalNotifd.Notifd is a complete server); what was missing was knowing
;;; whether it is the one IN CHARGE, which decides whether its data means
;;; anything.  That is what `notify-status' answers, and a shell should render
;;; its notification UI from that answer rather than from an empty list that
;;; looks like "no notifications".
;;;
;;; Contrast ags2-shell (service/notifications.ts), which makes the same
;;; distinction: it checks the name owner and WARNS rather than fighting for the
;;; name.  That is the right behaviour for a shell that may be running alongside
;;; a desktop that already owns it.

(define-module (scheme-toolkit notify)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (scheme-toolkit services notifd)
  #:use-module (scheme-toolkit reactive)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (notification-name
            bus-name-owner
            notify-status
            notify-owner?
            notify-history
            notify-dont-disturb?
            notify-set-dont-disturb!
            notify-available?
            describe-notify-status))

(define notification-name "org.freedesktop.Notifications")

;;; ---------------------------------------------------------------------------
;;; Who owns the name
;;; ---------------------------------------------------------------------------

(define (bus-name-owner name)
  "The unique bus name owning NAME on the session bus, or #f.

A NULL result means nobody owns it -- which is the answer that makes a shell's
notification UI meaningful, because then AstalNotifd holds the name and its data
is real.

Asked with `gdbus' rather than Gio.DBusConnection.call_sync.  The GI call needs
a hand-built GVariant argument, and getting that wrong yields a marshalling
error that names neither the argument nor the call; a shell asks this question
once at startup, where a subprocess costs a few milliseconds and is legible. The
toolkit's `dbus' module is where a real GVariant-marshalling client belongs, for
the calls that must be frequent or async."
  (catch #t
    (lambda ()
      (let* ((p (open-input-pipe
                 (format #f "gdbus call --session --dest org.freedesktop.DBus ~
--object-path /org/freedesktop/DBus --method org.freedesktop.DBus.GetNameOwner ~
~a 2>/dev/null" name)))
             (out (get-string-all p)))
        (close-pipe p)
        ;; The reply is "(':1.3466',)" -- a tuple holding one quoted string, or
        ;; an empty/error reply when nobody owns the name.
        (let ((trimmed (and out (string-trim-both out))))
          (and trimmed
               (not (string-null? trimmed))
               (string-contains trimmed ":")
               (let* ((start (string-index trimmed #\'))
                      (stop (and start (string-rindex trimmed #\'))))
                 (and start stop (> stop start)
                      (substring trimmed (+ start 1) stop)))))))
    (lambda (key . args) #f)))

;;; ---------------------------------------------------------------------------
;;; Status
;;; ---------------------------------------------------------------------------

(define (notify-available?)
  "Is there a notification service on this bus at all?"
  (catch #t (lambda () (and (notifd) #t)) (lambda args #f)))

(define (notify-status)
  "Who is receiving notifications, as a symbol:

  'owner        this shell owns the name; its list and signals are real
  'elsewhere    another process owns it (quickshell, dunst, mako, ...); this
                shell can see nothing and its UI must say so
  'absent       nobody owns it, and AstalNotifd is not running either
  'unknown      the query itself failed

A shell picks its notification UI from this rather than from an empty list,
which is indistinguishable from a quiet desktop."
  (let ((owner (bus-name-owner notification-name)))
    (cond ((not (notify-available?)) 'absent)
          ((not owner) 'owner)
          (else 'elsewhere))))

(define (notify-owner?)
  (eq? 'owner (notify-status)))

(define (describe-notify-status)
  "One line, for a log or a diagnostic panel."
  (case (notify-status)
    ((owner)     "notifications: this shell owns the bus name")
    ((absent)    "notifications: no daemon on the session bus")
    ((elsewhere) (format #f "notifications: ~a is owned by another process; this shell cannot see its notifications"
                         notification-name))
    (else        "notifications: status unknown")))

;;; ---------------------------------------------------------------------------
;;; Reading what a rival exposes
;;; ---------------------------------------------------------------------------

(define (notify-history)
  "The currently unresolved notifications, or '().

On a machine where another process owns the name this returns '() and that is
NOT the same as \"no notifications\" -- check `notify-status' first."
  (catch #t
    (lambda ()
      (let ((n (notifd)))
        (if n
            (let ((v (catch #t (lambda () (slot-ref n 'notifications))
                            (lambda args #f))))
              (cond ((list? v) v)
                    ((vector? v) (vector->list v))
                    (else '())))
            '())))
    (lambda args '())))

;; DND is AstalNotifd's OWN flag, not the daemon's.  Setting it does not tell
;; quickshell or dunst to be quiet -- it only marks what THIS process believes.
;; Reported honestly rather than pretended otherwise: a shell that offered a DND
;; toggle and did nothing would be worse than one that did not offer it.
(define (notify-dont-disturb?)
  (catch #t (lambda () (slot-ref (notifd) 'dont-disturb)) (lambda args #f)))

(define (notify-set-dont-disturb! value)
  (catch #t
    (lambda () (slot-set! (notifd) 'dont-disturb (and value #t)) #t)
    (lambda args #f)))
