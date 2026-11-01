# Known issues

## RESOLVED: `create-poll` bound to a widget property failed

**Was.** Binding a poll accessor to a widget property raised

    ERROR: In procedure string->pointer:
    Wrong type argument in position 1 (expecting string): #<<accessor> ...>

with a backtrace entirely inside G-Golf — no frame from this project, so the
failing call was a GI call receiving an accessor where a string was expected.

**Cause.** Importing a Gtk class silently REPLACED procedures in
`(scheme-toolkit reactive)`. G-Golf generates a generic named after each GI
method it imports, and it binds them into the module doing the importing. Two of
the reactive core's names collided:

| name | GI source |
|---|---|
| `peek` | `Gtk.Widget.peek`-style methods |
| `create-context` | Cairo/Gdk |

The failure shape is what made it hard to read. `accessor?` still returned `#t`
after the clobber — because G-Golf had also replaced the `<accessor>` CLASS, so
`is-a?` was comparing against the wrong class and answering for the wrong reason.
`(peek acc)` then dispatched into GI's `peek` generic and returned an accessor.

**It only appeared once a GtkApplication existed**, which is why every isolated
test passed: nothing imported a colliding class until `run-shell` created the
application and the widget imports took effect.

**Fix.** The reactive core's names that collide are now prefixed: `st-peek`,
`st-create-context`, and the class is `<st-accessor>` rather than `<accessor>`.

**The general rule, which is the part worth keeping:** a module that imports GI
classes cannot safely export a bare common name. Check before adding one:

```scheme
(use-modules (scheme-toolkit gi) (scheme-toolkit <yours>))
(is-a? <the-name> <generic>)   ; #t means GI took it
```

Known taken so far: `peek`, `create-context`, `start`, `stop`, `show`, `hide`,
`quit`, `present`, `accessor`. The toolkit uses `run-shell`, `quit-shell`,
`st-peek` and `<st-accessor>` for this reason.

## `#:namespace` on a layer window makes it invisible

**Symptom.** A window built with a custom layer-shell namespace — e.g.
`(layer-window "bar" #:namespace "scheme-desktop" ...)` — is constructed, is
registered, `present` returns without error, and **no surface ever appears**.
`hyprctl layers` shows nothing, and there is no diagnostic anywhere, because the
failure is on the compositor side: Hyprland keeps no layer surface for it.

Removing `#:namespace` and letting the default (`gtk4-layer-shell`) stand makes
the same window appear immediately.

**Status.** Not yet diagnosed past the symptom. `Astal.Window`'s `namespace`
property is settable after `gtk4_layer_shell_init`, which happens at
construction, so an ordering problem in Astal is plausible — but that is a guess.

**Workaround.** Do not pass `#:namespace`. `layer-window` still accepts it,
because it may work on other compositors or with different values, but the
desktop shell omits it and says why.

**Cost when it bit.** An hour, because the `present` call in `run-shell` was
wrapped in a `catch` that discarded the exception. That `catch` now reports, and
the general lesson is worth keeping: a swallowed exception at a lifecycle
boundary turns a ten-second diagnosis into a long one.

## The REPL back door has no socket wiring

`(scheme-toolkit repl coop-server)` and `(scheme-toolkit repl client)` are
vendored from schemacs and load, but nothing yet calls `start-repl!`:
`run-shell` resolves `(scheme-toolkit repl)` at run time and calls it if
present, and there is no such module yet.

The client still speaks schemacs's discovery protocol — a TCP port written to
`$XDG_RUNTIME_DIR/schemacs-repl-<pid>.port` — rather than the Unix socket named
by instance this project wants. `client.scm` needs `repl-port-files` and
`repl-connect` adapted to `.sock` files under `$XDG_RUNTIME_DIR/scheme-toolkit/`.


## Four bugs that a `catch` hid, found by grepping compiler warnings

`guild compile` warns "possibly unbound variable" for a name the module never
imports. Every module here loads fine without one, so the warnings were only
worth reading *because* four of them were real — and all four were silent,
because each sat inside a `catch` that turned "this name does not exist" into a
plausible-looking `#f`.

The check, which is now worth running after any change to a module's imports:

    for f in $(find scheme-toolkit -name '*.scm'); do
      GUILE_AUTO_COMPILE=0 guild compile -o /tmp/c.go -L . "$f"
    done 2>&1 | grep unbound

Ignore `for-each`, `map`, `connect`, `member`, `max` — G-Golf overrides those
deliberately (see the duplicate-binding handler in `gi.scm`).

| Name | Where | What it silently did |
|---|---|---|
| `g-unsetenv` | `app.scm` | Never ran. The binding is the bare `unsetenv`, and `LD_PRELOAD` was therefore **never cleared**, so every app the shell launched inherited the layer-shell preload — the exact failure the function exists to prevent |
| `get-string-all` | `process.scm` | `exec-async` read nothing from its pipe, so children were never drained and could block on a full pipe |
| `set-interactive-debugging` | `app.scm` | The inspector never opened. The binding is `gtk-window-set-interactive-debugging`; the wrong name raised inside the `catch`, which reported "cannot open the inspector" and made it look broken rather than misspelt |
| `wp-default` | DESKTOP `volume.scm` | The volume button's click handler raised on every click — muting from the bar never worked |

**Three lessons.**

1. **A `catch` around a name that might not exist converts a load-time error
   into a runtime no-op.** That is the right shape for an *external* failure
   (no audio server, no inspector) and the wrong shape for a misspelt import.
   The distinguishing question is whether the body can fail for a reason other
   than "the code is wrong" — if not, let it raise.
2. **`catch` should report what it caught.** Two of these four were invisible
   for exactly one reason: the handler returned `#f` and said nothing.
3. **Compile warnings are worth reading even when the program runs**, because a
   program that runs is not the same as a program that does its job.

A fourth, unrelated: DESKTOP's `volume.scm` used `<gtk-button>` without
importing it — it worked only because another module's import reached the same
module graph. `define-gi-imports` per module is the rule; the same grep catches
it.

## A double quote inside a stylesheet comment ends the string

**Was.** `(scheme-desktop style)` stopped compiling:

    WARNING: compilation of .../style.scm failed:
    Syntax error:
    source expression failed to match any pattern in form (define %network-css "\n/* ---- the wifi panel ...")

— naming `%network-css`, which had not been touched.

**Cause.** The block CSS in `style.scm` lives in **Scheme string literals**, and
a comment written inside one contained `"Audio"`. The quote ended the string, so
every line after it was read as Scheme, and the definition that happened to be
open when the parser gave up got the blame.

**The same trap as the docstring entry below** (`Unbound variable: it`), which is
why that one is worth reading twice: inside a string, `"` is a delimiter and
nothing else. Nothing is escaped in the CSS, so nothing warns.

**How to find it.** The compiler names a definition that looks untouched — that
is the tell. Then, for the string literal it names, print the lines that contain
a quote and are not the opening or closing one:

    python3 -c "
    lines = open('scheme-desktop/scheme-desktop/style.scm').read().split(chr(10))
    print([(i+1, l[:60]) for i, l in enumerate(lines[883:1621]) if chr(34) in l])"

**How to apply.** In a CSS comment inside these strings, do not use double
quotes. Backticks or nothing at all; both read fine.

## RESOLVED: an unbound name raised in a signal handler corrupts GObject's emission list

**Was.** `scheme-desktop`'s bluetooth panel killed the shell (SIGSEGV) every time
it was opened, sometimes immediately, sometimes a second later. The backtrace
named nothing in this project:

    #0 emission_find (signal_id=69, instance=…)
    #4 <emit signal 'changed' on [GtkAdjustment]>
    #6 gtk_viewport_size_allocate
    #8 gtk_scrolled_window_allocate_child (width=380)
    #30 gdk_frame_clock_run_layout

**Cause.** A procedure — `refresh-bluetooth-panel-later!` — was called in **six**
places and its definition had been lost in an edit. Every call raised
`Unbound variable`, and those calls were in signal handlers (`notify::visible` on
the panel's window, and the panel's own click/hover handlers).

**Why that is a crash and not an error.** Guile unwinds an exception by
longjmp'ing, and it does not care that the C frames in between are GTK's. Thrown
from inside `g_signal_emit`, it leaves a **dangling entry in GObject's
thread-local list of in-progress emissions**. The *next* emission of any signal —
here `GtkAdjustment::changed`, during the next layout pass — then walks that list
and dies in `emission_find`. So:

