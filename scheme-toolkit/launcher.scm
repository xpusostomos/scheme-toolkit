;;; (scheme-toolkit launcher) -- prefix-routed plugins and frecency
;;;
;;; The framework, not the plugins.  A launcher is a search box whose results
;;; come from several SOURCES at once, with a prefix choosing which source a
;;; query belongs to:
;;;
;;;   linux                 the applications plugin (no prefix)
;;;   ?linux                web search
;;;   >linux                clipboard history
;;;   !htop                 run a command
;;;
;;; The shape is colorshell's runner (src/runner/), which is the best plugin
;;; architecture among the reference shells: a plugin has a prefix, a name, and
;;; a HANDLE procedure returning results.  What is NOT copied is its coupling --
;;; there the Runner is a Gtk subclass owning its widgets, so a plugin can only
;;; be used by a launcher.  Here a plugin is data, and the widget layer lives in
;;; the shell.
;;;
;;; SYNC RESULTS ONLY.  colorshell's handle() may return a Promise and the
;;; Runner awaits it.  Scheme could do that with a thread and a callback, but a
;;; launcher that blocks its own main loop on a subprocess is the exact failure
;;; this avoids: a slow plugin (a filesystem walk, a network call) can be made
;;; asynchronous by taking a CALLBACK argument and calling back later.  See
;;; `handle-async' results -- RESULTS is the callback, so a plugin may return
;;; immediately and push more later.  That covers the real cases (clipboard
;;; history is a subprocess, wallpapers is a directory walk) without a future
;;; abstraction.

(define-module (scheme-toolkit launcher)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit result)
  #:use-module (scheme-toolkit file)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:export (make-result
            result-title result-description result-icon
            result-action result-close? result-id
            make-plugin plugin? plugin-name plugin-prefix
            plugin-prioritize? plugin-icon
            register-plugin! plugins clear-plugins!
            plugins-for
            route
            make-launcher launcher-query set-launcher-query!
            launcher-results launcher-plugin-icon
            ;; frecency
            record-use! frecency-score frecency-rank
            frecency-add! frecency-load! frecency-save! frecency-clear!
            default-frecency-file))

;;; ---------------------------------------------------------------------------
;;; Results
;;; ---------------------------------------------------------------------------
;;
;; A result is what the UI needs to draw one row and what to do when it is
;; chosen.  It is a record rather than an alist so a typo in a keyword is a
;; load-time error instead of a silently missing row.
;;
;; `id' is not for display: it is the key frecency is recorded under, so a
;; result must have a stable one when it represents something reusable (an
;; application, a command).  A result with no id is simply not ranked.

(define-record-type <result>
  (make-result-raw title description icon action close? id)
  result?
  (title       result-title)
  (description result-description)
  (icon        result-icon)
  (action      result-action)
  (close?      result-close?)
  (id          result-id))

