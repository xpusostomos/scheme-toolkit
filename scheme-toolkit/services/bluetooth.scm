;;; (scheme-toolkit services bluetooth) -- BlueZ, through AstalBluetooth
;;;
;;; The adapter, the devices BlueZ knows about, and the four things a panel does
;;; with them: switch the radio, scan, connect or disconnect, forget.
;;;
;;; NOTHING HERE SHELLS OUT.  ags2-shell unpairs by running `bluetoothctl remove'
;;; and Omarchy by running its own `omarchy-bluetooth-device' script; Astal
;;; already exposes `Adapter.remove_device', which is the same call to BlueZ
;;; without a subprocess in the middle.
;;;
;;; TWO TRAPS, BOTH MEASURED ON THIS MACHINE, AND NEITHER LOOKS LIKE A BINDING
;;; PROBLEM WHEN YOU HIT IT:
;;;
;;;   1. THE LIST PROPERTIES ARE RAW POINTERS.  `devices' and `adapters' are
;;;      GList-valued, and G-Golf answers `(slot-ref bt 'devices)' with
;;;      #<pointer 0x...> -- not a list, and not #f either.  `as-list' of that
;;;      pointer is '(), so the obvious code reports NO DEVICES FOREVER, WITH NO
;;;      ERROR AND NO WARNING.  The METHODS (`get-devices', `get-adapters')
;;;      convert properly and give a real Scheme list; an empty one comes back as
;;;      #f, which is exactly what `as-list' is for.  Everything here uses the
;;;      methods -- as does the hyprland service, for the same reason.
;;;
;;;   2. THE ASYNC METHODS TAKE A CALLBACK AND ITS USER DATA, so their generics
;;;      are three arguments wide and `(connect-device d)' answers "No applicable
;;;      method".  `(connect-device d #f #f)' is the call with no callback at all
;;;      -- the same shape `deactivate-connection' needs in
;;;      (scheme-toolkit services network).  Read out of the GOOPS method
;;;      specializers, not guessed: connect_device (3), set_powered (2),
;;;      remove_device (2), start_discovery (1), stop_discovery (1), pair (1).
;;;
;;; AND A VOID METHOD IS NOT A FAILED ONE.  `set-powered', `start-discovery' and
;;; the rest return NO values on success, so a caller that expects one gets
;;; "Zero values returned to single-valued continuation" and reads it as an
;;; error.  Every action below answers #t for "the call went out"; what actually
;;; happened arrives afterwards, as a property change.

(define-module (scheme-toolkit services bluetooth)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit service-helpers)
  ;; read-file and write-file, for the kernel's rfkill switch -- see the note on
  ;; `rfkill-bluetooth-device'.  Both were MISSING when that code was first
  ;; written, and a `catch' around each call turned "Unbound variable" into "no
  ;; rfkill device found", so the recovery silently did nothing.  Caught by
  ;; `bin/scheme-toolkit check-unbound'.
  #:use-module (scheme-toolkit file)
  ;; `scandir'.  Same trap: it is not in the default environment, and the same
  ;; `catch' hid it.  (This project has now been bitten by a missing `scandir'
  ;; three times -- see docs/known-issues.md.)
  #:use-module (ice-9 ftw)
  ;; put-bytevector, for the /dev/rfkill event.
  #:use-module (ice-9 binary-ports)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)

  #:export (bluetooth
            bluetooth-powered bluetooth-connected
            bluetooth-adapter bluetooth-devices bluetooth-devices-watch
            bluetooth-on? bluetooth-adapter-powered bluetooth-adapter-seen?
            bluetooth-rfkill-blocked? bluetooth-unblock!
            bluetooth-scanning bluetooth-scanning? bluetooth-adapter-discovering
            bluetooth-scan! bluetooth-scan-stop!
            bluetooth-power! bluetooth-toggle!
            bluetooth-connect! bluetooth-disconnect! bluetooth-forget!
            bluetooth-device-ref
            bluetooth-device-label bluetooth-device-glyph bluetooth-device-battery
            bluetooth-device-connected? bluetooth-device-paired?
            bluetooth-device-connecting? bluetooth-human-name?
            bluetooth-name-unusable? bluetooth-device-groups))

