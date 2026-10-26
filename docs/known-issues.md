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

## The REPL back door has no socket wiring

`(scheme-toolkit repl coop-server)` and `(scheme-toolkit repl client)` are
vendored from schemacs and load, but nothing yet calls `start-repl!`:
`run-shell` resolves `(scheme-toolkit repl)` at run time and calls it if
present, and there is no such module yet.

The client still speaks schemacs's discovery protocol — a TCP port written to
`$XDG_RUNTIME_DIR/schemacs-repl-<pid>.port` — rather than the Unix socket named
by instance this project wants. `client.scm` needs `repl-port-files` and
`repl-connect` adapted to `.sock` files under `$XDG_RUNTIME_DIR/scheme-toolkit/`.