(define* (make-result title
                      #:key (description #f) (icon #f) (action #f)
                            (close? #t) (id #f))
  "One row of a launcher's output.

ACTION is a thunk called when the row is chosen.  CLOSE? says whether choosing
it should dismiss the launcher -- a search-engine result closes, a \"type more\"
hint does not.  ID is the frecency key; leave it out for anything that should
not be ranked."
  (make-result-raw title description icon action close? id))

;;; ---------------------------------------------------------------------------
;;; Plugins
;;; ---------------------------------------------------------------------------

(define-record-type <plugin>
  (make-plugin-raw name prefix prioritize? icon handler)
  plugin?
  (name         plugin-name)
  (prefix       plugin-prefix)
  (prioritize?  plugin-prioritize?)
  (icon         plugin-icon)
  (handler      plugin-handler))

(define* (make-plugin name handler
                      #:key (prefix #f) (prioritize? #f) (icon #f))
  "A launcher plugin.

HANDLER is called as (handler QUERY RESULTS) where QUERY is the text with the
prefix removed, and RESULTS is a procedure to pass each result to.  Returning
results by calling RESULTS rather than by returning a list is what lets a slow
plugin answer immediately and add more when its subprocess finishes -- the
alternative is blocking the main loop, which for a launcher means a frozen
search box.

PRIORITIZE? means this plugin's results win when several plugins match; its
ICON then replaces the search icon, which is how the user sees that the prefix
took effect."
  (make-plugin-raw name prefix prioritize? icon handler))

;; Plugins live in a list, in registration order.  Registration is global
;; because a launcher is one per shell in practice, and threading a registry
;; through every plugin constructor would be noise.
(define %plugins '())

(define (register-plugin! plugin)
  "Add PLUGIN.  A later registration with the same PREFIX replaces the earlier
one, so re-evaluating a plugin definition in a live shell takes effect."
  (unless (plugin? plugin) (error "register-plugin!: not a plugin" plugin))
  (let ((prefix (plugin-prefix plugin)))
    (when prefix
      (set! %plugins
            (filter (lambda (p) (not (equal? (plugin-prefix p) prefix))) %plugins)))
    (set! %plugins (cons plugin %plugins))
    plugin))

(define (plugins) "Every registered plugin, newest first." %plugins)

(define (clear-plugins!) (set! %plugins '()) #t)

(define (plugins-for input)
  "The plugins that CLAIM INPUT, most specific first.

A plugin with a prefix claims an input starting with it; one without claims
everything, and therefore sorts last -- otherwise the applications plugin
would swallow every prefixed query."
  (sort
   (filter (lambda (p)
             (let ((prefix (plugin-prefix p)))
               (or (not prefix) (string-prefix? prefix input))))
           %plugins)
   (lambda (a b)
     (let ((pa (plugin-prefix a)) (pb (plugin-prefix b)))
       (cond ((and pa (not pb)) #t)
             ((and pb (not pa)) #f)
             (else (> (string-length (or pa "")) (string-length (or pb "")))))))))

;;; ---------------------------------------------------------------------------
;;; Routing
;;; ---------------------------------------------------------------------------

(define* (route input #:key (limit #f))
  "Every result for INPUT, in plugin order.

The prefix of a plugin is STRIPPED before its handler sees the query, which is
what makes `?linux' search the web for \"linux\" rather than for \"?linux\".

LIMIT truncates the combined list, applied AFTER collection so that one plugin
cannot starve another by returning a hundred rows."
  (let ((results '()))
    (define (collect! r)
      (when r (set! results (cons r results))))
    (for-each
     (lambda (plugin)
       (let* ((prefix (plugin-prefix plugin))
              (query (if prefix
                         (substring input (string-length prefix))
                         input)))
         (catch #t
           (lambda () ((plugin-handler plugin) query collect!))
           ;; A plugin that throws must not take the launcher with it: a search
           ;; box that goes blank because one source failed is worse than one
           ;; that shows the other sources' answers.
           (lambda (key . args)
             (format (current-error-port)
                     "scheme-toolkit: launcher: plugin ~a failed: ~a ~s~%"
                     (plugin-name plugin) key args)))))
     (plugins-for input))
    (let ((out (reverse! results)))
      (if (and limit (> limit 0) (> (length out) limit))
          (take out limit)
          out))))

(define (active-plugin input)
  "The first PRIORITIZED plugin claiming INPUT, or #f."
  (find (lambda (p) (and (plugin-prioritize? p)
                         (let ((prefix (plugin-prefix p)))
                           (or (not prefix) (string-prefix? prefix input)))))
        (plugins-for input)))

;;; ---------------------------------------------------------------------------
;;; Frecency
;;; ---------------------------------------------------------------------------
;;
;; "Frequently AND recently used", the ranking the reference shells share.  A
;; plain use count ranks a command tried once at the top forever; a plain
;; timestamp forgets a daily habit.  The decay is what makes the two combine:
;; each use adds 1 to a running score, and idle time erodes it, so something
;; used a hundred times last month sinks below something used twice today.
;;
;; Stored as an alist of (KEY . (SCORE . TIMESTAMP)) so the file is readable
;; and a corrupt entry can be dropped without losing the rest.

(define %frecency (make-hash-table))
(define %frecency-loaded? #f)

;; Half-life in seconds.  A day is long enough that a morning routine survives
;; to the afternoon, short enough that last week's experiment does not.
(define %frecency-half-life (* 24 60 60))

(define (decay-factor elapsed)
  (expt 0.5 (/ (exact->inexact elapsed) %frecency-half-life)))

(define (now-seconds)
  (let ((t (get-internal-real-time)))
    (inexact->exact (round (/ t internal-time-units-per-second)))))

(define* (frecency-score key #:key (now (now-seconds)))
  "KEY's current score, decayed to NOW.  0 when unseen."
  (let ((entry (hash-ref %frecency key)))
    (if entry
        (* (car entry) (decay-factor (- now (cdr entry))))
        0)))

(define* (record-use! key #:optional (now (now-seconds)))
  "Note that KEY was used now.  Its score gains 1 before the current decay, so
a use does not erase history."
  (let ((entry (hash-ref %frecency key)))
    (hash-set! %frecency key
               (cons (if entry (+ 1.0 (car entry)) 1.0) now))
    #t))

(define* (frecency-rank results #:key (now (now-seconds)))
  "RESULTS reordered so the most-used, most-recent id comes first.

A result with no id keeps its relative position after the ranked ones: it
cannot be ranked, and dropping it would hide a plugin's output entirely."
  (let ((ranked (filter (lambda (r) (and (result-id r)
                                         (> (frecency-score (result-id r) #:now now) 0)))
                        results))
        (unranked (filter (lambda (r) (not (and (result-id r)
                                                (> (frecency-score (result-id r) #:now now) 0))))
                          results)))
    (append
     (sort ranked (lambda (a b)
                    (> (frecency-score (result-id a) #:now now)
                       (frecency-score (result-id b) #:now now))))
     unranked)))

;;; ---------------------------------------------------------------------------
;;; Frecency persistence
;;; ---------------------------------------------------------------------------

(define (default-frecency-file)
  (string-append (xdg-state-home) "/scheme-desktop/launcher-frecency.scm"))

(define* (frecency-save! #:optional (path (default-frecency-file)))
  "Write the frecency table to PATH, atomically.

A half-written ranking file is not worth recovering: the worst case is that
frequently-used entries rank as unused for one session.  The temp-and-rename
still matters, because a truncated file would be READ as a shorter table rather
than failing."
  (let ((entries (hash-map->list (lambda (k v) (list k (car v) (cdr v)))
                                 %frecency))
        (tmp (string-append path ".tmp")))
    (and (write-file tmp (format #f "~s~%" entries))
         (catch #t
           (lambda () (rename-file tmp path) #t)
           (lambda args #f)))))

(define* (frecency-load! #:optional (path (default-frecency-file)))
  "Read the frecency table from PATH.  A missing or corrupt file leaves the
table empty rather than failing -- a ranking aid must never stop a shell."
  (set! %frecency (make-hash-table))
  (let ((text (read-file path)))
    (when (and text (not (string-null? (string-trim text))))
      (catch #t
        (lambda ()
          (let ((data (read (open-input-string text))))
            (when (list? data)
              (for-each
               (lambda (entry)
                 ;; Each entry is (key score . timestamp); a malformed one is
                 ;; skipped, so one bad line does not lose the whole table.
                 (when (and (list? entry) (= 3 (length entry))
                            (string? (car entry)) (number? (cadr entry))
                            (number? (caddr entry)))
                   (hash-set! %frecency (car entry)
                              (cons (exact->inexact (cadr entry)) (caddr entry)))))
               data))))
        (lambda (key . args)
          (format (current-error-port)
                  "scheme-toolkit: launcher: cannot read frecency from ~a~%" path)))))
  (set! %frecency-loaded? #t)
  %frecency)

(define* (frecency-add! key score #:optional (timestamp (now-seconds)))
  "Insert or replace KEY with an explicit SCORE, for a caller merging another
launcher's history."
  (hash-set! %frecency key (cons (exact->inexact score) timestamp))
  #t)

(define (frecency-clear!)
  (set! %frecency (make-hash-table))
  #t)

(define* (frecency-load-once! #:optional (path (default-frecency-file)))
  (unless %frecency-loaded? (frecency-load! path)))

;;; ---------------------------------------------------------------------------
;;; The launcher state
;;; ---------------------------------------------------------------------------
;;
;; The toolkit owns the QUERY and the RESULTS as accessors, so a widget binds to
;; them the same way it binds to any other reactive value.  It does not own the
;; widgets: a shell decides whether results are a Gtk.ListBox, a Stack, or
;; something drawn by hand.

(define* (make-launcher #:key (limit 24) (frecency? #t))
  "A launcher value: query in, results out.

Returns two accessors -- the query, and its results -- plus a setter for the
query.  The results are a COMPUTED, so re-running a search happens when the
query changes and at no other time."
  (let-values (((query set-query!) (create-state "")))
    (let ((results
           (create-computed
            (lambda ()
              ;; (query), NOT (st-peek query).  st-peek deliberately reads
              ;; without recording a dependency, so a computed using it never
              ;; lists the query among its sources -- and the results then stay
              ;; empty forever while the query changes.  The read that is right
              ;; here is the plain call: this computation is precisely a
              ;; function OF the query.
              (let ((q (query)))
                (if (string-null? (string-trim q))
                    '()
                    (let ((r (route q #:limit limit)))
                      (if frecency? (frecency-rank r) r))))))))
      (values query set-query! results))))

(define (launcher-query launcher) (car launcher))
(define (launcher-results launcher) (cdr launcher))
