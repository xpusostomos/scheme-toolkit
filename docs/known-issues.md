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
