;;; (scheme-toolkit services network) -- NetworkManager (AstalNetwork)
;;;
;;; The Network service, its Wi-Fi device, and the access-point list. The
;;; biggest of these modules, because Wi-Fi is the part of a shell that
;;; needs the most doing to it.

(define-module (scheme-toolkit services network)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (scheme-toolkit process)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:export (network wifi wifi-access-points wifi-active-access-point wifi-connect! wifi-disconnect! access-point-ref access-point-known? known-wifi-ssids wifi-enabled? wifi-enable! wifi-scan! wifi-scanning? wifi-ssid wifi-strength wifi-icon-name wifi-forget! wifi-state wifi-connected? wifi-state-accessor))

(define (wifi)
  "The Wi-Fi device, or #f when the machine has none."
  (let ((n (network)))
    (and n (catch #t (lambda () (get-wifi n)) (lambda args #f)))))


(define (wifi-access-points)
  "Every access point the wifi device can see, as a list, or '()."
  (let ((w (wifi)))
    (and w (catch #t (lambda () (as-list (get-access-points w)))
                   (lambda args '())))))

(define (wifi-active-access-point)
  "The access point in use, or #f."
  (let ((w (wifi)))
    (and w (catch #t (lambda () (get-active-access-point w)) (lambda args #f)))))

(define (access-point-ref ap prop)
  "AP's property PROP as a Scheme value, or #f.

The AccessPoint methods are `get-ssid', `get-strength' and so on; this is the
one place that maps a name to the call, so a caller does not need the G-Golf
names in scope -- which is the trap that made an earlier version of this file's
imports bind into the wrong module."
  (catch #t
    (lambda ()
      (case prop
        ((ssid) (get-ssid ap))
        ((strength) (get-strength ap))
        ((frequency) (get-frequency ap))
        ((requires-password) (get-requires-password ap))
        ((bssid) (get-bssid ap))
        ((icon-name) (get-icon-name ap))
        ((max-bitrate) (get-max-bitrate ap))
        ((last-seen) (get-last-seen ap))
        (else #f)))
    (lambda args #f)))

(define (known-wifi-ssids)
  "The SSIDs NetworkManager has a SAVED Wi-Fi connection for, as a list.

WHY THIS IS NOT `AccessPoint.get_connections'. That is the right question asked
in the right place -- Astal's own source is `ap.filter_connections(wifi.device
.client.connections)' -- and it is unusable here. G-Golf generates the method
with NO SPECIALIZERS AT ALL:

  n methods 1
    specializers ()
  (get-connections ap) -> goops-error

so it takes zero arguments and cannot be called on an access point, on an
NM.Client, or on anything else. It returns a `GenericArray<NM.RemoteConnection>'
and that boxed type is what G-Golf fails to turn into a receiver -- the same
failure as `AstalWorkspace', and the third time it has cost this project.

So the profiles are read from `nmcli' instead. The NAME field is the SSID for
any Wi-Fi profile the usual tools create -- Omarchy's own connect script is
`nmcli connection add type wifi con-name \"$1\" ssid \"$1\"', which makes them
the same string by construction.

BLOCKS, on purpose: it is one fast local call, and a wifi list wants the answer
before it draws. Call it ONCE per refresh and hand the result to
`access-point-known?' -- that is why the predicate takes an optional list, and
why nothing here caches. A cache would have to be invalidated the moment a new
network is joined, and it would still be a cache."
  (let ((out (run-command (list "nmcli" "-t" "-f" "NAME,TYPE"
                                "connection" "show"))))
    (if (not out)
        '()
        (filter-map
         (lambda (line)
           (let ((parts (string-split line #\:)))
             (and (= (length parts) 2)
                  (string=? (list-ref parts 1) "802-11-wireless")
                  (let ((name (list-ref parts 0)))
                    (and (not (string=? name "")) name)))))
         (string-split out #\newline)))))

(define* (access-point-known? ap #:optional known)
  "Whether NetworkManager has a saved connection for AP.

Pass KNOWN -- a list from `known-wifi-ssids' -- when asking about more than one
access point, or every call runs `nmcli' again."
  (let ((ssid (access-point-ref ap 'ssid)))
    (and ssid
         (not (string=? ssid ""))
         (and (member ssid (or known (known-wifi-ssids))) #t))))

(define (wifi-connect! ap password)
  "Connect to AP, with PASSWORD when the network needs one. Returns at once.

`activate' IS A METHOD ON THE ACCESS POINT, NOT ON THE WIFI DEVICE:

  AstalNetwork.AccessPoint.activate(password, callback, target) -> void

so this is `(activate ap ...)' and not `(activate (wifi) ap ...)'. That earlier
spelling was a goops-error on every call, and the `catch' here turned it into a
silent #f -- clicking a network did nothing and said nothing.

THE TWO TRAILING #f ARE NOT OPTIONAL. The GIR declares `callback' and `target'
nullable, but G-Golf generates the method as

  (<astal-network-access-point> <top> <top> <top>)

and calling it with two arguments is `No applicable method'. Checked with
`(method-specializers m)'; the arity is in the specializer list, not in the
error message.

A FAILED ATTEMPT LEAVES A SAVED PROFILE BEHIND. `activate' with a password
creates a connection and NetworkManager writes it to disk -- measured: three
deliberately-wrong attempts against one network left `CHARLIE_PLACE',
`CHARLIE_PLACE 1' and `CHARLIE_PLACE 2' in `nmcli connection show'. That is not
a leak to be tidied away, it is the behaviour Omarchy's panel is built around:
its `shouldRepromptPassphrase' says an auth failure means the stored passphrase
is wrong, and the profile it means is this one. It also means a network becomes
KNOWN after a single failed attempt, which is what the reference does too."
  (catch #t
    ;; AN ABSENT PASSWORD IS #f AND NOT "", and the difference is a connection
    ;; that never completes.  `activate' takes `string?', so NULL means \"no
    ;; password given -- use the saved profile\" while "" is a password: an empty
    ;; one.  Handing "" for a network that HAS a saved profile makes
    ;; NetworkManager configure the connection with an empty key, and it waits at
    ;; `config' for a handshake that cannot happen.  Measured, from the panel's
    ;; own state log: connecting to a known network went
    ;; `prepare -> config' and stopped there, with the row saying Connecting...
    ;; for ever.
    (lambda () (activate ap (and password (not (string=? password "")) password)
                         #f #f) #t)
    (lambda (key . args)
      (format (current-error-port)
              "scheme-toolkit: wifi: connect failed: ~a ~s~%" key args)
      #f)))

(define (wifi-disconnect!)
  "Drop the current Wi-Fi connection.  Returns whether the request went out.

THE TRAILING #f ARGUMENTS ARE NOT OPTIONAL -- the same trap `wifi-connect!' above
documents for `activate'.  The GIR declares `callback' and `target' nullable and
G-Golf still generates them as parameters, so the generic here is

  #<<generic> deactivate-connection (3)>

-- instance, callback, target -- and `(deactivate-connection w)' is
`No applicable method'.  Which the `catch' turned into a silent #f: the row then
sat on `Disconnecting...' for ever because nothing had been asked to disconnect.

AND THE FAILURE IS SAID OUT LOUD NOW, for the same reason."
  (let ((w (wifi)))
    (and w
         (catch #t
           (lambda () (deactivate-connection w #f #f) #t)
           (lambda (key . args)
             (format (current-error-port)
                     "scheme-toolkit: wifi: disconnect failed: ~a ~s~%" key args)
             #f)))))

(define (wifi-state)
  "The Wi-Fi device's own state, as a symbol: 'activated, 'disconnected, ...

THE DEVICE'S STATE AND NOT `connectivity', which is the question a bar should ask
when it wants to know whether the wifi is UP.  NetworkManager's connectivity is
whether the INTERNET is reachable; it is probed periodically and cached, so after
the wifi is disconnected it can go on saying `full' for a while -- and a bar built
on it goes on showing the name of a network that is no longer connected."
  (wifi-device-ref 'state))

(define (wifi-connected?)
  "Whether the Wi-Fi device is carrying a connection."
  (eq? (wifi-state) 'activated))

(define %wifi-state-accessor #f)

(define (wifi-state-accessor)
  "An ACCESSOR over the wifi device's state, for a widget to show.

FED BY THE DEVICE'S OWN `state-changed' SIGNAL, not by `create-binding' on the
`state' property: the property does not notify, so a binding answers once when it
is made and never again -- which is exactly what the bar's network icon did.  It
went on showing a connection after the radio was switched off, while the PANEL,
which reads the value when it draws, showed the crossed-out wifi glyph.  The two
were reading the same fact by different roads and only one of them was arriving.

This is the shape the workspace accessor next door uses, for the same reason: a
value that changes without a signal is read again on the signal that does exist."
  (unless %wifi-state-accessor
    (let ((dev (wifi)))
      (set! %wifi-state-accessor
            (if dev
                (let-values (((acc push!) (create-connection (wifi-state) 'wifi-state)))
                  (catch #t
                    (lambda ()
                      (connect dev "state-changed"
                               (lambda (d new old reason) (push! new))))
                    (lambda args #f))
                  acc)
                (create-connection #f 'wifi-state)))))
  %wifi-state-accessor)

(define (wifi-forget! ssid)
  "Delete the saved connection profile for SSID. Returns whether it went.

`nmcli' rather than Astal, because Astal has no forget: NetworkManager's
`Settings.DeleteConnection' would need the profile's object path, and the only
way to that path through G-Golf is the `connections' list that raises (see
`known-wifi-ssids'). Deleting by SSID is the same operation by name.

SUCCESS IS AN EMPTY STDOUT, not an exit status. `run-command' deliberately does
not treat a non-zero exit as failure -- many useful commands signal with their
status and still print the answer -- and `nmcli connection delete' on a profile
that does not exist exits non-zero with its complaint on STDERR and nothing on
stdout, which would otherwise read as success."
  (and ssid
       (not (string=? ssid ""))
       (catch #t
         (lambda ()
           (let ((out (run-command (list "nmcli" "connection" "delete" "id" ssid))))
             (and out (not (string=? out "")) #t)))
         (lambda (key . args)
           (format (current-error-port)
                   "scheme-toolkit: wifi: cannot forget ~s: ~a ~s~%" ssid key args)
           #f))))

(define (wifi-enabled?)
  "Whether the Wi-Fi radio is on."
  (let ((w (wifi)))
    (and w (catch #t (lambda () (get-enabled w)) (lambda args #f)))))

(define (wifi-enable! on)
  "Turn the Wi-Fi radio ON or off."
  (let ((w (wifi)))
    (and w (catch #t (lambda () (set-enabled w (and on #t)) #t) (lambda args #f)))))

(define (wifi-scan!)
  "Ask NetworkManager to rescan. The results arrive as access-point-added."
  (let ((w (wifi)))
    (and w (catch #t (lambda () (scan w) #t) (lambda args #f)))))

;; The four the wifi DEVICE reports about its own connection, as opposed to the
;; access point list. `wifi-device-ref' rather than four near-identical bodies.
(define (wifi-device-ref prop)
  "A property of the wifi device itself, or #f.

The device's `ssid', `strength', `icon-name', `scanning' and `state' describe the
connection IN USE -- which is why the hero of a wifi panel reads them and the rows
read the access points.

`state' IS READ AS A PROPERTY, not through a getter, and it has to be: the getter
is `get-state' and it CLASHES with Goops itself -- `get-state' is what
`(oop goops)' calls to ask an object for its state, so importing the GI one
shadows it and every `slot-ref' in this module starts answering
`No applicable method'.  A property read is the same value by another road."
  (let ((w (wifi)))
    (and w (catch #t
             (lambda ()
               (case prop
                 ((ssid) (get-ssid w))
                 ((strength) (get-strength w))
                 ((icon-name) (get-icon-name w))
                 ((scanning) (get-scanning w))
                 ((frequency) (get-frequency w))
                 ((state) (slot-ref w 'state))
                 (else #f)))
             (lambda args #f)))))

(define (wifi-ssid) (wifi-device-ref 'ssid))
(define (wifi-strength) (wifi-device-ref 'strength))
(define (wifi-icon-name) (wifi-device-ref 'icon-name))
(define (wifi-scanning?) (wifi-device-ref 'scanning))

(define (network) (service-instance 'network))