- the crash is in an **unrelated** signal, which is why no Scheme frame is on the
  stack and why the backtrace named nothing;
- it is unaffected by removing the panel's contents — the corruption had already
  happened at an earlier emission;
- it is **timing-dependent**: under valgrind's slower timing it stopped happening,
  which is a false negative, not a fix.

**It was in the logs.** Every crashing shell printed

    scheme-desktop/widgets/bluetooth.scm:190:23: warning: possibly unbound
    variable `refresh-bluetooth-panel-later!'

twelve times before the crash. The rule "always check the guile warnings" would
have found it in seconds; the crash behind the warning cost hours.

**How it was found.** `bin/scheme-desktop gdb` (see below), breaking on Guile's
exception throw and looking for `g_signal_emit` under it:

    set pagination off
    set confirm off
    set debuginfod enabled on
    set breakpoint pending on          # libguile loads with the program
    break scm_ithrow
    commands
      silent
      bt 18
      continue
    end
    run

A hit whose stack contains `g_signal_emit` **is** an error escaping a handler;
the `lookup_bound` frames above it name it as an unbound variable. (`-batch`
matters: without it gdb prompts about debuginfod and answers "No", and every
frame is then a bare library offset.)

**Two rules that follow.**

1. **An exception must never cross a C callback boundary.** `catch` around the
   body of anything called from C — signal handlers above all — turns this whole
   class into a log line instead of a corrupted process.
2. **When a GObject/GTK program segfaults with a stack that names no code of
   yours, suspect an exception thrown from a handler**, not the signal being
   emitted. Look for the *earlier* emission.

**`bin/scheme-toolkit check-unbound`** now compiles every module from source and
reports these names with file and line, ignoring the deliberate G-Golf overrides.
It exits non-zero when it finds one, so it can gate a change. It found a second
live instance the first time it ran: `tools/repl-cli.scm` used
`call-with-new-thread` with no `(ice-9 threads)` import, so the interactive
`scheme-toolkit repl` verb raised "Unbound variable" as soon as it started —
untested, because the suites drive `eval`, never the interactive path. See also
"Four bugs that a `catch` hid" above: same cause, milder symptom.

**Also fixed while there:** the repl client treated a *closed* stdin (piped input,
or Ctrl-D) as an error — `read-line` on a closed port raises rather than
answering the eof object — and the read loop at the other end did the same with
the socket the input thread had just closed. Both now end the session.

## Rebuilding a layer window: three things that silently produce nothing

A live config change that alters the shape of the tree needs the windows
rebuilt rather than patched in place. Each of the three steps below failed in
a way that logged nothing and left the registry looking healthy.

**1. `for-each-monitor` skips monitors that already have a root.** Correct for
a hotplug, wrong for a rebuild: the roots still exist, so every monitor counted
as already done and *nothing was built*. Hence `#:force?`, which disposes the
old root first.

**2. A rebuilt window is not presented.** `run-shell` presents on the
application's `activate`, which fires once. So the rebuild produced windows
that were registered, `visible` in the registry, and had **no surface at all**.
Presenting after a rebuild is the caller's job.

**3. Do not dispose the root while rebuilding.** Roots are per-*monitor*, not
per-window-name, and the new widgets register inside the same root. Disposing
it tears down the scope the replacement is about to use, so the fresh widgets
subscribe into a dead scope. `destroy-windows!` destroys the widgets and
leaves the root alone.

**One unrelated trap met while testing the above.** A `GtkApplication` holds
its `application-id` for its lifetime, so while an old shell process is alive a
new one prints "already running; use `scheme-toolkit eval'" and exits 0 —
which reads exactly like a crash on startup if you are watching the surface
count rather than the message. `scheme-toolkit list` distinguishes the two: no
listener plus surfaces on screen means a stale process, not a successful start.

## Three element-runtime bugs that only existed behind an earlier crash

`tests/element.scm` reported 19 passes and no failures for a long time. It was
actually **aborting** partway: `#:css` raised (a symbol where GTK wants a
numeric priority), so the last three test groups never ran. Fixing the raise
turned three failures on at once. The lesson is in the last section.

**1. `%deferred-props` held SYMBOLS, not classes.**

```scheme
(define %deferred-props
  '((<gtk-stack> . ("visible-child-name"))))   ; the symbol <gtk-stack>
```

A quoted `<gtk-stack>` is a symbol; `(class-of obj)` is a class OBJECT, so
`assoc-ref`/`assq-ref` never matched and `deferred-prop?` answered `#f` for
everything. Deferred properties were never deferred — `GtkStack`'s
`visible-child-name` went straight to `make`, was overwritten by the first
child added, and the stack showed page one plus

    Gtk-WARNING: Child name 'second' not found in GtkStack

The reason this survived review is cosmetic: a symbol and a class print
identically. The table is now a backquote with the classes unquoted.

**2. `<fragment>`'s `items` slot had no `#:init-keyword`.**

```scheme
(items #:init-form '() #:accessor fragment-items)   ; before
```

`(make <fragment> #:items items)` therefore **silently ignored** the keyword —
GOOPS accepts an unknown init keyword on a class and drops it — so every
fragment was empty and `(element <gtk-box> f)` added nothing. `#:init-value`
plus `#:init-keyword #:items` fixes it.

**3. A fragment's append observer updated a dead local.**

`element` collected children into a local `added` and copied it into
`%children` once, at the end. The observer runs later, so its `cons` grew a
list nobody would read again: the widget really was appended to the box, but
`%element-children` kept answering the old count. The local now publishes on
every change.

**The general lesson, which cost the most time here.** A test file that aborts
reports *no failure* for everything after the abort point — the same green as
success. Only the missing `test-end` line distinguishes them, and nobody reads
the tail of a passing run. Two defences, both cheap:

- check that the suite's own summary line appears (`test-end` prints
  `# of expected passes`), and treat its absence as a failure;
- make the runner count expected tests, so a group that silently stopped
  running changes the count.

The three bugs above were found in under an hour *once the tests actually
ran*; they had been sitting behind that one raise for days.

## `guile -e main -s FILE` passes main one argument

`(define (main) ...)` is the natural thing to write in an entry-point file and
fails at startup with

    In procedure main: Wrong number of arguments to #<procedure main ()>

after every module has loaded, which reads like a deeper problem than it is.
`guile` calls `main` with **one** argument: the script's command line as a list
of strings. The fix is `(define (main . args) ...)`.

## A WirePlumber property lags its own write by a DBus round trip