;;; ---------------------------------------------------------------------------
;;; The imports
;;; ---------------------------------------------------------------------------
;;
;; The class names AND the method names.  Importing a class brings its members,
;; but the METHOD names are what the code below calls, and G-Golf binds a method
;; into the module CURRENT AT THE TIME of the call -- so this has to run here, at
;; load, inside this module, and not from a helper elsewhere.
;;
;; `get_is_powered' is Bluetooth's; `get_powered' is Adapter's.  Both are
;; booleans about the radio and they are different questions about different
;; objects, which is the sort of thing a merged generic hides well.

(eval-when (load eval)
  (catch #t
    (lambda ()
      (g-irepository-require "AstalBluetooth")
      (for-each (lambda (name) (gi-import-by-name "AstalBluetooth" name))
                '("Bluetooth" "Adapter" "Device"
                  ;; the Bluetooth aggregate
                  "get_is_powered" "get_is_connected" "get_adapters" "get_devices"
                  "get_adapter" "toggle"
                  ;; the adapter
                  "get_powered" "get_discovering" "set_powered"
                  "start_discovery" "stop_discovery" "remove_device"
                  ;; a device
                  "get_name" "get_alias" "get_address" "get_connected"
                  "get_paired" "get_connecting" "get_trusted" "get_blocked"
                  "get_battery_percentage" "get_icon" "get_rssi"
                  "connect_device" "disconnect_device" "pair" "cancel_pairing")))
    (lambda args #f)))

;;; ---------------------------------------------------------------------------
;;; The service, and the two things the bar shows
;;; ---------------------------------------------------------------------------

(define (bluetooth) (service-instance 'bluetooth))

(define (bluetooth-powered)
  "Whether the radio is on, as an ACCESSOR -- the bar's glyph follows it.

`is-powered' rather than the adapter's `powered': the adapter object comes and
goes (a machine with the radio off can still have one; a machine with none has
neither), and the bar item has to be buildable either way.  This property lives
on the service itself."
  (bind-obj (bluetooth) "is-powered" 'bluetooth-powered))

(define (bluetooth-connected)
  "Whether anything at all is connected, as an ACCESSOR.

The distinction the bar's glyph is drawn from: a radio that is on with nothing
attached and a radio with a headset on it are the same switch and not the same
thing."
  (bind-obj (bluetooth) "is-connected" 'bluetooth-connected))

;;; ---------------------------------------------------------------------------
;;; The adapter
;;; ---------------------------------------------------------------------------

(define (bluetooth-adapter)
  "The adapter, or #f when the machine has none.

`get-adapter' first and the first of `get-adapters' second, because the single
adapter property is what BlueZ's own model means by it and the list is the
fallback for a machine where it is unset.  Both are object-valued and convert
properly -- it is only the LIST properties that come back as pointers."
  (let ((b (bluetooth)))
    (and b
         (catch #t
           (lambda ()
             (let ((found (or (get-adapter b)
                              (let ((all (as-list (get-adapters b))))
                                (and (pair? all) (car all))))))
               (when found (%adapter-seen-set! #t))
               found))
           (lambda args #f)))))

;;; ---------------------------------------------------------------------------
;;; Devices
;;; ---------------------------------------------------------------------------

(define (bluetooth-devices)
  "Every device BlueZ has, as a list of <astal-bluetooth-device>, or '().

THE METHOD, NOT THE PROPERTY -- see the header.  The property gives an opaque
pointer and every list built from it is silently empty."
  (let ((b (bluetooth)))
    (and b (catch #t (lambda () (as-list (get-devices b))) (lambda args '())))))

(define (bluetooth-state-summary)
  "A value that CHANGES whenever something a panel draws changes.

WHY A SUMMARY AND NOT THE DEVICE LIST.  `create-connection' only notifies its
subscribers when the new value differs by `equal?' from the old one, and a list
of the same device OBJECTS is `equal?' to itself -- so publishing the device
list on a connect would publish nothing, and a panel bound to it would never
hear.  Building a value out of the fields the panel actually shows makes a
connect, a disconnect, a pairing or a battery report a real change."
  (map (lambda (dev)
         (list (bluetooth-device-label dev)
               (bluetooth-device-ref dev 'connected)
               (bluetooth-device-ref dev 'connecting)
               (bluetooth-device-ref dev 'paired)
               (bluetooth-device-battery dev)))
       (bluetooth-devices)))

(define (bluetooth-devices-watch)
  "An ACCESSOR that changes whenever the Bluetooth situation changes.

WHAT IT WATCHES, and the omission that made the panel look dead: it listened only
for `device-added', `device-removed', `adapter-added' and `adapter-removed'.
CONNECTING A DEVICE IS NONE OF THOSE -- it adds nothing to the list and removes
nothing, it changes a property ON a device -- so the panel sat there waiting for
an event that never came.  Reported as: \"it doesn't proactively detect
connections and disconnections, it just sits there waiting for an event that
never comes.\"

So each device is watched too, for the properties a row draws: `connected',
`connecting', `paired' and `battery-percentage'.  Devices come and go, so the
watching happens on every publish, and a device already watched is not watched
twice (a hash of the devices seen).  A device that goes away takes its handlers
with it -- they are connected to the device itself.

The initial value is read now rather than left empty, so a panel built before
any signal arrives is still correct.

THE SETTER IS NOT CALLED `push!', which is what a connection setter looks like
it should be called: `(scheme-toolkit gi)' re-exports the whole G-Golf interface
and G-Golf has a `push!' MACRO of its own, so a local binding of that name is not
a binding at all -- the expander tries to expand `(push! x)' as G-Golf's
two-argument push and the module fails to compile with \"source expression failed
to match any pattern in form push!\", an error about syntax in a file whose
problem is a name."
  (let ((b (bluetooth)))
    (if (not b)
        (create-accessor (lambda () '()) 'bluetooth-devices)
        (let-values (((acc publish!) (create-connection '() 'bluetooth-devices)))
          (let ((watched (make-hash-table)))
            (define (update!)
              (publish! (bluetooth-state-summary))
              (for-each
               (lambda (dev)
                 (unless (hash-ref watched dev #f)
                   (hash-set! watched dev #t)
                   (for-each
                    (lambda (prop)
                      (catch #t
                        (lambda ()
                          (connect dev
                                   (string->symbol (string-append "notify::" prop))
                                   (lambda args (update!))))
                        (lambda args #f)))
                    '("connected" "connecting" "paired" "battery-percentage"))))
               (bluetooth-devices)))
            (for-each (lambda (signal) (connect b signal (lambda args (update!))))
                      '("device-added" "device-removed"
                        "adapter-added" "adapter-removed"))
            (update!)
            acc)))))

;;; ---------------------------------------------------------------------------
;;; The kernel's switch
;;; ---------------------------------------------------------------------------
;;
;; SWITCHING THE RADIO OFF MAKES THE ADAPTER DISAPPEAR, and this is why.
;;
;; On this machine, powering the adapter off through BlueZ sets an rfkill SOFT
;; BLOCK, and bluez then REMOVES the adapter object from D-Bus altogether --
;; measured: `busctl tree org.bluez` shows nothing under /org/bluez, `bluetoothctl
;; list` finds no controller, and Astal's adapter list is empty.  With no adapter
;; there is no `org.bluez.Adapter1` interface left, so:
;;
;;   `set-powered' has nothing to act on -- turning it back ON from the adapter
;;   is impossible, and Astal's own `toggle' fails with
;;   "astal_bluetooth_adapter_get_powered: assertion 'self != NULL' failed".
;;
;; The way back is the kernel's own switch: clearing the soft block makes bluez
;; re-register the adapter, powered, within a second or two.  Measured, and it
;; needs no privileges on this machine -- `rfkill unblock bluetooth' succeeded as
;; the desktop user (a udev ACL on the rfkill device).
;;
;; READ THROUGH /sys, NOT THROUGH `rfkill': the same rule as the rest of this
;; toolkit, and it keeps the recovery in Scheme rather than in a subprocess.
;; /sys/class/rfkill/rfkill<N>/type says what the switch controls ("bluetooth"),
;; and `soft' is the one we can clear.

(define (rfkill-bluetooth-device)
  "The rfkill device controlling bluetooth, as a directory, or #f."
  (let ((entries (catch #t (lambda () (scandir "/sys/class/rfkill")) (lambda args '()))))
    (let loop ((names entries))
      (cond ((null? names) #f)
            (else
             (let ((dir (string-append "/sys/class/rfkill/" (car names))))
               (if (equal? (catch #t (lambda () (string-trim-both (read-file (string-append dir "/type"))))
                                  (lambda args #f))
                           "bluetooth")
                   dir
                   (loop (cdr names)))))))))

(define (bluetooth-rfkill-blocked?)
  "Whether the kernel has the bluetooth radio soft-blocked; #f if there is no
such switch on this machine."
  (let ((dir (rfkill-bluetooth-device)))
    (and dir
         (equal? "1" (catch #t (lambda () (string-trim-both (read-file (string-append dir "/soft"))))
                            (lambda args "0"))))))

(define (bluetooth-unblock!)
  "Clear the kernel's soft block.  #t when it is clear afterwards.

THROUGH /dev/rfkill, NOT THROUGH /sys.  The obvious version writes "0" to
/sys/class/rfkill/rfkillN/soft -- and it silently does nothing, because that file
is root-owned and 0644: a desktop user may READ the switch but not write it.  The
`rfkill' command changes it by writing an event to `/dev/rfkill' instead, which IS
writable by the desktop user (measured: `rfkill unblock bluetooth' succeeds as
this user with no privileges), and that is what this does -- no subprocess, the
same file interface the command itself uses.

The event is `struct rfkill_event' from linux/rfkill.h, packed, 8 bytes:

    u32 idx   u8 type   u8 op   u8 soft   u8 hard

`idx' is the number in the device's name (`rfkill0'), `op' is RFKILL_OP_CHANGE,
and `soft' is the state being asked for.

THE TWO CONSTANTS WERE BOTH WRONG THE FIRST TIME, and the failure was silent --
the write succeeded, the radio stayed blocked, and nothing was logged.  Read them
out of /usr/include/linux/rfkill.h rather than remembering them:

    RFKILL_OP_ADD 0, DEL 1, CHANGE 2, CHANGE_ALL 3
    RFKILL_TYPE_ALL 0, WLAN 1, BLUETOOTH 2, UWB 3, ...

so the first version sent op=CHANGE_ALL addressed to type=UWB: a well-formed
event about a device this machine does not have, which the kernel accepted and
did nothing with."
  (let* ((dir (rfkill-bluetooth-device))
         (name (and dir (basename dir)))
         ;; "rfkill12" -> 12
         (index (and name (string->number (substring name 6)))))
    (and index
         (catch #t
           (lambda ()
             (let ((event (make-bytevector 8 0)))
               (bytevector-u32-set! event 0 index (endianness little))
               (bytevector-u8-set! event 4 2)     ; type: RFKILL_TYPE_BLUETOOTH
               (bytevector-u8-set! event 5 2)     ; op:   RFKILL_OP_CHANGE
               (bytevector-u8-set! event 6 0)     ; soft: unblocked
               (bytevector-u8-set! event 7 0)     ; hard: cannot be changed
               (let ((port (open-file "/dev/rfkill" "wb")))
                 (put-bytevector port event)
                 (close-port port))
               (usleep 400000)
               (not (bluetooth-rfkill-blocked?))))
           (lambda (key . rest)
             (format (current-error-port)
                     "scheme-toolkit: bluetooth: cannot clear the radio block: ~a ~a~%"
                     key rest)
             #f)))))

;; WHETHER THIS MACHINE HAS EVER HAD AN ADAPTER.  Once the radio is switched off
;; the adapter is gone and indistinguishable from a machine that has none -- and
;; the two want different words and different controls.  Remembering that one was
;; seen is what lets a panel say "Off" (with the switch still there to turn it
;; back on) instead of "No adapter" and nothing to press.
(define-values (%adapter-seen %adapter-seen-set!) (create-state #f))

(define (bluetooth-adapter-seen?)
  "Whether this machine has a Bluetooth adapter, asked in a way that survives the
radio being switched off.

TWO ANSWERS, OR'd, because neither is enough alone.  `%adapter-seen' is set
whenever an adapter object is actually found -- but it is per PROCESS, so a shell
started while the radio is switched off has never seen one and would call the
machine adapterless.  The KERNEL'S RFKILL DEVICE answers that case: a
`/sys/class/rfkill/*/type' of "bluetooth" exists exactly when the machine has a
Bluetooth radio, and it stays readable while the radio is blocked (measured: with
the block set, bluez exports nothing under /org/bluez and this still reads
`bluetooth')."
  (or (st-peek %adapter-seen) (and (rfkill-bluetooth-device) #t)))

(define (bluetooth-device-ref dev prop)
  "DEV's property PROP as a Scheme value, or #f.

One place that maps a name to the G-Golf call, so a widget does not need the
method names in scope -- the same shape `access-point-ref' has in the network
service, and for the same reason: a method imported into the wrong module is an
error about an unbound variable naming nothing to do with bluetooth.

EVERY READ IS IN A `catch', because a device can be destroyed underneath us:
BlueZ churn during discovery removes devices while a panel is drawing them, and
a widget that dies during a repaint takes the shell with it."
  (and dev
       (catch #t
         (lambda ()
           (case prop
             ((name) (get-name dev))
             ((alias) (get-alias dev))
             ((address) (get-address dev))
             ((connected) (get-connected dev))
             ((paired) (get-paired dev))
             ((connecting) (get-connecting dev))
             ((trusted) (get-trusted dev))
             ((blocked) (get-blocked dev))
             ((battery) (get-battery-percentage dev))
             ((icon) (get-icon dev))
             ((rssi) (get-rssi dev))
             (else #f)))
         (lambda args #f))))

(define (bluetooth-device-connected? dev)
  (and (bluetooth-device-ref dev 'connected) #t))

(define (bluetooth-device-paired? dev)
  (and (bluetooth-device-ref dev 'paired) #t))

(define (bluetooth-device-connecting? dev)
  (and (bluetooth-device-ref dev 'connecting) #t))

(define (bluetooth-device-label dev)
  "What to call DEV: its name, else its alias, else its address.

The address is the last resort and it is a real one: an unpaired device found by
a scan very often has no name yet, and a row reading the address is more use
than a row reading nothing.  `name' first to agree with ags2-shell, which draws
`name || address'."
  (let ((name (bluetooth-device-ref dev 'name))
        (alias (bluetooth-device-ref dev 'alias)))
    (cond ((and (string? name) (not (string-null? (string-trim-both name))))
           (string-trim-both name))
          ((and (string? alias) (not (string-null? (string-trim-both alias))))
           (string-trim-both alias))
          (else (or (bluetooth-device-ref dev 'address) "")))))

(define (bluetooth-device-battery dev)
  "DEV's battery as a fraction 0.0-1.0, or #f when it does not report one.

ASTAL ANSWERS -1.0 FOR UNKNOWN, NOT #f, so the test is `>= 0' and not
`number?': a row that trusts `number?' draws \"-100%\" on every device that does
not publish a battery level, which is most of them."
  (let ((b (bluetooth-device-ref dev 'battery)))
    (and (number? b) (>= b 0) (<= b 1) b)))

;;; ---------------------------------------------------------------------------
;;; Names, and the ones that are not names
;;; ---------------------------------------------------------------------------
;;
;; Omarchy's rule, and it earns its place: BlueZ hands out devices whose "name"
;; is a UUID, a 32-digit hex blob, or the device's own address, because the
;; device has not told anyone what it is called yet.  Listing those as if they
;; were names fills a panel with unreadable rows that a person can do nothing
;; with, and the same devices come back with real names once they are paired.

(define (hex-digit? c)
  (or (and (char>=? c #\0) (char<=? c #\9))
      (and (char>=? c #\a) (char<=? c #\f))
      (and (char>=? c #\A) (char<=? c #\F))))

(define (hex-string? s)
  (and (> (string-length s) 0) (string-every hex-digit? s)))

(define (address-like? s)
  "AA:BB:CC:DD:EE:FF, or with dashes -- a Bluetooth address, not a name."
  (let ((parts (string-split (string-trim-both s)
                             (lambda (c) (or (char=? c #\:) (char=? c #\-))))))
    (and (= (length parts) 6)
         (every (lambda (p) (and (= (string-length p) 2) (hex-string? p))) parts))))

(define (uuid-like? s)
  "A 32-hex-digit blob, dashed or not, or a 0x... identifier."
  (let* ((t (string-downcase (string-trim-both s)))
         (bare (string-delete #\- t)))
    (or (and (memv (string-length t) '(32 36)) (hex-string? bare))
        (and (string-prefix? "0x" t) (hex-string? (string-drop t 2))))))

(define (bluetooth-name-unusable? name)
  "Whether NAME is a device's identity rather than a name.

THE RULE AS A PURE FUNCTION, so it can be asserted without a Bluetooth device to
hand -- the three strings below were measured on this machine, where a scan
turned up a device whose \"name\" was `66-3C-C3-BF-6F-C0' and it was correctly
kept out of every list.

An empty name counts as unusable: a row with nothing in it is not a row."
  (let ((label (if (string? name) (string-trim-both name) "")))
    (or (string-null? label)
        (uuid-like? label)
        (address-like? label))))

(define (bluetooth-human-name? dev)
  "Whether DEV has a name a person could act on."
  (not (bluetooth-name-unusable? (bluetooth-device-label dev))))

;;; ---------------------------------------------------------------------------
;;; The groups a panel draws
;;; ---------------------------------------------------------------------------

(define (bluetooth-device-groups)
  "The devices split the way Omarchy's panel splits them, as an alist:

  ((connected . devices) (known . devices) (discovered . devices))

CONNECTED is what is in use now, KNOWN is what has been paired or trusted before,
DISCOVERED is everything else -- which in practice means what a scan just found.
The three are the same list seen three ways and a device moves between them as it
is paired, connected and forgotten.

Unnamed devices are dropped here rather than by the caller, so every group is
something a person can read.  Each group is sorted by label, because BlueZ
returns them in whatever order it likes and a list that reorders itself between
two openings of the same panel is a list you cannot aim at."
  (let* ((named (filter bluetooth-human-name? (bluetooth-devices)))
         (by-label (lambda (devices)
                     (sort devices
                           (lambda (a b)
                             (string<? (string-downcase (bluetooth-device-label a))
                                       (string-downcase (bluetooth-device-label b)))))))
         (known? (lambda (dev)
                   (or (bluetooth-device-paired? dev)
                       (bluetooth-device-ref dev 'trusted)))))
    (list (cons 'connected (by-label (filter bluetooth-device-connected? named)))
          (cons 'known (by-label (filter (lambda (d)
                                           (and (not (bluetooth-device-connected? d))
                                                (known? d)))
                                         named)))
          (cons 'discovered (by-label (filter (lambda (d)
                                                (and (not (bluetooth-device-connected? d))
                                                     (not (known? d))))
                                              named))))))

;;; ---------------------------------------------------------------------------
;;; Scanning
;;; ---------------------------------------------------------------------------
;;
;; ASTAL'S `discovering' PROPERTY IS WRONG ON THIS MACHINE, and that is measured,
;; not suspected.  The control is BlueZ itself: StopDiscovery is REFUSED with
;; "No discovery started" when nothing is scanning, so a StopDiscovery that
;; SUCCEEDS proves a scan was live.  Measured in one process:
;;
;;   stop   (nothing running)  -> refused, org.bluez.Error.Failed
;;   start                     -> ok
;;   discovering property      -> #f, immediately and 300 ms later
;;   stop   (should succeed)   -> ok        <-- so a scan WAS running
;;
;; So the adapter was scanning while the property said it was not, and a panel
;; that drew its state from that property would show "Scan" instead of "Cancel"
;; and never reveal what the scan found.  What the scan DOES is recorded here
;; instead: we know when we asked for one and when we stopped it.
;;
;; THE PROPERTY IS STILL CONSULTED, because on a machine where it works it is
;; better information than ours -- it also knows about a scan started by another
;; client, which we cannot see.  So the two are OR'd for reading, while the
;; accessor a widget binds to is OURS, which is the one that reliably changes.

;; `create-state' TAKES NO NAME, unlike `create-computed': its signature is
;; (initial #:equals), and a second positional argument is read as a keyword.
(define-values (%scan-requested %scan-requested-set!)
  (create-state #f))

(define (bluetooth-adapter-discovering)
  "What BlueZ itself says about scanning, read now, or #f.

Kept separate from `bluetooth-scanning?' because they disagree on this machine
and the disagreement is the interesting part -- see the measurement above."
  (let ((a (bluetooth-adapter)))
    (and a (catch #t (lambda () (and (get-discovering a) #t)) (lambda args #f)))))

(define (bluetooth-adapter-powered)
  "Whether the ADAPTER is switched on, read now, or #f.

THE ADAPTER IS THE AUTHORITY FOR POWER, and this exists because the service's own
`is-powered' was seen to answer #f once on a cold first read -- in a freshly
recompiled process the panel drew itself as \"Off\" with the crossed-out glyph
while the adapter, asked in the same process seconds later, said #t.  Ten
subsequent runs all read #t, so that is an unreproduced one-off rather than a
fault I have characterised; what it does show is that the aggregate property is
not the thing to build a panel's state on when the adapter can be asked directly.

It is also simply the right object: `set-powered' acts on the adapter, so the
switch and the state it shows should be reading the same thing."
  (let ((a (bluetooth-adapter)))
    (and a (catch #t (lambda () (and (get-powered a) #t)) (lambda args #f)))))

(define (bluetooth-on?)
  "Whether the radio is on, read NOW: the adapter's answer, else the service's.

For a widget that has to DECIDE (which glyph, and what the switch shows) rather
than watch.  `bluetooth-powered' below is still the accessor to bind to."
  (or (bluetooth-adapter-powered) (st-peek (bluetooth-powered))))

(define (bluetooth-scanning)
  "Whether a scan is running, as an ACCESSOR, for a panel that re-renders.

OUR record and not the adapter's property: the property does not change on this
machine (measured above), so a binding to it never fires and a panel built on it
never redraws."
  %scan-requested)

(define (bluetooth-scanning?)
  "Whether a scan is running, read NOW: ours, or the adapter's if it says so."
  (or (st-peek %scan-requested) (bluetooth-adapter-discovering)))

;; BLUEZ SAYS "No discovery started" FOR A STOP THAT HAS NOTHING TO STOP, and
;; that is not a failure -- it is the answer to "is it still scanning?", and it
;; happens whenever a scan ended on its own or another client stopped it.  The
;; GError arrives through G-Golf as a `misc-error' whose message is the useful
;; part, so the test is on the rendered error rather than on a condition type
;; that does not survive the crossing.
(define (scan-already-stopped? caught-args)
  (let ((text (catch #t (lambda () (format #f "~a" caught-args)) (lambda args ""))))
    (and (string? text) (string-contains text "No discovery started") #t)))

(define (bluetooth-scan!)
  "Start looking for devices, switching the radio on first if it is off.

POWERED FIRST because a scan on a radio that is off does nothing and says
nothing -- ags2-shell does the same, and BlueZ would otherwise answer a scan
request with an error nobody sees.  Returns #t when the request went out."
  (let ((a (bluetooth-adapter)))
    (and a
         (catch #t
           (lambda ()
             (unless (get-powered a) (set-powered a #t))
             (start-discovery a)
             (%scan-requested-set! #t)
             #t)
           (lambda (key . rest)
             (format (current-error-port)
                     "scheme-toolkit: bluetooth: cannot scan: ~a ~a~%" key rest)
             #f)))))

(define (bluetooth-scan-stop!)
  "Stop looking for devices.  #t when there is nothing scanning any more.

A STOP THAT BLUEZ REFUSES IS A SUCCESS HERE: \"No discovery started\" means the
scan is already over, which is what the caller asked for.  Logging it as an error
would put a line in the journal every time someone clicked Cancel a moment after
a scan had timed out."
  (%scan-requested-set! #f)
  (let ((a (bluetooth-adapter)))
    (and a
         (catch #t
           (lambda () (stop-discovery a) #t)
           (lambda (key . rest)
             (cond ((scan-already-stopped? rest) #t)
                   (else
                    (format (current-error-port)
                            "scheme-toolkit: bluetooth: cannot stop scanning: ~a ~a~%"
                            key rest)
                    #f)))))))

;;; ---------------------------------------------------------------------------
;;; The actions
;;; ---------------------------------------------------------------------------

(define (bluetooth-power! on)
  "Switch the radio ON (a truthy value) or off.  #t when the request went out.

A RADIO GOING OFF TAKES ANY SCAN WITH IT, so the scan record is dropped here:
BlueZ will not go on discovering with the adapter down, and a panel that kept
saying \"Cancel\" after the switch was turned off would be describing a scan that
cannot be running."
  (let ((a (bluetooth-adapter)))
    (unless on (%scan-requested-set! #f))
    ;; TURNING IT ON STARTS WITH THE KERNEL SWITCH, because when the radio is off
    ;; there is no adapter object left to switch on -- see the note above
    ;; `rfkill-bluetooth-device'.  Clearing the block makes bluez re-register the
    ;; adapter, powered, on its own, so this returns before `set-powered' has
    ;; anything to act on; the adapter's arrival is a `device-added'/'adapter-added'
    ;; event the panel already watches for.
    (when on (when (bluetooth-rfkill-blocked?) (bluetooth-unblock!)))
    (and a
         (catch #t
           (lambda () (set-powered a (and on #t)) #t)
           (lambda (key . rest)
             (format (current-error-port)
                     "scheme-toolkit: bluetooth: cannot switch the radio: ~a ~a~%"
                     key rest)
             #f)))))

(define (bluetooth-toggle!)
  "The radio the other way.  For a click on the bar's glyph."
  (let ((a (bluetooth-adapter)))
    (and a (bluetooth-power! (not (get-powered a))))))

(define (bluetooth-connect! dev)
  "Ask BlueZ to connect DEV.  #t when the request went out.

THE TWO #f ARE NOT OPTIONAL and they are not `cancellable' and something else:
the generic is (device callback user-data), because Vala's async method carries
a GAsyncReadyCallback.  Passing #f for both means \"no callback\" -- the result
is dropped, which is right here, because the answer that matters is the
`connected' property changing and that arrives on its own."
  (and dev
       (catch #t
         (lambda () (connect-device dev #f #f) #t)
         (lambda (key . rest)
           (format (current-error-port)
                   "scheme-toolkit: bluetooth: cannot connect ~a: ~a ~a~%"
                   (bluetooth-device-label dev) key rest)
           #f))))

(define (bluetooth-disconnect! dev)
  "Ask BlueZ to drop DEV's connections.  #t when the request went out."
  (and dev
       (catch #t
         (lambda () (disconnect-device dev #f #f) #t)
         (lambda (key . rest)
           (format (current-error-port)
                   "scheme-toolkit: bluetooth: cannot disconnect ~a: ~a ~a~%"
                   (bluetooth-device-label dev) key rest)
           #f))))

(define (bluetooth-forget! dev)
  "Remove DEV and its pairing information.  #t when the request went out.

ON THE ADAPTER, on the device: `Adapter.remove_device'.  This is the operation
both reference shells reach for an external program to do."
  (let ((a (bluetooth-adapter)))
    (and a dev
         (catch #t
           (lambda () (remove-device a dev) #t)
           (lambda (key . rest)
             (format (current-error-port)
                     "scheme-toolkit: bluetooth: cannot forget ~a: ~a ~a~%"
                     (bluetooth-device-label dev) key rest)
             #f)))))

;;; ---------------------------------------------------------------------------
;;; The glyphs
;;; ---------------------------------------------------------------------------

(define (glyph codepoint)
  "A Nerd Font glyph, built from its codepoint.

`integer->char' AND NEVER \"\\U000F00B1\", which is not a Unicode escape in Guile:
it reads as a six-digit hex escape plus the literal text `B1'.  See the battery
widget's table for what that cost the wifi panel."
  (string (integer->char codepoint)))

(define (bluetooth-device-glyph dev)
  "The glyph for a device row: Omarchy's two, connected or not."
  (glyph (if (bluetooth-device-connected? dev) #x0F00B1 #x0F00AF)))
