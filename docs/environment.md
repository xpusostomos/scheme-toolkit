# Environment

Everything here was established by experiment against G-Golf 0.8.7, GTK 4.24.1,
Astal (git build) and Hyprland 0.56 on 2026-10-26. `tools/check-env.scm`
asserts all of it; run it first when something behaves inexplicably.

## The three traps

Run `bin/scheme-toolkit check-env`. It should print `ALL GREEN`.

Run bare (`env -u LD_PRELOAD -u LD_LIBRARY_PATH -u GI_TYPELIB_PATH guile -s
tools/check-env.scm`) it should report 17 problems. That contrast is the point:
each trap fails *silently* in normal use, so the diagnostic exists to make the
silence audible.

### 1. `LD_PRELOAD=libgtk4-layer-shell.so` is mandatory

**This is the expensive one.** Without it Astal prints, once, to stderr:

    window.vala:59: can not initialize layer shell on window: layer shell not supported

and then **every layer-shell property set silently no-ops**. `slot-ref` returns
the default value, so a bar compiles, runs, presents a window, and is simply
unanchored. Nothing raises.

    ;; without LD_PRELOAD
    (set! (!anchor w) '(top left right))
    (!anchor w)             ; => (none)
    (!exclusivity w)        ; => normal

    ;; with LD_PRELOAD=libgtk4-layer-shell.so
    (!anchor w)             ; => (top right left)
    (!exclusivity w)        ; => exclusive

### 2. `LD_LIBRARY_PATH` must include `/usr/local/lib`

Astal installs to `/usr/local` and is **not** in the ldconfig cache
(`ldconfig -p | grep -c astal` is 0). Without the path, GI loads the typelib in
a degraded "enums only" mode: no error, no classes. `Astal-4.0` yields 24
bindings instead of 143, and `<astal-window>` is simply absent.

### 3. `GI_TYPELIB_PATH` must include `/usr/local/lib/girepository-1.0`

Where the 23 Astal typelibs live. Same silent failure mode as trap 2.

## Non-environment traps

### GTK4 must be initialised explicitly

Importing Gtk does not initialise it. **Constructing any `<gtk-*>` widget
before `gtk_init()` segfaults with no diagnostic at all.** This is the least
obvious thing in the stack.

    (gi-import-by-name "Gtk" "init")
    (gtk-init)                      ; required before making any widget

`(scheme-toolkit gi)`'s `gtk-bootstrap!` does this, and every entry point calls
it.

### `gi-import-by-name` binds into the *current* module

So it must be called at expand/load time from inside the module that wants the
names -- which is what `define-gi-imports` does. Calling it from a helper
procedure in another module binds the names where the caller cannot see them.

### Astal enums are symbols

Set them the same way as Gtk's `#:orientation 'vertical`:

    (make <astal-window> #:anchor '(top left right) #:exclusivity 'exclusive)

Not integers, and not enum variables -- G-Golf binds no per-member variables.

## Naming

G-Golf binds `NAMESPACE.Type` as `<kebab(namespace + type)>`:

| GI name | Scheme |
|---|---|
| `Gtk.Application` | `<gtk-application>` |
| `Astal.Window` | `<astal-window>` |
| `AstalWp.Wp` | `<astal-wp-wp>` |
| `AstalPowerProfiles.PowerProfiles` | `<astal-power-profiles-power-profiles>` |
| `AstalIO.Process` | `<astal-io-process>` (its C type name) |
| `AstalWl4.find_output_by_gdk_monitor` | `astal-wl4-find-output-by-gdk-monitor` |

Classes get angle brackets; functions do not. Rather than encode these
exceptions anywhere but here, `tools/check-env.scm` tries the plausible shapes
and reports which one appeared.

## Timing

Measured on the development machine, `internal-time-units-per-second` around
each phase:

| Phase | Cost |
|---|---|
| `gi-import-by-name "Gtk" "Application"` | 0.57 s |
| `gtk-init` | 0.01 s |
| `g-irepository-require` × 8 Astal namespaces | 0.001 s |
| `gi-import-by-name "Astal" "Window"` | 0.01 s |
| **total to shell-ready** | **0.59 s** |

For contrast, whole-namespace `(gi-import "Gtk")` costs 2.74 s and
`(gi-import "Adw")` 1.60 s, for 4.7 s of startup. That is why
`define-gi-imports` exists and why nothing here calls `gi-import`.

## Compositor capabilities

Detected at runtime, not assumed:

    (astal-supported? 'workspace)     ; => #t   (ext-workspace-v1)
    (astal-supported? 'idle-notify)   ; => #t   (ext-idle-notify-v1)

Both are supported on Hyprland 0.56, so DESKTOP's workspace service can use
`AstalWorkspace` rather than the `AstalHyprland` fallback.
