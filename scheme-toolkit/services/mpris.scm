;;; (scheme-toolkit services mpris) -- media players (AstalMpris)
;;;
;;; Every MPRIS player on the bus, the one that should be shown, and the handful
;;; of properties and commands a now-playing block needs.
;;;
;;; WHERE THE NOW-PLAYING BLOCK'S NUMBERS COME FROM, since it is the part of this
;;; that looks like magic.  ags2-shell's MediaPlayer.tsx reads them like this, and
;;; so does this:
;;;
;;;   title, artist, art-url, entry     plain properties
;;;   playback-status                   an enum: playing / paused / stopped
;;;   position, length                  SECONDS (Astal divides MPRIS' microseconds)
;;;   mpris:length                      in the METADATA variant, in MICROSECONDS
;;;
;;; THE LENGTH HAS TWO SOURCES BECAUSE NEITHER IS RELIABLE ALONE.  Many players
;;; report `length' as 0 until playback has actually started, so a paused player
;;; -- which is exactly when a panel is opened -- shows 0:00 over 0:00.  The
;;; metadata's `mpris:length' is usually there, so it is used as a fallback, and
;;; each track's answer is remembered by trackid so a later re-render does not
;;; lose it.  That is ags2-shell's `duration_cache', and this mirrors it.
;;;
;;; Measured on this machine with Firefox playing a video:
;;;
;;;   title "Do Bible Scholars Just Make Stuff Up? #earlychristianity"
;;;   artist "C. J. Cornthwaite"   paused   length 520.0   position 520.0
;;;   art-url file:///home/chris/.mozilla/firefox/firefox-mpris/1065189_0.png
;;;
;;; so `length' DOES work for Firefox.  The fallback is for the players where it
;;; does not.

(define-module (scheme-toolkit services mpris)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (scheme-toolkit service-helpers)

  #:export (mpris
            mpris-players mpris-players-model mpris-active-player mpris-players-watch
            player-ref player-playback-status player-playing? player-can-control?
            player-title player-artist player-identity player-entry player-art-url
            player-length player-position player-progress
            player-toggle! player-next! player-previous! player-seek!
            mpris-player-for-track))

(define (mpris) (service-instance 'mpris))

;;; ---------------------------------------------------------------------------
;;; GLib.Variant access, for the metadata fallback
;;; ---------------------------------------------------------------------------
;;
;; A NOTE THAT WAS HERE WAS WRONG, and this is the correction.  It said reading
;; `mpris:length' out of `player.metadata' was impossible in Scheme because
;; `lookup-value' is unbound and G-Golf cannot unpack a GVariant.  Both halves are
;; false once the right names are imported: G-Golf binds GLib's `g_variant_*'
;; functions as ordinary procedures over the raw pointer the property hands back.
;;
;; WHY IT MATTERS RATHER THAN BEING TIDINESS.  `Player.length' is -1 for a track
;; Astal has not had a PropertiesChanged for yet, and -- measured here, with
;; Firefox starting a new video -- `Player.position' sits at 0.0 at the same time
;; while `playback-status' already reads `playing'.  Astal's own poll only calls
;; check_position while playing, and that call is what delivers the first position
;; and (through the properties-changed handler) the metadata; until it lands, a
;; now-playing block shows 0:00 of nothing.  THE METADATA IS THE ONE SOURCE THAT
;; IS CORRECT AT THAT MOMENT, because the new track's properties arrive with it.
;; The pause/play the user was doing by hand was forcing the notify Astal's own
;; poll was supposed to deliver.
;;
;; IMPORTED AT LOAD TIME, INTO THIS MODULE -- never from inside a procedure and
;; never through `eval' at runtime.  `gi-import-by-name' binds into whatever
;; module is current, and doing it on the shell's main thread at runtime is how a
;; probe of mine killed the process with a truncated warning and no backtrace;
;; `(scheme-toolkit service-helpers)' documents the same lesson for get_default.
(eval-when (load eval)
  (catch #t
    (lambda ()
      (g-irepository-require "GLib")
      (for-each (lambda (name)
                  (catch #t (lambda () (gi-import-by-name "GLib" name)) (lambda args #f)))
                '("Variant" "variant_lookup_value" "variant_get_int64"
                  "variant_get_uint64" "variant_get_type_string"
                  "variant_get_type" "variant_is_of_type")))
    (lambda args #f)))

(define (variant-lookup-value variant key)
  "VARIANT's KEY, or #f.

Every argument is caught: this runs over properties whose shape is the player's
business, not ours, and a dict that lacks the key is ordinary rather than an
error."
  (and variant
       (catch #t
         (lambda () (g-variant-lookup-value variant key #f))
         (lambda args #f))))

(define (variant-double v)
  "V as a number, or #f.  Tries the signed and unsigned int64 forms, because a
GVariant's signedness is decided by the player that sent it."
  (and v
       (catch #t
         (lambda ()
           (or (catch #t (lambda () (let ((n (g-variant-get-int64 v))) (and n (exact->inexact n)))) (lambda a #f))
               (catch #t (lambda () (let ((n (g-variant-get-uint64 v))) (and n (exact->inexact n)))) (lambda a #f))))
         (lambda args #f))))

;;; ---------------------------------------------------------------------------
;;; The players
;;; ---------------------------------------------------------------------------
;;
;; THE LISTS ARE GList-VALUED PROPERTIES, so through `slot-ref' they come back as
;; a raw pointer and read as empty -- the same trap the bluetooth and hyprland
;; services document.  The METHOD converts.
;;
;; AND LIKE ASTALWP, THIS IS POPULATED ASYNCHRONOUSLY: a bare `guile -c' script
;; with no main loop reports no players even when one is playing.  Inside the
;; shell it answers.

(define (mpris-players)
  "Every MPRIS player on the bus, as a list, or '()."
  (let ((m (mpris)))
    (and m (catch #t (lambda () (as-list (get-players m))) (lambda args '())))))

;;; ---------------------------------------------------------------------------
;;; The list AS AN ACCESSOR -- the one a widget that has to BUILD around it wants
;;; ---------------------------------------------------------------------------
;;
;; WHY THIS EXISTS, and it is a bug that reached the user five times over.
;;
;; `mpris-players' is a plain read: ask now, get a list.  A widget that decides
;; whether to build a player control AT ALL -- the bar's media item does -- reads
;; it during `widget-build', which happens once, at startup.  At that moment the
;; list is empty, because AstalMpris is populated asynchronously (see the header),
;; and the widget builds its "nothing is playing" shape instead: a bare box with
;; no children.  It then never looks again, so the bar has NO MEDIA WIDGET for
;; the life of the shell, however much is playing.
;;
;; The symptom the user saw is worth recording because it pointed the wrong way:
;; the media item is invisible, so the next restart's config write records a bar
;; that still lists it, and the only visible difference between a fresh install
;; and this state is nothing at all -- which makes it look like a config that
;; lost a widget, so the config gets deleted until something happens to make the
;; timing come out right.  Measured: `bar-trees' held `<gtk-box> ... 0 children'
;; for the media item while `mpris-players' answered one player.
;;
;; THE PREVIOUS WIDGETS GOT AWAY WITH IT because they read a SERVICE object that
;; exists before the players do.  This one branches on the players themselves.
;;
;; `get-n-items' / `get-item' RATHER THAN `get-players'.  The Mpris object
;; implements Gio.ListModel on a list of WEAK references, which is what lets a
;; player exit and be collected; `get-players' returns a freshly-built strong
;; GList whose elements a binding would then hold alive.  The model's accessors
;; are the ones that do not change the ownership story.  (`get-n-items' is
;; callable -- measured -- even though `get-item' is not bound by name, and the
;; property `n-items' is not exported.)
;;
;; AND IT IS COLD, which is the reactive core's own rule: the subscription to the
;; two signals exists only while something is subscribed to the accessor.  A bar
;; with no player on the bus therefore holds no handler at all.
(define (mpris-players-model)
  "The players as an ACCESSOR, so a widget can build around it and follow it.

Changes when a player appears or goes, which is what a widget branching on
\"is anything playing\" needs; it does NOT change on a track change, which is
what `mpris-players-watch' is for."
  (let ((m (mpris)))
    (if (not m)
        (create-accessor (lambda () '()) 'mpris-player-list)
        (create-accessor
         (lambda () (model-players m))
         'mpris-player-list
         #:version-fn (lambda () (model-version m))
         #:subscribe-fn (lambda (thunk) (model-subscribe! m thunk))))))

(define (model-players m)
  "The players from the LIST MODEL, as a list, or '()."
  (catch #t
    (lambda ()
      (let ((n (get-n-items m)))
        (map (lambda (i) (get-item m i)) (iota n))))
    (lambda args '())))

;; A COUNTER AND A SET OF SUBSCRIBERS PER Mpris INSTANCE.  Module-level because
;; `mpris' is a singleton whose lifetime is the process's -- the weak table is
;; for tidiness in a test that builds several, not for the shell.
(define %model-versions (make-weak-value-hash-table))
(define %model-subs (make-weak-value-hash-table))

(define (model-version m)
  (or (hash-ref %model-versions m) 0))

(define (model-bumped! m)
  (hash-set! %model-versions m (1+ (model-version m))))

(define (model-subscribe! m thunk)
  "Subscribe THUNK to M's players, connecting the two signals the first time."
  (let ((subs (or (hash-ref %model-subs m)
                  (let ((s (make-subs)))
                    (hash-set! %model-subs m s)
                    ;; THE TWO SIGNALS ASTALMIPRIS ACTUALLY EMITS, read off the
                    ;; GIR rather than guessed: `player-added' and
                    ;; `player-closed'.  There is no `player-changed'.
                    (for-each (lambda (signal)
                                (catch #t
                                  (lambda ()
                                    (connect m signal
                                             (lambda args
                                               (model-bumped! m)
                                               (subs-notify! s))))
                                  (lambda args #f)))
                              '("player-added" "player-closed"))
                    s))))
    (subs-add! subs thunk)
    (lambda () (subs-remove! subs thunk))))

(define (player-playing? p)
  (and p
       (catch #t
         (lambda () (eq? (slot-ref p 'playback-status) 'playing))
         (lambda args #f))))

(define (mpris-active-player)
  "The player to show: one that is PLAYING, else any player at all, else #f.

PLAYING FIRST, which is ags2-shell's rule and the right one: a browser and a
music app can both be on the bus, and the one making noise is the one the block
is about.  Falling back to any player means a paused video still shows its
thumbnail and title, which is what you want from a now-playing block."
  (let ((ps (mpris-players)))
    (or (find player-playing? ps) (and (pair? ps) (car ps)))))

(define (mpris-players-watch)
  "An ACCESSOR that changes when a player appears, goes, or changes track.

A SUMMARY, not the player objects -- `create-connection' only notifies on an
`equal?' change and a list of the same objects is equal to itself, so publishing
the objects would notify nothing (the same lesson as the bluetooth device list).

Each player is watched for the properties the block draws, and the selection
(`mpris-active-player') is evaluated again on every change, so playback moving
from one player to another moves the block."
  (let ((m (mpris)))
    (if (not m)
        (create-accessor (lambda () #f) 'mpris-players)
        (let-values (((acc publish!) (create-connection '() 'mpris-players)))
          (let ((watched (make-hash-table)))
            ;; ART-URL AND TRACKID ARE PART OF THE SUMMARY, and leaving them out
            ;; is why a new video kept the previous thumbnail.  `create-connection'
            ;; notifies only on an `equal?' change, and the artwork is not a
            ;; function of anything else in this list: two videos can share a
            ;; title, an artist, a status and even a length, and the summary would
            ;; then compare equal and publish NOTHING -- so an effect keyed on the
            ;; watch would never re-run and the picture would never be replaced.
            ;; Even one video becoming another, with the metadata notifying in
            ;; stages, can pass through a summary that matches the previous one.
            (define (summary)
              (map (lambda (p)
                     (list (player-title p) (player-artist p)
                           (player-playback-status p)
                           (player-length p) (player-position p)
                           (player-ref p 'trackid) (player-art-url p)))
                   (mpris-players)))
            (define (update!)
              ;; THE SELECTION IS PART OF THE VALUE, so a change in which player
              ;; is playing is a change the panel hears about.
              (publish! (cons (and (mpris-active-player) #t) (summary)))
              (for-each
               (lambda (p)
                 (unless (hash-ref watched p #f)
                   (hash-set! watched p #t)
                   (for-each (lambda (prop)
                               (catch #t
                                 (lambda ()
                                   (connect p (string->symbol (string-append "notify::" prop))
                                            (lambda args (update!))))
                                 (lambda args #f)))
                             '("playback-status" "title" "artist" "art-url"
                               "position" "length" "metadata" "trackid"))))
               (mpris-players)))
            ;; ONLY THE TWO SIGNALS THAT EXIST.  Read off the GIR rather than
            ;; guessed: AstalMpris emits `player-added' and `player-closed', and
            ;; there is no `player-changed' -- a first version of this watched for
            ;; one, which would simply have never fired.  A player changing TRACK
            ;; is not a bus event: it is a `notify::' on the player, which is what
            ;; the per-player handlers below are for.
            (for-each (lambda (signal) (connect m signal (lambda args (update!))))
                      '("player-added" "player-closed"))
            (update!)
            acc)))))

;;; ---------------------------------------------------------------------------
;;; One player's properties
;;; ---------------------------------------------------------------------------

(define (player-ref p prop)
  "P's property PROP as a Scheme value, or #f.

EVERY READ IS IN A `catch': a player can leave the bus between the list being
read and a property being asked for, which is ordinary MPRIS churn, and a widget
that dies during a redraw takes the shell with it."
  (and p
       (catch #t
         (lambda ()
           (case prop
             ((title) (slot-ref p 'title))
             ((artist) (slot-ref p 'artist))
             ((identity) (slot-ref p 'identity))
             ((entry) (slot-ref p 'entry))
             ((art-url) (slot-ref p 'art-url))
             ((playback-status) (slot-ref p 'playback-status))
             ((position) (slot-ref p 'position))
             ((length) (slot-ref p 'length))
             ((trackid) (slot-ref p 'trackid))
             ((can-control) (slot-ref p 'can-control))
             ;; A raw <foreign> GVariant pointer, not a Scheme value.  It is here
             ;; so `metadata-length' can reach it; nothing else should read it.
             ((metadata) (slot-ref p 'metadata))
             (else #f)))
         (lambda args #f))))

(define (player-playback-status p) (player-ref p 'playback-status))
(define (player-can-control? p) (and (player-ref p 'can-control) #t))
(define (player-title p) (or (player-ref p 'title) ""))
(define (player-artist p) (or (player-ref p 'artist) ""))
(define (player-identity p) (or (player-ref p 'identity) ""))
(define (player-entry p) (or (player-ref p 'entry) ""))
(define (player-art-url p) (or (player-ref p 'art-url) ""))

;;; ---------------------------------------------------------------------------
;;; Length, with the metadata fallback and the per-track cache
;;; ---------------------------------------------------------------------------

;; trackid -> seconds.  Bounded, because a session that plays a playlist all day
;; would otherwise grow it with every track.
(define %duration-cache (make-hash-table))
(define %duration-cache-limit 64)

(define (remember-duration! track seconds)
  (hash-set! %duration-cache track seconds)
  (when (> (hash-count (const #t) %duration-cache) %duration-cache-limit)
    ;; Forgetting ONE arbitrary entry is enough to keep it bounded; the exact
    ;; policy is not worth a queue for a cache this small.
    (hash-remove! %duration-cache (car (hash-map->list (lambda (k v) k) %duration-cache)))))

;; THE METADATA FALLBACK, WHICH THE NOTE ABOVE USED TO SAY WAS IMPOSSIBLE.
;; `mpris:length' is in MICROSECONDS, so it is divided down to seconds like
;; every other MPRIS implementation.
(define (metadata-length p)
  "P's track length from `mpris:length' in the metadata, in seconds, or #f.

THE SOURCE THAT IS RIGHT WHEN `length' IS NOT: a track Astal has not synced yet
reports length -1 and position 0.0, while the metadata the player published with
the track already carries the real duration."
  (let ((micros (variant-double
                 (variant-lookup-value (player-ref p 'metadata) "mpris:length"))))
    (and micros (> micros 0) (/ micros 1000000.0))))

(define (metadata-position p)
  "P's position from the metadata, in seconds, or #f.

Some players publish `Position' only as a property and never deliver it in a
notify; the metadata is the second place to look.  #f when it is absent, which is
the normal case for Firefox."
  (let ((micros (variant-double
                 (variant-lookup-value (player-ref p 'metadata) "mpris:position"))))
    (and micros (>= micros 0) (/ micros 1000000.0))))

(define (player-length p)
  "P's track length in SECONDS, best effort.

FOUR SOURCES, in order, and the order is the point: the `length' property, the
per-track cache, `mpris:length' from the metadata, and 0.  A player that reports
`length' as 0 or -1 -- the case the fallback exists for -- gets its cached answer
or the metadata's, which is what makes a freshly-started track show 8:40 instead
of 0:00.

WHY -1 COUNTS AS MISSING, not just 0: AstalMpris sets `length = -1' when the
metadata carries no `mpris:length' at all (`lib/mpris/src/player.vala', `sync').
Both mean \"no length yet\" and both must fall through."
  (let ((reported (let ((l (player-ref p 'length)))
                    (and (number? l) (> l 0) l))))
    (if reported
        (begin (let ((track (player-ref p 'trackid)))
                 (when track (remember-duration! track reported)))
               reported)
        (let ((track (player-ref p 'trackid)))
          (or (and track (hash-ref %duration-cache track #f))
              (let ((from-metadata (metadata-length p)))
                (when (and from-metadata track)
                  (remember-duration! track from-metadata))
                from-metadata)
              0)))))

(define (player-position p)
  "P's position in seconds, or #f.

THE PROPERTY, THEN THE METADATA.  `position' is -1 from Astal when it is
unsupported, and 0.0 before the first poll has landed -- and 0.0 is
indistinguishable from \"genuinely at the start\", so the metadata is consulted
only when the property has not answered at all."
  (let ((pos (player-ref p 'position)))
    (if (and (number? pos) (>= pos 0))
        pos
        (metadata-position p))))

(define (player-progress p)
  "How far through the track, 0.0-1.0, for a progress bar."
  (let ((len (player-length p)) (pos (player-position p)))
    (if (and (number? len) (> len 0) (number? pos))
        (max 0.0 (min 1.0 (/ pos len)))
        0.0)))

(define (mpris-player-for-track)
  "The player the now-playing block is about, or #f."
  (mpris-active-player))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(define (player-toggle! p)
  "Play or pause.  #t when the call went out.

AstalMpris has `play-pause' as a method of its own, which is what a single
button wants -- `play' and `pause' separately would need the caller to know the
state, and the state is what it is trying to change."
  (and p (catch #t (lambda () (play-pause p) #t) (lambda args #f))))

(define (player-next! p)
  (and p (catch #t (lambda () (next p) #t) (lambda args #f))))

(define (player-previous! p)
  (and p (catch #t (lambda () (previous p) #t) (lambda args #f))))

(define (player-seek! p seconds)
  "Seek to SECONDS into the track."
  (and p (number? seconds)
       (catch #t (lambda () (slot-set! p 'position seconds) #t) (lambda args #f))))
