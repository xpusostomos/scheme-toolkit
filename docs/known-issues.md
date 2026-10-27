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

## OPEN: "New application windows must be added after GApplication::startup"

Two `Gtk-CRITICAL` warnings appear at shell startup. Windows still appear and
behave, so this is cosmetic — but it is real, and it is not the ordering it
names.

**Ruled out by experiment.** Building a `Gtk.Window` inside the `activate`
handler does NOT produce it, and neither does building an `Astal.Window` there:
both minimal cases are clean. So `run-shell`'s activate-time build is not the
cause, and moving construction to `startup` would be cargo-culting.

**What is left to check.** The shell builds a nested element tree (centerbox →
three boxes → module widgets) inside the window, and `element` applies CSS and
attaches controllers along the way. The likeliest explanation is one of those
children reaching for something that wants an application window already
registered — a style provider or a controller added before the toplevel is
attached.

**Why it is not fixed here.** It costs nothing at runtime, and guessing at a
fix would put an untested reordering into the startup path of every shell built
on this toolkit. Worth root-causing when M8 adds notification popups, which
create windows on the fly and would multiply the warning.

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