**Symptom.** Toggling mute twice in a row in the same event-loop turn returns
`(#t #t)`:

    (list (speaker-mute-toggle!) (speaker-mute-toggle!))   ; => (#t #t)

and the sink ends up muted, having never been unmuted.

**Cause, and why it is not a bug in `speaker-mute-toggle!`.** `AstalWp`'s
`mute` property is a *proxy* for state that lives in WirePlumber. Writing it
sends a DBus message; `get_mute` keeps answering the previous value until the
reply and the resulting `notify` come back. The second call therefore reads the
value from *before* the first call, decides "not muted", and mutes again.

Measured, with a 300 ms main-loop pump between the calls:

    before  #t
    toggle  -> #f
    after   #f        ; the round trip landed
    toggle  -> #t
    after   #t

**Why this does not affect the shell.** A click, a keybinding or a test step are
separate main-loop iterations, so the round trip lands between them. The failure
needs two toggles in one turn, which real input cannot produce.

**If a caller ever needs determinism** -- a script issuing several volume
commands in a row -- the answer is to wait for the `notify::mute` signal, or to
set an explicit state rather than toggling. Somebody adding an
`mute-set!`-style command should read this first.

## G-Golf's `define-class` is fussy about class options

Three things, all found while building `define-service`, two of which produce
errors that point at the wrong place.

**1. Slots must come before keyword options.** `class`'s parser
(`hl-api/gtype.scm`) reads slots until it meets the first keyword and then
requires keywords for the rest of the list. A keyword option written *before* a
slot makes it try to read the slots as keyword/value pairs. Worse, the failure
message shows only the *remaining* arguments, so it points at the slots -- which
are fine -- while the real problem is an option earlier in the list.

**2. Exactly one `#:g-signal`.** Two fail the same way. `install-signals` loops
over every `#:g-signal` it finds, so this is a parser limitation rather than a
design one. It is not order-dependent.

**3. `#:g-type-name` is silently ignored.** The GType name always derives from
the *class* name:

    (define-class <tn-test> (<gobject>) ... #:g-type-name "StTnTest")
    (g-type-name (!g-type (class-of (make <tn-test>))))   ; => "TnTest"

This matters because GLib rejects a type name shorter than three characters, so
a class named `<t1>` fails to define with "type name 'T1' is too short" -- a
message that never mentions `#:g-type-name`, which looked like it should have
overridden the name.

## A custom signal cannot be emitted from Scheme

G-Golf declares a signal for `#:g-signal` and generates **no emitter** for it.
There is no high-level emit: `g_signal_emit_by_name` is varargs and does not
bind, and `g-signal-emitv` needs a hand-built array of `GValue`s, which is
reachable but unfinished here.

`service-emit` was written, did not work, and was **removed** rather than shipped
failing.

Not a blocker: a widget binds to a *property*, and GObject supplies
`notify::` for a declared property with no help at all. A shell service in this
toolkit therefore exposes state as properties and only declares signals for
external code to subscribe to.

## Writing a double quote inside a docstring

Twice now, and it is worth its own entry because the error points at the wrong
place:

    (define (first-player players)
      "Whichever player MPRIS lists first is the one to show, rather than
    tracking an "active" player."
      ...)

The `"active"` **ends the string**. Everything after it is read as code, so the
definition acquires stray identifiers and the failure is

    media.scm:32:34: In procedure media-widget: Unbound variable: active

-- naming a variable that appears nowhere as a variable. The same thing bit
`run-shell`'s docstring earlier, in a different file.

Avoid a bare `"` in a docstring. Rephrase, or use `\"`.

## "No applicable method" usually means the wrong ARITY

**This one cost hours, chasing a bug that did not exist.** `GFile.monitor_file`
kept answering

    No applicable method for #<<generic> monitor-file (2)> in call (...)

and the conclusion drawn was that G-Golf fails to dispatch methods bound from a
typelib. That was wrong: the method takes **three** arguments — `(file flags
cancellable)` — and it was being called with two. GOOPS was right every time.

The inspection that would have shown it in seconds:

    (for-each (lambda (m) (say "~s" (method-specializers m)))
              (generic-function-methods monitor-file))
    ;; => (<g-file> <top> <boolean>)
    ;;    (<g-file> <top> <g-cancellable>)

Three specializers, therefore three arguments. `generic-function-arity` is not
exported by this GOOPS, so count the specializers instead.

**Lessons, in the order they would have helped:**

1. When GOOPS says "No applicable method", first check the argument COUNT
   against the method's specializers. It is by far the most common cause.
2. Two arguments "not matching" is a strong hint that a third exists — the
   generic's own name prints its arity, as `monitor-file (2)` did above, and
   that `(2)` was the generic's class count, not the method's.
3. The workarounds this wrong diagnosis produced (FFI via `dynamic-link`, a
   private module to alias the name, a raw-pointer monitor) all "worked" far
   enough to look like progress, which is what made the mistake durable. If a
   workaround is needed for a *library* bug, verify the library is actually
   broken before building around it.

The one real problem in that area is a NAME COLLISION, not dispatch: Gio binds
`monitor-file` on GFile and `(scheme-toolkit file)` exports `monitor-file`, so
importing both makes the wrapper call itself. Gio's is imported into a private
module and fetched from there.

## FIXED: "New application windows must be added after GApplication::startup"

**Status: fixed 2026-10-28. The note below was wrong about the cause, and right
to refuse to guess.**

The critical is NOT produced by a shell's first start, and it is not about the
ordering of widget construction. It is produced by a **second** launch of the
same instance, and the reason it got that far is a bug in `run-shell`:

    (when (catch #t (lambda () (register %app)) (lambda args #f))
      ... "already running" ... (exit 0))

`register` is a GOOPS generic. It has no method for `<gtk-application>`, so the
call raised `No applicable method for register` on every single start -- and the
`catch` around it turned that into `#f`, which is the same value as "not
already running". **The guard had never once fired.** A second launch therefore
went on to build a full set of windows for an application that is not the
primary owner; a remote instance never receives `startup`, so GTK rejected each
window it added:

    Gtk-CRITICAL: New application windows must be added after the
    GApplication::startup signal has been emitted.

**The fix** is `g-application-register`, checked for the remote case:

    (let ((registered? (catch #t (lambda () (g-application-register %app #f)) ...)))
      (unless registered? ... (exit 1))
      (when (g-application-get-is-remote %app)
        ... "already running" ... (exit 0)))
A second launch now prints `scheme-desktop is already running; use
scheme-toolkit eval to talk to it` and exits before building anything, and the
criticals are gone.

**The lesson, and it is the same one three times over on this project:** a
`catch` that returns `#f` cannot tell "the call said no" from "the call blew
up", and here it hid a guard that had never worked. Every `catch` added to
silence a warning has to be re-read as a possible mask for a real error.

**Two symptoms went with it.** The same duplicate-instance runs also printed
twelve `on-cleanup called outside a scope; it will never run` warnings -- a
shell building widgets for a GtkApplication that is not the primary owner is
building them where the scope machinery had not been set up. Both are gone: four
start/toggle cycles after the fix are clean.

A third symptom was a hard exit:

    srfi/srfi-1.scm:236:2: In procedure map:
    In procedure map: Wrong type argument: 0

**It was the tray, and it is fixed -- see the next entry.** The eleven
`on-cleanup` warnings and this exit came from the same place, and pinning the
first one down pinned both.

## "overrides core binding" warnings: measured, and they are benign

Startup prints a wall of these:

    WARNING: (scheme-toolkit astal): imported module (scheme-toolkit gi)
             overrides core binding `connect'
    WARNING: (scheme-toolkit reactive): imported module (scheme-toolkit gi)
             overrides core binding `map'

They are worth taking seriously -- a core binding really is being replaced --
so the behaviour was tested rather than reasoned about.  The short answer: the
procedures keep working on ordinary data, because the handler is
`merge-generics`, which MERGES rather than replaces.

**What actually happens.**  `gi.scm` installs

    (default-duplicate-binding-handler
      '(merge-generics replace warn-override-core warn last))

With `merge-generics`, when an import provides a binding whose name is already
bound to a generic, the two are merged into ONE generic carrying both sets of
methods.  So after importing Gtk:

    map      => <generic>, one method, specializer (<gtk-widget>)
    connect  => <generic>, two methods, (<g-cancellable> ...) and
                (<gtype-instance> <top>)

Both are still callable on plain Scheme data, verified:

    (map 1+ '(1 2 3))              => (2 3 4)
    (map + '(1 2) '(10 20))        => (11 22)     ; still variadic
    (for-each ... '(1 2 3))        => works
    (member 2 '(1 2 3))            => (2 3)
    (append '(1) '(2))             => (1 2)
    (assoc "b" ...)                => ("b" . 2)

Nothing in the tree lost behaviour.  If `merge-generics` were absent and the
handler were `replace`, `map` would become a one-method generic that only
accepts a `<gtk-widget>` -- and every `(map f list)` in the codebase would fail.
The handler is load-bearing in exactly this way, which is why `gi.scm` sets it
*before* `(use-modules (g-golf))` and explains why in a comment.

**One thing that did NOT regress, contrary to a claim made while investigating.**
GOOPS slot observers are `(add-observer! slot object proc)`, and they are not
available in this Guile's `(oop goops)` at all (`add-observer!` is unbound with
or without G-Golf).  The plain `connect` is Guile's SOCKET connect -- it takes a
file descriptor, and G-Golf does not change that:

    (connect s AF_UNIX path)            => works, on a real listening socket
    (connect some-slot proc)            => wrong-type-arg (expecting open file
                                           port), both with and without G-Golf

So `connect` was never the GOOPS observer procedure here, and the GI generic
adds GObject signal connections alongside the socket one rather than displacing
it.  Checked because the first reading of the warnings suggested a regression
that does not exist.

**What the warnings ARE good for.** They are a reliable index of which names
G-Golf takes, which is the trap recorded earlier in this file: a module that
exports a bare common name can have it silently replaced by a GI generic.  The
list currently includes `map`, `for-each`, `member`, `max`, `append`, `connect`,
`assoc`, `read`, `peek`, `start`, `stop`, `show`, `hide`, `quit`, `present`.
The toolkit's answer is to prefix its own colliding exports
(`st-peek`, `run-shell`, `quit-shell`, `<st-accessor>`).

If the noise is unwanted it can be silenced with
`(default-duplicate-binding-handler '(merge-generics replace last))` -- dropping
`warn-override-core` -- but that removes the index, and the warning has already
earned its place twice.

## The warning wall, triaged: which ones to ignore and which not to

Startup prints a dozen `overrides core binding` warnings.  They are NOT all the
same thing, and "ignore them" is only right for most.  Measured:

| warning | verdict |
|---|---|
| `map`, `for-each`, `member`, `max`, `append`, `assoc`, `read`, `unsetenv` | **benign.** Merged, not replaced -- see the section below. Verified: `(map 1+ '(1 2 3))` => `(2 3 4)`, `(for-each ...)` over a list works, `(read port)` still parses, `(assoc ...)` still works |
| `connect`, `quit`, `present`, `show`, `hide`, `start`, `stop` | **benign but worth knowing**: these become generics carrying BOTH the Guile/GOOPS method and the GI ones. This is why the toolkit exports `run-shell`/`quit-shell` rather than `start`/`quit` |
| `` `monitor-file' imported from both (scheme-toolkit gi) and (scheme-toolkit file) `` | **NOT benign -- a real collision**, see below |

### The `monitor-file` collision, and why it is order-dependent

`(scheme-toolkit file)` exports a wrapper `monitor-file` taking `(path proc)`.
Importing Gtk ALSO brings Gio's `GFile.monitor_file` under the same name, and
afterwards the generic has ONLY Gio's methods:

    (generic-function-methods monitor-file)
    ;; => ((<g-file> <top> <boolean>) (<g-file> <top> <g-cancellable>))

Calling it the way `file.scm` documents then fails:

    (monitor-file "/tmp/x" (lambda (kind path) ...))
    ;; No applicable method for #<<generic> monitor-file (2)> ...

**`(scheme-toolkit config)` survives this by IMPORT ORDER** -- it lists
`(scheme-toolkit gi)` before `(scheme-toolkit file)`, so `file`'s binding wins
and live config reload works. That is luck, not design: reverse the two lines
and the config stops reloading with an error that names a generic and an arity
rather than the collision.

**The fix for a caller that hits it** is to qualify the import:

    #:use-module ((scheme-toolkit file) #:prefix file:)
    (file:monitor-file path proc)

or to reference the module directly. `file.scm` already does exactly this for
Gio's side (it imports Gio's into a private `(scheme-toolkit file gio)` module),
so the two can coexist in one module -- but only if the caller asks for one of
them by a qualified name.

**Not yet changed.** `config.scm` works today and changing its import to a
prefix would be a real fix rather than a cosmetic one; it is recorded here so
the next reader does not rediscover it as a mystery.

### Why "merged, not replaced" is the whole story for the benign ones

`gi.scm` installs, before `(use-modules (g-golf))`:

    (default-duplicate-binding-handler
      '(merge-generics replace warn-override-core warn last))

With `merge-generics`, two same-named generics are merged into ONE carrying both
sets of methods.  That is why `map` still maps over lists after Gtk is imported.
With `replace` instead, `map` would become a one-method generic accepting only a
`<gtk-widget>`, and every `(map f list)` in the tree would break -- so the
handler is load-bearing, not decoration.

**Conclusion: the warning wall is safe to ignore in general, with two caveats.**
It is also the index of which names G-Golf takes, which is the trap that
motivated prefixing the toolkit's own exports (`st-peek`, `run-shell`,
`<st-accessor>`); and a `from both` line -- as opposed to an `overrides core
binding` line -- is worth reading, because that is a genuine name collision
rather than a merge.

## A stylesheet attached to a widget styles ONLY that widget (GTK4)

**The most expensive trap in this project so far, and it looks like nothing at
all.** A shell applies its stylesheet to each window:

    (add-provider (get-style-context window) provider 800)

The stylesheet parses with zero errors. `parsing-error` never fires. The
provider is held and referenced. `shell-css` returns the exact text intended.
And **nothing changes**, because in GTK4 that call styles the widget it is given
and is NOT inherited by its children:

    gtk_style_context_add_provider               styles THAT WIDGET only
    gtk_style_context_add_provider_for_display   styles every widget under it

GTK3 inherited a widget-attached provider, which is why the wrong call is the
natural one to write and why every tutorial-shaped instinct points at it. On a
toplevel the visible effect is that the window's own background changes and
every button, label and image inside keeps the theme's styling -- so a bar looks
*almost* styled, and the parts that are wrong look like CSS specificity bugs.

It cost an afternoon of chasing the wrong hypothesis. The symptoms all pointed
at the CSS because the CSS was the only thing being examined:

    tray icons had a rounded box      -> Adwaita's button background, untouched,
                                          because `all: unset' never reached them
    hover was a squircle              -> same, `box-shadow: none' never applied
    a garish probe colour changed
      nothing at all                  -> the probe never reached the widget either

**The fix is one call, and the trap is its NAME.** `add_provider_for_display` is
a namespace FUNCTION, and G-Golf names those after the full C identifier with
the prefix kept:

    (defined? 'add-provider-for-display)                      ; => #f
    (defined? 'gtk-style-context-add-provider-for-display)     ; => #t

while METHODS get the short name (`add-provider`). So looking for the name you
expect finds nothing, and the obvious conclusion -- the one drawn here at first
-- is that G-Golf skipped it for being deprecated. It did not skip it; it is
present under its long name. This is the same quirk as
`gtk-window-set-interactive-debugging` recorded above, and the general rule is
worth stating once:

> A G-Golf binding may be named after the full C identifier with its prefix
> intact, even when a neighbouring method of the same class gets the short name.
> Before concluding that a function is unavailable, check for the prefixed
> spelling.

`(scheme-toolkit style)` now provides `apply-provider-for-display!`, and
`apply-provider!` says plainly that it styles one widget -- which is exactly
what the per-widget `#:css` prop wants.

**How to check which of the two you have**, without a screenshot: add a rule with
an unmistakable colour to a class on a DESCENDANT and read it back.

    (gtk-widget-get-color child)   ; (1.0 0.0 0.0 1.0) if the rule reached it

## A tray menu: four separate traps, all producing "the menu is empty"

Every one of these presented identically -- a popover with nothing in it -- and
each had to be found separately. The list is worth keeping because the symptom
never narrows down which one it is.

**1. `GtkMenuButton` has no `activate` signal.** A handler connected to it never
runs, so "refresh the menu when the button is clicked" silently does nothing.
`GtkMenuButton` is not a `GtkButton`. Use a plain `Gtk.Button` (which emits
`clicked`) with a `Gtk.Popover` parented to it -- which is what ags2-shell does.

**2. `Gtk.PopoverMenu` cannot render a `Gio.DBusMenuModel`.** Measured: after
`AboutToShow` the model reports 8 items, the attributes read back correctly
("Open Syncthing", "Settings", ...), and the popover still shows nothing. The
model is fine; the widget cannot draw it. ags2-shell does not use PopoverMenu
for tray menus either -- it walks the model and builds buttons by hand.

**3. `get-item-attribute-value` silently answers `#f` without a GVariantType.**

    (get-item-attribute-value MODEL INDEX ATTRIBUTE VARIANT-TYPE)

Passing `#f`, or the string `"s"`, returns `#f` for **every** item while real
menu items are present. The natural reading is "the model has no labels", which
sends the search to the model rather than the call. It must be a real type:
`(g-variant-type-new "s")`, which G-Golf returns as a `<foreign>` -- that
`<foreign>` is correct and works. The result is a `GVariant` pointer, read with
`g-variant-get-string`.

**4. `AboutToShow` populates the model, and not every application implements it.**
DBusMenu menus are lazy: before the host asks, the model holds placeholder rows
with no labels and no actions. Measured on Syncthing: 2 empty rows, then 8 real
ones immediately after `AboutToShow`. Measured across five items on this
machine: Syncthing and Insync implement it, JetBrains Toolbox and Chromium-style
items do not (`UnknownMethod`). So the call is best-effort and must not stop the
menu appearing.

Two more things that are easy to get wrong once the walk works:

- **A `Gio.DBusMenuModel` is a WRAPPER** -- one item whose *section* holds the
  real menu. A walk that does not unwrap it renders a single row which opens the
  menu, rather than the menu. `get-item-link model 0 "section"` is the unwrap.
- **Bound the recursion.** A model that links to itself spins forever.

**And a testing lesson.** The first version of the verification helper walked
only DIRECT children and reported an empty menu that had in fact been built --
the labels sit at `button > box > label`. A test asserting on the *model* would
have passed throughout all four bugs above, because the model was always
correct. `tray-item-menu-labels` therefore builds the same box the popover gets
and reports what a user would SEE.

## OPEN: a GTK setter used as a value returns ZERO values

`Gtk` setters are void C methods, so through G-Golf they return **zero values**.
Using one where a value is expected raises

    Zero values returned to single-valued continuation

for the *enclosing* form, which names no widget, no property and no line.  Three
of these were hit in `(scheme-toolkit tray)`:

    (when known (set-sensitive button #t))       ; raises
    (when box (set-child popover box))           ; raises
    (when tt (set-tooltip-text button tt))       ; raises

    (when known (set-sensitive button #t) #t)    ; sequenced -- fine

A call in STATEMENT position is fine, because the value is discarded.  Only a
value-requiring context (`when`, `if`, `not`, `and`, `or`, a `let` binding) is a
problem -- which is why `(gtk-widget-add-css-class w "x")` on its own line never
bit anyone.

**The tell is that the error carries no location.**  If a message says
"Zero values returned to single-valued continuation" and names nothing, look for
a `set-*`/`add-*`/`append` GTK call in a conditional.

The same shape as `gtk-window-set-interactive-debugging` elsewhere in this file:
a void C call reached from Scheme where a value is expected.

## OPEN: Gio.DBusMenuModel drops items from a tray menu

**Measured against Syncthing's own menu.** The application publishes eleven
nodes on `com.canonical.dbusmenu`:

    Open Syncthing, Settings, Rescan all, Log,
    Show internal errors, Show notifications/errors,
    Connection -> (Primary instance), About,
    ───── separator ─────
    Close

Read straight off D-Bus:

    gdbus call --session --dest :1.6681 --object-path /MenuBar \
      --method com.canonical.dbusmenu.GetLayout 0 5 "[]"
    # 10 labels (Primary instance is a child of Connection), 1 separator

`Gio.DBusMenuModel` -- the model AstalTray hands out as `menu-model`, and the
one every tray host reads -- reports **8 items and no separator**:

    (get-n-items (item-menu-model item))   ; => 8
    (menu-item-section model 0)            ; => #f -- no section link at all

So `Close` and the dividing rule **never reach the widget builder**. They are
not filtered out by this toolkit: they are absent from the model.

**Why it matters.** ags2-shell builds its menus from the same Gio model, so a
correctly-ported builder still cannot draw those two nodes. This is a limit of
the Gio model, not of the port -- which is worth knowing before spending more
time on the builder.

**The route that would work**, if this matters: read the menu over D-Bus
directly with `GetLayout` and walk the returned tree, rather than going through
`gio.DBusMenuModel`. That is what the `gdbus` call above does, and it is the
only way to see the whole menu. It is a real piece of work -- a variant walker
for `(ia{sv}av)` -- and it belongs in `(scheme-toolkit dbus)`, not in the tray.

**Not yet done.** Recorded so the next reader does not re-derive it from a
screenshot comparison.


**CORRECTION (2026-10-27).** The paragraph above is WRONG and was written from a
misdiagnosis. `Gio.DBusMenuModel` does not drop `Close` or the separator, and
ags2-shell was never reading a different model.

The bug was in this toolkit's own `item-menu-model`, which UNWRAPPED item 0 of
the model before returning it. The model's top level is a list of SECTIONS:

    raw model n_items = 2
      0: no label, SECTION -> the eight rows (Open .. About)
      1: no label, SECTION -> the separator and Close

Returning item 0 threw away item 1 -- the separator and Close -- before any
widget code saw it. Returning the model EXACTLY AS PUBLISHED fixes it, and the
hand-built menu now draws 0-7 buttons, a separator, and Close, matching the
`GetLayout` dump above node for node.

The lesson worth keeping: `get-n-items` on a DBusMenuModel counts SECTIONS at
the top level, not rows, so "the model has 8 items" was a true statement about
the wrong level of the tree.

---

## AstalHyprland emits JSON-GLib CRITICALs on every monitor sync

**Symptom.** Two CRITICALs per monitor, several times a second, from any process
that so much as calls `Hyprland.get_default()`:

    (guile:1283170): Json-CRITICAL **: json_node_get_int: assertion
    'JSON_NODE_IS_VALID (node)' failed
    (guile:1283170): Json-CRITICAL **: json_object_get_int_member: assertion
    'node != NULL' failed

**Cause, and it is upstream.** `lib/hyprland/src/monitor.vala:65-66`:

    active_workspace = hyprland.get_workspace((int)obj.get_object_member("activeWorkspace").get_int_member("id"));
    special_workspace = hyprland.get_workspace((int)obj.get_object_member("specialWorkspace").get_int_member("id"));

Hyprland reports `specialWorkspace` as an EMPTY OBJECT (`{}`) on a monitor that
has no special workspace. `get_int_member("id")` on an empty object yields a
NULL node, and JSON-GLib warns twice for each. `sync_monitors` runs on every
`workspacev2`, `focusedmon` and `monitoradded` event, so it is not once at
startup.

`lib/hyprland/src/client.vala:54` has the same shape for a client on a special
workspace (`get_object_member("workspace")`).

**What this toolkit does about it: nothing, deliberately.** It is not reachable
from Scheme -- the parse happens inside AstalHyprland's own event loop, and it
fires from merely constructing the singleton, before any of our code runs. The
per-second repetition needs a Hyprland event to trigger it, so a still desktop
is quiet.

**The route that would remove it** is D3's `AstalWorkspace`
(ext-workspace-v1), which the plan already calls for: workspaces come from
`AstalWorkspace` and `AstalHyprland` is kept only for clients and dispatch --
both of which are still JSON-parsed, so the criticals only disappear if the
shell stops constructing `AstalHyprland` at all.

**Not ours, and not fixable here.** Recorded so it is not re-diagnosed.


---

## FIXED: the tray connected its item signals with no reactive scope

**Symptom.** Eleven `scheme-toolkit: on-cleanup called outside a scope; it will
never run` warnings on an ordinary single-instance start -- sometimes zero,
sometimes eleven, depending on how many StatusNotifier items had arrived by the
time the handler ran. Once, a hard exit.

**Found by printing the frames**, since Guile's own backtrace printer dies on
the G-Golf frame:

    ###   2 scheme-toolkit/reactive.scm 393   <- on-cleanup
    ###   3 scheme-toolkit/widget.scm   467   <- connect-signal!
    ###   4 scheme-toolkit/tray.scm     609   <- connect-signal! button "clicked"
    ###   5 scheme-toolkit/tray.scm     706   <- (tray-menu-button item ...)
    ###   6 srfi/srfi-1.scm             749   <- for-each
    ###   7 scheme-toolkit/tray.scm     701   <- update-tray!'s for-each
    ###   9 g-golf/hl-api/closure.scm   269   <- A C CALLBACK
    ###  11 g-golf/hl-api/function.scm   90

**Cause.** `tray-widget` rebuilds its item buttons from the `items-changed`
signal. That signal is emitted by C, and a Guile **parameter is not in scope
inside a C callback** -- `(%scope)' is `#f` there, whatever the shell's dynamic
state was. So every `connect-signal!' the rebuild made warned, and then kept its
handler for the life of the process: one leaked handler per item per event.

**Fix.** Each rebuild runs inside its own `create-root', and the previous one is
disposed first:

    (let ((dispose-items #f))
      (define (rebuild-items!)
        (when dispose-items (dispose-items))
        (set! dispose-items
              (create-root (lambda (_) (update-tray! box ...)))))
      ...)

`create-root' is what puts a scope back; disposing the previous root is the
other half, or the handlers of every superseded button survive the rebuild that
replaced them.

**The general lesson, and it applies to every widget that reacts to a C signal:
"the code that runs later" is not the same dynamic context as "the code that was
built".** Anything a signal handler constructs -- widgets, bindings,
connections -- needs a root of its own, because `%scope' cannot survive a trip
through C.

**The same bug was in DESKTOP's workspaces pills**, and it was found second only
because the tray announces itself. `widgets/bar/workspaces.scm` rebuilds its
pills from `subscribe` on the workspace accessors, which AstalHyprland notifies
from its `event` signal -- also emitted by C. Six pills, six warnings, every
time the focused workspace changed. Fixed the same way: each rebuild gets a root
and the previous one is disposed.

What made it hard to see: **a shell that is merely started produces no warnings
at all.** Both bugs need an external event -- a StatusNotifier item arriving, a
workspace being switched -- so a start-and-screenshot test never fails. Every
widget that rebuilds itself from a signal needs to be exercised by actually
causing the signal.

M8's notification popups, created on the fly from D-Bus, will be the next place
this shape appears.

**The exit had the same shape.** `for-each' raised `Wrong type argument: 0' on
the tray rebuild path. Guile named the caller (`map') rather than the procedure
that failed (`srfi-1.scm:749' is `for-each'), which is why the error read as
something else entirely. Both symptoms stopped when the scope was restored.


---

## FIXED: "In procedure map: Wrong type argument: 0" -- a G-Golf bitfield passed as 0

**Symptom.** Clicking inside the date menu killed the shell:

    srfi/srfi-1.scm:236:2: In procedure map:
    In procedure map: Wrong type argument: 0

The message names `map`, which is nowhere in the failing code, and `srfi-1.scm:236`
is `wrong-type-arg` -- so even the line number is the error *reporter*, not the
error. Guile's backtrace printer dies at the G-Golf frame, so the stack was no
help either.

**Cause, found by bisecting the handler rather than the symptom.** The popup
window's click-outside gesture calls

    (gtk-widget-pick win x y 0)

**G-Golf passes a C bitfield as a LIST of symbols, not as an integer.** `0` is
not "no flags" to it; it is a non-list, and G-Golf walks the flag list to build
the C value with a `map`. `'()` is "no flags" and works.

    (gtk-widget-pick w 995.0 173.0 0)     ; => Wrong type argument: 0
    (gtk-widget-pick w 995.0 173.0 '())    ; => #<gtk-image>

A bare symbol fails the same way (`(non-targetable)` is a list, but G-Golf
wanted it wrapped) -- only a list is accepted.

**The reliable repro was clicking the calendar's month arrows**, because the
gesture is on the POPUP and therefore fires for any click inside it. That is
also why it looked like a calendar bug.

**Rule for this toolkit: every `GtkPickFlags`, `Gtk*Flags` and bitfield parameter
is a LIST.** Passing an integer for one produces a `map` error that names neither
the call nor the file.

**How it was finally pinned.** No mouse-synthesis tool exists on this machine
(`ydotool`/`dotool` are absent, `wtype` is keyboard-only), so the gesture was
driven directly: `popup-window` temporarily stashed its gesture controller and
window in module variables, and `(emit g "pressed" 1 x y)` reproduced the crash
exactly. The coordinates came from `gtk-widget-compute-bounds` on the arrow
button. Worth repeating -- for a widget that only misbehaves on a click, emitting
the signal is faster and more precise than any amount of reading.

---

## A dock must not take a positive exclusive zone, or every top bar shortens

**Symptom.** A bar anchored `top left right` starts 55px in from the left edge
instead of at it, and stops short of the right, on a screen where nothing else
is wrong. Measured on this machine while `ags2-shell` was also running:

    eDP-1 (1920 wide):  reserved=[55, 114, 0, 0]      # [left, top, right, bottom]
    our bar:            xywh: 55 81 1865 33

The 55 is `ags2-shell`'s dock: `xywh: 0 48 55 1032`, a left strip with an
exclusive zone.

**It is not a bug in the bar, and there is no bar setting that fixes it.** The
layer-shell protocol has ONE knob, `exclusive_zone`, and it means different
things per value -- there is no way to say "reserve my strip *and* ignore
everybody else's":

    > If set to zero, the surface indicates that it would like to be moved to
    > avoid occluding surfaces with a positive exclusive zone.  If set to -1,
    > the surface indicates that it would not like to be moved to accommodate
    > for other surfaces, and the compositor should extend it all the way to the
    > edges it is anchored to.

So a surface that reserves its strip is, by the same declaration, asking to be
moved to avoid other reserved strips. Every combination was measured:

| setting | x | y | width | reserves | verdict |
|---|---|---|---|---|---|
| `exclusive`, anchor `top left right` | 55 | 81 | 1865 | 33 | inset, correct otherwise |
| `ignore` (zone -1) | 0 | **0** | 1920 | 0 | full width, but ALSO stops avoiding -- lands on top of the other bars |
| `exclusive`, anchor `top` alone + explicit width | **28** | 81 | 1920 | 33 | Hyprland centres on the *usable* area (1865), so a 1920 surface hangs off the right |
| `ignore` + `margin-top 81` | 0 | 81 | 1920 | 0 | full width and stacked -- but reserves nothing, so **maximised windows slide under the bar**. Reported as a worse failure than the inset, and reverted |

**The fix belongs in the DOCK, and it is one word.** Astal maps `Exclusivity` to
`exclusive_zone` directly (`lib/astal/gtk4/src/widget/window.vala`):

    case Exclusivity.NORMAL:     set_exclusive_zone(this, 0);        // avoid others, reserve nothing
    case Exclusivity.EXCLUSIVE:  auto_exclusive_zone_enable(this);   // reserve the surface's extent
    case Exclusivity.IGNORE:     set_exclusive_zone(this, -1);       // neither

Quickshell -- which is *not* affected on the same desktop -- does exactly this
in its own source, with the reasoning in a comment:

    // DockWindow.qml -- the dock
    // Kept clear of the bar's reserved edge, without reserving one of its own:
    // floating windows go where they are put.
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0

    // Bar.qml -- the bar
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: thickness

The dock reserves nothing, so no edge is shortened and the bar spans the screen
as an ordinary top bar. Quickshell's bar is not doing anything special; its dock
is.

**`ags2-shell` does the opposite** (`widget/Dock/index.tsx:200`):

    exclusivity={createComputed(() => active() && is_static() ? EXCLUSIVE : IGNORE)}

In static mode its dock reserves a left strip, and its own top bar -- anchored
`left right`, so asking to avoid zones -- dutifully shortens itself by its own
dock. Changing that one `EXCLUSIVE` to `NORMAL` aligns it with Quickshell.

**The rule for this toolkit, and the reason this entry exists:** a `<layer-window>`
used as a **dock** must be `#:exclusivity 'normal` (zone 0), never `'exclusive`.
`'exclusive` on a dock looks correct in isolation -- a static dock that pushes
windows aside is a reasonable thing to want -- and it silently shortens every top
bar on the machine, including one built by the same shell. That is exactly
`ags2-shell`'s bug, and it is the obvious thing to type.

**No change needed in the bar.** It is already `'exclusive`, which is right for
a bar, and it will span `0 0 <width>` with no code change the moment nothing
holds a left zone -- which is the case as soon as `ags2-shell` is not running.

## G-Golf generates some methods with NO specializers, and they cannot be called

`AccessPoint.get_connections` is the third instance of the same G-Golf failure,
and it is worth naming because the symptom does not look like the cause.

Astal's `Network.AccessPoint.get_connections` returns
`GenericArray<NM.RemoteConnection>` -- the list of saved connection profiles
that match this access point, i.e. "have I joined this before". It is the right
way to ask, and Astal asks it that way itself (`ap.filter_connections(wifi.
device.client.connections)`).

Under G-Golf 0.8.7 it is unusable, and not in a way that says so:

    n methods 1
      specializers ()
    (get-connections ap)          -> ERROR: goops-error
    (get-connections nm-client)   -> ERROR: goops-error

The method is generated with an **empty specializer list**. A method with no
specializers takes no arguments, so every call with a receiver is "no
applicable method" -- which reads as *you passed the wrong object*, and sends
you looking for a different object to pass. There is no object that works.

`AstalWorkspace` was the first instance and `NM.Client.connections` (a
`GPtrArray`) behaves the same way. **The pattern is a container return type G-Golf
cannot turn into a receiver: `GenericArray<T>`, `GPtrArray`.** A `GList` return
is fine -- `get_workspaces` and `get_monitors` come back as Scheme lists.

**How to tell this apart from a genuine wrong-argument error**, which is the
thing that wastes the time: ask for the specializers, not the error.

    (map (lambda (m) (map class-name (method-specializers m)))
         (generic-function-methods (module-ref (current-module) 'get-connections)))
    => (())

An empty list is the G-Golf codegen failure. A non-empty list naming classes you
did not pass is an ordinary arity/type mistake.

**Workaround, in `(scheme-toolkit astal)`:** `known-wifi-ssids` reads the saved
profiles from `nmcli -t -f NAME,TYPE connection show` and `access-point-known?`
matches against that list. It costs one local subprocess, which is why the
predicate takes an optional pre-fetched list and why the caller fetches once per
refresh rather than once per access point.

## Module-level state is process state: the rule for anything a reload touches

**Written down because the failure is silent.** A reload calls whatever it is
told to and assumes the world it left is the world it finds. Module-level state
breaks that assumption -- and it breaks it quietly: a stale cache looks exactly
like a working one, and the symptom appears somewhere else entirely.

Hyprscheme hit this at scale (`~/GIT/Hyprscheme/CLAUDE.md`): its host throws the
whole Scheme side away and re-evaluates the config into a fresh generation, so
every module with state defines an unexported `reset`, and a sweep in `init.scm`
calls them all before the config is read. **We do not need that sweep, and the
reason is worth stating: our config is data, not code.** We re-read a file and
rebuild widget trees; modules load once and are never re-evaluated. Most of what
Hyprscheme must reset, we never invalidate.

That is a property to keep, not one to rely on by accident. **The rule:**

> A module-level binding is PROCESS-lifetime unless its module exports a
> `reset!` that the reload calls. If you add state that a rebuild invalidates,
> you must add the `reset!` in the same commit.

And for anything created at runtime, ask which of these it is and say so in a
comment:

| created with | belongs to | on reload |
|---|---|---|
| `create-poll` / `interval` / `timeout` | the process, memoised | **keep** -- re-creating leaks a subprocess per rebuild |
| `monitor-file` | the process, one per path | **keep** -- `monitor-file` shares the monitor and appends a callback, so re-watching appends a second one that fires for ever |
| `create-root` / `create-window-root` | a scope | **dispose and rebuild** -- the reload's job |
| `get_default()` singletons (Astal) | the process | **keep** -- clearing drops the backend |
| persisted user data (frecency) | the process AND disk | **keep** -- clearing loses history |

**What NOT to do**, each of which has a failure that looks like something else:

- **Do not memoise a resource without saying it is memoised.** `clock-poller`
  and `date-poller` are `(unless %x (set! %x ...))` with a comment saying why.
  Without the comment the next person "fixes" it by moving the `set!` out, and
  every rebuild starts another `date` process per second.
- **Do not re-monitor a path on a rebuild.** `monitor-file` adds callbacks to a
  shared monitor and returns a stop procedure nobody keeps. A rebuild that
  watches again leaves the old callback alive, subscribed to a dead widget.
- **Do not reset a `get_default()` singleton.** It is not a cache; it is the
  connection to NetworkManager/WirePlumber. Re-acquiring it on every config save
  is a slow and visible bug.
- **Do not put per-generation state in a module variable "for now".** It works
  until the first reload and then it is a stale value nobody can find.
- **Do not rely on `use-modules` re-reading anything.** It loads once per
  PROCESS, ever. Re-evaluating a module's top level means `load` on the file, not
  `use-modules` on the name -- and if a config ever becomes code, that distinction
  is what makes a reload work at all.

**Where this bites today, verified:** none of it does. `%clock-poll`,
`%date-poll` and `%time-poll` are memoised and reused; every `monitor-file`
caller is a once-at-startup path; the calendar's uptime timer is cancelled and
recreated per menu open, not per rebuild; `%config-ticks` and `%initialising`
are weak-keyed so dead widgets collect. The audit is the *reason* to keep it
that way, not a description of a bug.

## The config watcher: now in scheme-utils, and now all working

**THE WATCHER IS NO LONGER IN THIS TREE.** `(scheme-toolkit watch)` and
`(scheme-toolkit inotify)` were Hyprscheme's, taken whole, and they were never
about *this* shell: reading a config and noticing that it changed is the same
job wherever it happens. Both modules now live in the separate `scheme-utils`
tree as `(scheme-utils watch)` and `(scheme-utils inotify)`, alongside the
loader, and `(scheme-desktop config)` uses those. A shell now supplies only the
two decisions that are actually its own -- what to load, and what a reload
means -- through `auto-watch-configure!` and a waiter.

The boundary that matters, and it is what made the move worth doing: the
**waiting is a seam**. `auto-watch-waiter!` takes `(proc fd thunk)`; GLib's is
supplied by default and a Hyprland plugin passes its own. scheme-utils does not
own an event loop, and does not pretend to.

**VERIFIED WORKING** (headless probes, `XDG_CONFIG_HOME` set on the command line,
nothing built and nothing presented):

| change | reloads |
|---|---|
| edit `config.scm` | +1 |
| edit `init.scm` | +1 |
| rewrite a file with the SAME bytes | +0 -- the content guard |
| `init.scm` pulls a file in with `(user-load-config ...)` | +1 |
| edit that pulled-in file | +1 |

**THE NESTED CASE, WHICH USED TO BE BROKEN, NOW WORKS.** Three levels deep --
`init.scm` loads `level1.scm`, which loads `level2.scm` -- an edit to
`level2.scm`, a file no top-level code names, now reloads. Measured, and
repeatedly:

| change | reloads |
|---|---|
| edit `level2.scm`, two levels down | +1 |
| edit `level1.scm`, one level down | +1 |
| edit `level2.scm` again | +1 |

Loaded set after the run: `config.scm`, `init.scm`, `level1.scm`, `level2.scm`.

The difference is batching. The watcher collects every event in one read and
asks the reload question **once for the batch**, adding any newly known
directory's watch during that pass; the toolkit version armed per event, so a
watch added by a file loaded during a reload could be added after the event
that needed it had already been decided.

**TWO THINGS THAT ARE OURS, NOT THEIRS, AND BROKE IT ON THE WAY IN:**

1. **Atomic writes made one save look like three events.** `write-config-file!`
   writes a temporary file and renames it over the target, so inotify reports
   MOVED-TO on the target and CLOSE-WRITE and MOVED-FROM on the temporary -- and
   each is an event against a watched *directory*. Upstream never saw it: a
   Hyprland plugin's config is written by an editor, once. Fixed by comparing the
   file's CONTENT, not the event, plus a 250 ms debounce.

2. **Marking the file as seen on the way IN silences the watcher completely.**
   `auto--watch-arm!` must record the new text only AFTER a reload, never on
   arrival: marking on entry means the timer's own check finds the file matching
   what was just recorded, and every change reads as no change. Measured -- it
   silenced everything, and it looks correct while doing so.

**HOW TO TEST THIS WITHOUT TOUCHING A REAL CONFIG.** `XDG_CONFIG_HOME` must be
set ON THE COMMAND LINE:

    XDG_CONFIG_HOME=/tmp/probe bin/scheme-toolkit guile -s probe.scm

**A `setenv` from inside the script is too late and silently reads the real
config.** `bin/scheme-toolkit` preloads the shell's modules before the script's
first line, and `(scheme-desktop config)` computes its paths in a top-level
`define` at load. Verified: with `setenv` the file resolved to the real
`~/.config`; with the environment variable on the command line it resolved to the
scratch directory. This cost several rounds of probes that were reading and
writing the real config while believing they were sandboxed.

**AND: the load hook watched far more than the config -- REMOVED.**

Hyprscheme builds the watch list from Guile's `%load-hook` (`hyprscheme/watch.scm`
line 178), and this tree inherited that faithfully. The hook is **global**: it
fires for every file the *process* loads, whoever asked for it. Its comment
claimed that meant "the files a CONFIG chose to read, and none of the machinery's
own modules" -- but a file pulled in by `user-load-config` is loaded from inside a
*loaded file*, and the shell's own modules load by name, so the claim was wrong in
both directions at once. It also meant interposing on `%load-hook` process-wide,
which is not this machinery's to take.

Measured, and the reason it was noticed: **evaluating anything over the REPL**
makes Guile compile it, which loads its compiler sources, which the hook reported.
The watch list came back holding 60 files from
`/usr/share/guile/3.0/language/tree-il/` and friends, each with a directory watch,
none of them anything a config asked for.

**The loader reports now, and nothing else does.** `auto-load` calls
`auto--watch-note-loaded!` for each file it reads -- exactly the rule in the
heading -- and `%load-hook` is left precisely as Guile set it. The dependency runs
one way: `(scheme-utils load)` imports `(scheme-utils watch)`.

Measured after the change, with the same REPL eval that used to produce 60 files:

    ("init.scm" "config.scm")

Nested loads still work, because nesting goes through `auto-load` either way:
`init.scm` -> `level1.scm` -> `level2.scm`, editing the deepest, +1 every time.
A file loaded by a bare `primitive-load` is *not* reported -- and that is asserted
in `scheme-utils/tests/run-tests.scm`, because it is the difference between this
and the hook.

## `AstalWp.Endpoint.route` is the DEVICE's route, not the endpoint's

**Symptom.** A row in the audio panel labelled "HDMI / DisplayPort 3 Output" had a
tooltip saying "HDMI / DisplayPort 2 Output", and it looked like a stale tooltip, a
row built from the wrong endpoint, or a label/card mismatch.

**Cause.** None of those. AstalWp's `astal_wp_endpoint_get_route_id` delegates to
the device (`lib/wireplumber/src/endpoint.c:110`):

    return is_speaker ? astal_wp_device_get_output_route_id(dev)
                      : astal_wp_device_get_input_route_id(dev);

so `route` is the card's ACTIVE port and every sink on a card reports the same
one. Measured here, all three Renoir/Cezanne HDMI/DisplayPort sinks answer
"HDMI / DisplayPort 2 Output" while their own `description`s read 1, 2 and 3.

**What to do.** Take the port from the endpoint's `description` (which already
names it, and is what the row shows); there is no per-endpoint route to read.
`(scheme-toolkit services wireplumber)` keeps `endpoint-route-label` and its
docstring records the trap, but nothing in the shell uses it for a port.

Same lesson as `mpris:length` and the mute round trip above: a property that
exists and answers is not necessarily a property that answers *about this
object*.

## A progress readout wired to an event rather than to time

**Symptom.** The now-playing block's elapsed time, total and progress bar were
`0:00`/`0:00`/empty when the audio panel opened, and started working after a
pause/play.

**Cause.** `AstalMpris.Player.position` is fed by a poll that runs once a second
**while playing** and not at all while paused (`lib/mpris/src/player.vala`:
`init_position_poll` / `check_position`), and a player that has not been polled
answers `-1`. The widget wrote its numbers when the service *told* it something
had moved, and a paused player never tells it. The pause/play click was the
notify that had been missing -- which is what made it look like a click bug.

**Rule.** A value that moves with wall-clock time belongs on a clock, not on a
signal. The block now reconciles itself once a second, only while the panel is
open (`panel-open?`), with the timer cancelled through `on-cleanup` -- so a closed
panel costs nothing. Text fields are compared before writing, because `icon-name`
assignment reloads the icon file even when the name is unchanged.

**Cost of getting it wrong is subtle, not loud.** `AstalMpris` reuses its `Player`
object when a bus name comes back, so a player that exits and reappears can leave a
widget showing the previous track's text against the new player's numbers -- a
mixture no single notify can be trusted to fix.

## A `widget-build` that branches on data which arrives later is permanently wrong

**Symptom.** The bar had no media widget. Ever. The user reported it as "the
config lost my media widget" and had deleted `config.scm` about five times to
recover it — and each time the symptom came back.

**Cause, and it is two bugs stacked, neither of which is the config.**

1. **The item branched on the player list at BUILD time.** `widget-build` runs
   once, when the bar is built — and AstalMpris is populated asynchronously, so at
   that instant the list is ALWAYS empty. The build took the "nothing is playing"
   path and returned a bare box with no children, and nothing ever re-decided.
   *Measured:* `bar-trees` held `<gtk-box> … 0 children` for the media item while
   `mpris-players` answered one player.

   The other bar items never hit this because they read a SERVICE object, which
   exists before its data does. This was the only one whose SHAPE depended on
   late data. The fix is `mpris-players-model` — an accessor over the players,
   driven by `player-added`/`player-closed` — with an effect that swaps an empty
   box for the player tree.

2. **A binding path through a GList-valued property reads `#f` for ever.**
   `(create-binding-path m (list "players" first-player "title"))` looks like the
   obvious port and silently yields `#f`: `Mpris.players` through `slot-ref` is a
   raw `<foreign>` pointer, `path-step` asks it for `title` on the way past, and
   the chain collapses. `create-binding` straight onto the PLAYER object works.
   *Measured:* the tree had six children and a blank label; the path accessor
   answered `#f` while the player was on the bus with a title.

**And the thing that made it look like config corruption.** The bar's `layout`
option is a saved value, and `resolve-layout!` SKIPPED a name the registry no
longer knew — with a warning, but the layout was then written back to
`config.scm` unchanged, for ever. The stale name here was `volume`, which `audio`
had replaced. So the bar came up a widget short on a build whose fresh default
was right, and deleting the file only helped until the next write.

**Rule.** `prune-layout!` now TRANSLATES a renamed widget (`%renamed-widgets`)
rather than dropping it, drops names with no successor, and SAVES — because a
repair made during startup has no later change to carry it to the file. A renamed
widget in a shipped default needs an entry in that table or every existing user's
bar loses the slot.

## A pending config save is lost if the shell exits within the debounce

**Symptom.** A layout repaired in memory at startup was still stale in the file
after a restart, so the repair repeated on every start.

**Cause.** Saves are debounced (400 ms) and only the RELOAD path ever flushed a
pending one. Nothing flushed on shutdown, so any change — or repair — within the
window was discarded when the shell exited. `start-shell-config!` now connects
`shutdown` to `widget-config-save!`, once per call.

## A `create-effect` that reads no accessor runs once and never again

**Symptom.** The audio panel's now-playing thumbnail kept the previous video's
picture. The title updated, the thumbnail did not.

**Cause.** The artwork was on its own effect, keyed on the art URL and comparing
against the last one seen — correct logic that never got to matter, because the
effect body called only PLAIN PROCEDURES (`mpris-active-player`,
`player-art-url`). `create-effect` re-runs when something the body read **as an
accessor** changes; a plain procedure records no dependency, so the effect ran
once at build time and then sat inert for the life of the tree.

**Rule.** Every effect needs at least one accessor read, and the usual one is the
service's watch: `(watch)` as the first form. This is also why the same file's
readout effect was fine — it read the watch.

**And the accessor has to be able to NOTICE.** The watch summary did not include
`trackid` or `art-url`, and `create-connection` notifies only on an `equal?`
change — so two videos sharing a title, artist, status and length publish an
identical summary and notify NOTHING. The artwork is not a function of anything
else in that list, so it has to be in the list. (Fixed in
`(scheme-toolkit services mpris)`.)

## `width-request` is a floor, not a cap — and `ellipsize` does not cap either

**Symptom.** The audio panel changed width whenever a new video played.

**Cause.** `max-width-chars` was set on some labels and not others. A
`GtkLabel` with `ellipsize end` but NO `max-width-chars` still reports its **full
natural width**, and the panel is fitted to its widest child — so a long video
title sized the panel. *Measured:* title 385px inside a 380px request, panel box
530px; after adding `max-width-chars 34` the same title measures 272px and the
panel box 417px. Verified with a deliberately 92-character title: the panel did
not move.

**Rule, and `(scheme-desktop widgets bluetooth)` says the same thing at its
`width` slot:** `width-request` does not cap anything, so EVERY label whose text
comes from outside — device names, titles, artist strings, status lines — needs
`max-width-chars` together with `ellipsize end`. A new label without the pair is
a panel that starts moving again.
