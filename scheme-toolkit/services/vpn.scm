;;; (scheme-toolkit services vpn) -- NetworkManager's VPN connections, by nmcli
;;;
;;; PORTED FROM the Omarchy VPN plugin's `Model.js' (~/GIT/omarchy-vpn), which
;;; was written to be free of Qt for exactly this: it parses `nmcli' and builds
;;; the commands, and knows nothing about a bar.  So it is a toolkit service --
;;; any shell that wants a VPN switch wants this -- and the widget that draws it
;;; is the desktop's.
;;;
;;; WHY `nmcli' AND NOT AstalNetwork: Astal has no VPN connections at all, and
;;; NetworkManager's own typelib would mean the `connections' list that
;;; (scheme-toolkit services network) records as unusable through G-Golf.  The
;;; plugin reads `nmcli' for the same reason, and `known-wifi-ssids' next door
;;; already does.
;;;
;;; ONLY GENUINE VPN TYPES.  `vpn' (NetworkManager's VPN plugins -- OpenVPN, an
;;; imported .ovpn) and `wireguard' (NM's native WireGuard).  Anything else that
;;; happens to be a tunnel -- tailscale0, a plain tun, docker's bridges -- is not
;;; what a user means by "my VPN", and the plugin narrows to these two to keep it
;;; out; so does this.

(define-module (scheme-toolkit services vpn)
  #:use-module (scheme-toolkit process)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:export (<vpn-connection> vpn-connection?
            vpn-connection-name vpn-connection-type vpn-connection-state
            vpn-connection-device
            vpn-active? vpn-wireguard?
            parse-nmcli-connections nmcli-split
            vpn-connections vpn-connections-from
            active-vpn-names
            vpn-up! vpn-down!
            vpn-list-command vpn-up-command vpn-down-command))

;;; ---------------------------------------------------------------------------
;;; A connection
;;; ---------------------------------------------------------------------------

;; One row of `nmcli -t --fields NAME,TYPE,STATE,DEVICE connection show'.  STATE
;; is "activated", "activating", "deactivating", "deactivated", or "" for one
;; that has never been up.
(define-record-type <vpn-connection>
  (make-vpn-connection name type state device)
  vpn-connection?
  (name vpn-connection-name)
  (type vpn-connection-type)
  (state vpn-connection-state)
  (device vpn-connection-device))

(define (vpn-active? c) (string=? (vpn-connection-state c) "activated"))

(define (vpn-wireguard? c)
  (string-ci=? (vpn-connection-type c) "wireguard"))

(define (vpn-type? type)
  (member (string-downcase (or type "")) '("vpn" "wireguard")))

;;; ---------------------------------------------------------------------------
;;; Parsing nmcli
;;; ---------------------------------------------------------------------------

(define (nmcli-split line sep)
  "LINE split on SEP, with `nmcli -t''s escaping undone.

`-t' escapes an embedded colon or backslash with a backslash, so a connection
NAME containing either would otherwise be cut in two.  The plugin's
`splitTopLevel': a backslash takes the next character literally."
  (let loop ((chars (string->list line)) (current '()) (fields '()))
    (cond ((null? chars)
           (reverse (cons (list->string (reverse current)) fields)))
          ((and (char=? (car chars) #\\) (pair? (cdr chars)))
           (loop (cddr chars) (cons (cadr chars) current) fields))
          ((char=? (car chars) sep)
           (loop (cdr chars) '() (cons (list->string (reverse current)) fields)))
          (else (loop (cdr chars) (cons (car chars) current) fields)))))

(define (parse-nmcli-connections raw)
  "Every connection in RAW -- `nmcli -t --fields NAME,TYPE,STATE,DEVICE
connection show' output -- as <vpn-connection>s.  ALL types: filtering is
`vpn-connections-from''s, so a test can see what was parsed."
  (filter-map (lambda (line)
                (and (not (string-null? (string-trim-both line)))
                     (let ((cols (nmcli-split line #\:)))
                       (and (>= (length cols) 3)
                            (make-vpn-connection
                             (list-ref cols 0)
                             (list-ref cols 1)
                             (string-downcase (list-ref cols 2))
                             (string-trim-both
                              (if (> (length cols) 3) (list-ref cols 3) "")))))))
              (string-split (or raw "") #\newline)))

(define (vpn-connections-from connections)
  "The VPN ones of CONNECTIONS, ACTIVE FIRST, then by name -- the plugin's
`vpnRows' order, so what is connected is at the top of the panel."
  (stable-sort (filter (lambda (c) (vpn-type? (vpn-connection-type c))) connections)
               (lambda (a b)
                 (if (eq? (vpn-active? a) (vpn-active? b))
                     (string<? (vpn-connection-name a) (vpn-connection-name b))
                     (vpn-active? a)))))

(define (active-vpn-names connections)
  "The names of the active VPNs in CONNECTIONS, in display order."
  (map vpn-connection-name
       (filter vpn-active? (vpn-connections-from connections))))

;;; ---------------------------------------------------------------------------
;;; The commands
;;; ---------------------------------------------------------------------------

(define (vpn-list-command)
  '("nmcli" "-t" "--fields" "NAME,TYPE,STATE,DEVICE" "connection" "show"))

;; BY `id', as the plugin does: a connection NAME, said to be a name, so a name
;; that happens to look like a UUID or a path is not read as one.
(define (vpn-up-command name) (list "nmcli" "connection" "up" "id" name))
(define (vpn-down-command name) (list "nmcli" "connection" "down" "id" name))

(define (vpn-connections)
  "The VPN connections NetworkManager knows, active first; or #f when `nmcli'
could not be run -- which is not the same as having none, and a panel should
say which."
  (let ((out (run-command (vpn-list-command))))
    (and out (vpn-connections-from (parse-nmcli-connections out)))))

(define (vpn-up! name)
  "Start the VPN called NAME.  Returns at once; the change shows on the next read.

DETACHED, as the plugin's `execDetached' is: bringing a VPN up can take seconds
-- an OpenVPN handshake, a password agent -- and the bar must not wait for it."
  (exec-async (vpn-up-command name)))

(define (vpn-down! name)
  "Stop the VPN called NAME.  Returns at once, like `vpn-up!'."
  (exec-async (vpn-down-command name)))
