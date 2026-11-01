;;; (scheme-toolkit repl) -- this shell's wiring of the shared back door
;;;
;;; THE BACK DOOR ITSELF LIVES IN `(scheme-utils repl server)' NOW.  It was the
;;; same code in two projects -- this tree and schemacs -- so it moved to the tree
;;; they share, with everything specific to either one turned into a seam.  What
;;; is left here is this shell's settings.
;;;
;;; A running shell is controlled by evaluating Scheme in it.  That replaces
;;; AGS's four-verb D-Bus protocol: instead of `toggle-window', `quit',
;;; `inspect' and `request', the shell exports ordinary procedures and a
;;; keybinding says
;;;
;;;     scheme-toolkit eval '(toggle-window "launcher")'
;;;
;;; which is the same thing an editor, a test runner, or a person at a terminal
;;; does.
;;;
;;; THIS IS ARBITRARY CODE EXECUTION OVER A SOCKET, by design: it is the
;;; development and control back door.  The safety of it -- a Unix socket under
;;; $XDG_RUNTIME_DIR, per-user and 0700, refusing to start when that variable is
;;; unset, never TCP -- is enforced in the shared module, which documents the
;;; reasoning.  This file does not weaken any of it.
;;;
;;; WHY THE COOPERATIVE SERVER, and never `(system repl server)', is documented
;;; there too.  The short version: GTK is single-threaded, and Guile parameters
;;; are thread-local, so a REPL in its own thread would see the DEFAULT of the
;;; reactive core's current-scope -- an effect created from such a thread would
;;; have no scope and never be disposed.
;;;
;;; WHAT THIS FILE ADDS, and all it adds:
;;;
;;;   - the NAME, from SCHEME_TOOLKIT_INSTANCE, which the launcher sets from the
;;;     shell's directory name;
;;;   - the MODULE, (guile-user), which is where a shell exports its vocabulary
;;;     by importing it there;
;;;   - the WAKE, named out loud even though it is the shared default, because a
;;;     reader should not have to know that the default happens to suit us.
;;;
;;; AND TWO OLD NAMES, kept because callers and tests use them: a rename in
;;; three projects at once is churn nobody asked for, and `socket-directory' and
;;; `repl-socket-path' cost two lines to keep.

(define-module (scheme-toolkit repl)
  #:use-module (scheme-utils repl server)
  ;; RE-EXPORTED, not re-implemented.  Publishing them from here is what lets
  ;; the rest of the toolkit, the tools and the tests go on importing ONE module
  ;; -- the alternative is every caller learning that the back door moved, for no
  ;; benefit to any of them.
  #:re-export (start-repl!
               poll-repl!
               stop-repl!
               repl-running?
               repl-state! repl-restore!
               repl-name repl-name!
               repl-directory repl-directory!
               repl-directory-name repl-directory-name!
               repl-runtime-directory
               repl-create-directory?! repl-create-directory?
               repl-location repl-address repl-endpoint-path
               repl-socket-maker! repl-announce! repl-candidates
               repl-candidates! repl-cleanup!
               repl-module repl-module!
               repl-wake repl-wake!
               repl-welcome repl-welcome!
               repl-before-start! repl-after-poll!
               socket-alive? live-instances list-instances endpoints instance-of)
  ;; THIS SHELL'S OWN NAMES.
  #:export (repl-socket-path socket-directory))

;;; ---------------------------------------------------------------------------
;;; This shell's settings
;;; ---------------------------------------------------------------------------
;;
;; SET AT LOAD, not by the shell's `main'.  The back door is opened by
;; `(scheme-toolkit app)' during startup, and a shell that forgot to call a setup
;; function first would come up with the back door refusing to open -- a failure
;; that shows only when someone tries to connect.  Setting them here means
;; importing this module is the whole of what a shell has to do.

;; THE NAME COMES FROM THE ENVIRONMENT.  The launcher sets
;; SCHEME_TOOLKIT_INSTANCE from the shell's directory name, which is what makes
;; `scheme-toolkit eval -i scheme-desktop' and `scheme-toolkit list' agree with
;; each other: both read the same variable the same way.
;;
;; A THUNK RATHER THAN A VALUE, so the shared module can ask again -- and so the
;; error can name the variable and who sets it, which the shared module cannot
;; know.
;; THE DIRECTORY, AND IT MUST NOT CHANGE.  The shared module names its directory
;; after itself ("scheme-utils") unless told otherwise, and this shell's sockets
;; have always lived in $XDG_RUNTIME_DIR/scheme-toolkit/ -- which is where the
;; launcher computes paths and where `scheme-toolkit list' looks.  Left at the
;; default, every socket would quietly RELOCATE: the shell would keep working,
;; and every client would report "no running instances" while it sat there
;; running.  Nothing would error; that is the whole danger.
(repl-directory-name! "scheme-toolkit")

(repl-name!
 (lambda ()
   (let ((name (getenv "SCHEME_TOOLKIT_INSTANCE")))
     (unless (and name (not (string=? name "")))
       (error (string-append
               "scheme-toolkit: SCHEME_TOOLKIT_INSTANCE is unset.  "
               "bin/scheme-toolkit sets it from the shell's directory name.")))
     name)))

;; THE MODULE EXPRESSIONS ARE READ AND EVALUATED IN.  (guile-user) is where a
;; shell exports its vocabulary, and pinning it is what makes an expression mean
;; the same thing however deep in a signal handler the main thread happened to be
;; when the client's expression arrived.
(repl-module! '(guile-user))

;; THE WAKE.  GLib's idle source is the shared module's default, and this says so
;; out loud: it is the one host fact this shell supplies, and a reader should not
;; have to know that the default happens to suit us.
;;
;; The shell runs a GLib main loop, so `poll-repl!' is reached from an idle
;; source rather than from a timer -- which is the whole reason the vendored coop
;; server grew a `#:notify' hook.  Polling on a timer costs a measurable fraction
;; of a core at idle.
(repl-wake!
 (lambda (thunk)
   (let ((m (resolve-module '(g-golf hl-api glib))))
     ((module-ref m 'g-idle-add) thunk))))

;;; ---------------------------------------------------------------------------
;;; The two old names
;;; ---------------------------------------------------------------------------

(define (socket-directory)
  "The directory this shell's sockets live in."
  (repl-directory))

(define* (repl-socket-path #:optional (instance #f))
  "The socket path for INSTANCE, or for this shell's own instance."
  (repl-endpoint-path instance))
