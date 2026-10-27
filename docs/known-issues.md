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
