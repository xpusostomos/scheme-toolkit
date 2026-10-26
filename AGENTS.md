# SCHEME-TOOLKIT

A Guile Scheme desktop-shell toolkit, built on Astal, that is to Scheme what
[AGS](https://github.com/Aylur/ags) v3 is to TypeScript/JavaScript.

**Companion document:** [`SCHEME-DESKTOP.md`](./SCHEME-DESKTOP.md) — the shell
that consumes this toolkit and acts as its integration test. Every milestone
here names the DESKTOP milestone that exercises it; read the two side by side.

**Target platform:** GTK4, Astal (GTK4 namespaces), Wayland/Hyprland.
GTK3 is explicitly out of scope.

**Local reference checkouts used throughout:** AGS at `~/GITE/ags` (v3.1.2),
Gnim at `~/GITE/gnim` (v1.9.1), the shells under `~/GITE/ags-shells/`, G-Golf
source at `/tmp/guile-g-golf/src/g-golf-0.8.7` (the AUR build tree; its
`examples/`, `doc/` and `test-suite/` are the authoritative G-Golf reference).

---

## 0. Revision notes (second review, 2026-10-26)

This revision re-read AGS, Gnim and the shells, and re-ran experiments against
G-Golf 0.8.7 on this machine. The headline corrections to the first draft:

1. **AGS 3.1.2 does not use `AstalIO.Application` or `acquire_socket`.** It is a
   plain `Gtk.Application` whose `application-id` is `io.Astal.<instance>`, and it
   serves the `io.Astal.Application` D-Bus interface *itself* using Gnim's D-Bus
   helper (`~/GITE/ags/lib/gtk4/app.ts`, `lib/app/dbus.ts`). The Go CLI is a plain
   D-Bus client (`cli/lib/astal.go`). The D-Bus server path was **verified
   working under G-Golf** (§ 3), so serving the same four methods is a cheap
   optional shim that keeps the stock `ags` binary working — but it is not the
   primary control surface; see item 7.
2. **Gnim's reactive model is implicit-tracking, not explicit dependency lists.**
   `createComputed([a, b], fn)` is marked `@deprecated` in Gnim 1.9.1
   (`~/GITE/gnim/src/jsx/state.ts:343`); the current form is
   `createComputed(() => a() + b())`. Accessors are *cold* (subscribe to their
   source only while they themselves have subscribers). The first draft had this
   backwards; § M2 is rewritten.
3. **Gnim's JSX runtime has a precise contract the first draft omitted** — the
   `$` setup callback (68 uses across the two reference shells), `$type` child
   slots (55 uses), event controllers as children (`<Gtk.GestureClick>` ×39),
   `onNotify<Prop>`, `class`/`css`, scoped cleanup, `This`/`For`/`With`/`Fragment`.
   § M1 now specifies it. One Gnim trick is **not reproducible** in G-Golf
   (invoking `Gtk.Buildable.vfunc_add_child`); § M1 gives the replacement.
4. **The Astal on this machine is a current git build, not the 0.1 release**, and
   it ships namespaces the first draft never looked at: `AstalWorkspace`
   (ext-workspace-v1 — a compositor-agnostic workspace model), `AstalBrightness`,
   `AstalIdleNotify`, `AstalWl`/`AstalWl4`, `AstalGreet`, `AstalRiver`,
   `Quarrel` (a CLI parser), and `AstalIO.Process`/`AstalIO.Time`. Several things
   the first draft planned to write already exist (§ 4, § 7).
5. **Inventory corrections:** `guile-json` and `guile-fibers` are *not* installed;
   `guile-cairo` *is* installed but as a bare site module, not an Arch package; the
   Astal GSettings schema is **still uncompiled** (trap 2 is live); full `Gtk`
   import costs **2.7 s** and `Adw` **1.6 s** under G-Golf — a startup cost the
   first draft didn't measure.
6. **G-Golf specifics now pinned down by experiment:** property declaration is
   `#:g-param '(double #:default 0.5)` (the first draft's `#:g-property-type`
   syntax does not register a property); `slot-ref`/`slot-set!` is the dynamic
   property path `bind` needs; GList-returning getters come back as Scheme lists
   (no equivalent of AGS's `overrides.ts` hack is needed); `GListModel` works;
   `notify::` fires on custom classes.
7. **The control surface is a Guile REPL, not a bespoke protocol.** AGS needs a
   D-Bus interface with four verbs and a string-switch `Request` handler
   because JavaScript has no way to evaluate code in a running process from
   outside. Guile does: `(system repl coop-server)`. The toolkit's primary
   remote-control mechanism is therefore a cooperative REPL server in the shell
   plus a tiny client (`scheme-toolkit eval '(toggle-window "bar")'`), modelled
   on **`~/GIT/schemacs/schemacs/{repl,coop-server,repl-client}.scm`**, which has
   already solved the GTK-specific problems (wake instead of poll, evaluate on
   the main thread). The `io.Astal.Application` D-Bus interface is kept only as
   an optional ~40-line compatibility shim for the stock `ags`/`astal` CLIs.
   § M5 and § M9 are revised; the Quarrel-based per-shell CLI is dropped.

---

## 1. What this is, and what it replaces

AGS v3 is much smaller than it looks. Measured from `~/GITE/ags` and `~/GITE/gnim`:

| Component | Size | What it does | Scheme-toolkit equivalent |
|---|---|---|---|
| `ags/cli/` (Go) | ~1,200 lines | `run` (esbuild bundle → `gjs -m`, sets `LD_PRELOAD`), `bundle`, `init`, `types`, and the D-Bus client half: `quit`/`toggle`/`request`/`inspect`/`list` | `run` → a `guile` launcher wrapper (§ M11). The remote-control half → **a REPL client** (`scheme-toolkit eval`/`repl`, § M0.5): any Scheme expression, not four fixed verbs. The stock `ags` binary keeps working through an optional D-Bus shim |
| `ags/lib/` (TS) | 1,616 lines | `gtk4/app.ts` (328: `App extends Gtk.Application`, CSS/icons/theme helpers, D-Bus service, `request` signal), `gtk4/jsx-runtime.ts` (56: registers 17 intrinsic tags), `process.ts` (341), `time.ts` (143), `file.ts` (140), `overrides.ts` (92, GJS-only GList workaround), re-exports of Gnim `gobject`/`dbus`/`fetch` | **Rebuilt as `(scheme-toolkit app)`, `process`, `time`, `file`.** `overrides.ts` is unnecessary (§ 3). `process`/`time` shrink to wrappers over `AstalIO.Process`/`AstalIO.Time`, which they were ports of in the first place |
| Gnim 1.9.1 | 4,377 lines | `jsx/state.ts` (847: Accessor, createState/Computed/Memo/Effect/Binding/Connection/External/Settings), `jsx/jsx.ts` (373: the element runtime), `jsx/scope.ts` (185: Scope, createRoot, onCleanup, onMount, createContext), `For`/`With`/`This`/`Fragment` (~300), `gtk4/jsx-runtime.ts` (149: GTK4 child-insertion rules), `dbus.ts` (870: Service/iface/method/property decorators + proxy), `gobject.ts` (521: `@register`/`@property`/`@signal`), `fetch.ts` (411: WHATWG fetch polyfill), `variant.ts` (348: TS-level types only) | **`state`+`scope`+`jsx`+`For/With/This` → the toolkit's core (M1–M2).** `dbus.ts` → `(scheme-toolkit dbus)` (M5). `gobject.ts` → *nothing*: G-Golf's `define-class` already is the decorator layer. `fetch.ts` → *nothing*: Guile has `(web client)`. `variant.ts` → *nothing* |

There is no XML/`.ui` widget language in AGS and never was (see
`~/GITE/ags/GUILE-PORT-AGS.md` for the archaeology). This is a parallel frontend
sharing Astal and the `io.Astal.Application` contract, not a fork.

**Astal is the backend and is not reimplemented.** Astal is Vala/C + GObject
Introspection: any GI language gets the whole service layer free. Verified
working under Guile on this machine (§ 3).

---

## 2. Foundational decision: use G-Golf, not guile-gi

Both GI bindings for Guile are installed here. **Use
[G-Golf](https://www.gnu.org/software/g-golf/).** Evidence:

| | guile-gi 1231.388653a | g-golf 0.8.7 |
|---|---|---|
| Define a GObject subclass | `register-type` exists but is the fragile path; no vfunc support | **First-class**: `define-class` with `#:g-param` slots, `#:g-type-name`, `define-vfunc`, `#:g-signal`; interface implementation via `(g-golf hl-api iface)` |
| Namespace hygiene | **Shadows core syntax.** `Gtk-4.0` alone rebinds `begin`, `run`, `display`, `error`; also collides on `connect` and `quit` | **Merges** generics: with `default-duplicate-binding-handler` set to `merge-generics`, `append` works on both lists *and* `GtkBox` (§ M0). Verified |
| Maintainer | third-party | **GNU/FSF**; 0.8.5–0.8.7 released Mar–May 2026 (`NEWS`), actively maintained |
| Version | git snapshot | **0.8.7 — installed system-wide** (`guile-g-golf 0.8.7-1`) at `/usr/share/guile/site/g-golf/` |

The guile-gi shadowing problem is a correctness hazard, not cosmetic: `(begin
...)` inside a signal callback resolved to GTK's `begin` and failed with *"No
applicable method for `begin`"*.

G-Golf also ships the pieces a toolkit needs: `(g-golf hl-api gobject)` for
subclassing, `hl-api signal`, `hl-api vfunc`, `hl-api iface`, `hl-api closure`
(`<closure>` — verified usable for D-Bus method tables, § 3), `g-main-loop-*`,
`g-timeout-source-new`, `g-idle-source-new`, `g-io-create-watch`, and
`(g-golf support sxml)` (`ui->sxml` / `sxml->ui`).

> **Consequence:** the port is *not* built on `use-typelibs`. Everything below
> assumes `(use-modules (g-golf))` + `gi-import` / `gi-import-by-name`.

**One G-Golf limitation that shapes the design:** G-Golf can *implement* vfuncs
in subclasses (`define-vfunc`) but has **no API to invoke a vfunc on an existing
instance**. GJS has that (`obj.vfunc_add_child(...)`), and Gnim relies on it for
its universal child-insertion fallback. See § M1 for the replacement.

---

## 3. Verified environment (as of 2026-10-26, second pass)

Established empirically, not assumed. New in this revision marked **(new)**.

| Thing | Status |
|---|---|
| Guile | 3.0.11 |
| G-Golf | **0.8.7**, `guile-g-golf 0.8.7-1` (+ `-debug`); source tree at `/tmp/guile-g-golf/src/g-golf-0.8.7` |
| guile-gi | installed (`guile-gi-git`) — superseded, do not use |
| guile-lib | 0.2.8.1 installed |
| guile-cairo | **(new)** installed as `/usr/share/guile/site/3.0/cairo.scm` — *not* an Arch package; packaging (M11) must declare it explicitly |
| guile-json, guile-fibers | **(new) not installed** — consistent with § 4.1 (neither is needed) |
| GTK4 / libadwaita / gtk4-layer-shell | 4.24.1 / 1.10.0 / 1.3.0 |
| Astal | **(new) a git build, not the 0.1 tarball**: `/usr/local/lib/libastal-4.so.4.0.0` dated 2025-10-25, **23 typelibs** in `/usr/local/lib/girepository-1.0/`, GIRs in `/usr/local/share/gir-1.0/` |
| Astal GTK4 namespace (`Astal-4.0`) | classes: `Application`, `Bin`, `Box`, `Slider`, `Window`; `Window` properties: `anchor exclusivity gdkmonitor keymode layer margin-* monitor namespace` |
| Astal service namespaces | Apps, Auth, Battery, Bluetooth, Cava, Hyprland, Mpris, Network, Notifd, PowerProfiles, Tray, Wp, IO — **plus (new)** Brightness, IdleNotify, Workspace, Wl, Wl4, Greet, River, and `Quarrel` (§ 4) |
| `AstalIO` | **(new)** `Application` (iface), `Daemon`, **`Process`**, **`Time`**, `Variable`/`VariableBase` (deprecated) |

**Experiments run this pass** (scripts under `/tmp/stk/`, all with
`LD_LIBRARY_PATH=/usr/local/lib GI_TYPELIB_PATH=/usr/local/lib/girepository-1.0`):

| Experiment | Result |
|---|---|
| `(gi-import "Gtk")` full namespace | **2.74 s**. `Astal` 0.13 s, `Adw` **1.60 s**, each Astal service namespace 0.02–0.07 s. Whole-process startup ≈ 4.7 s with Gtk+Adw imported wholesale → use `gi-import-by-name` for Gtk/Adw (§ M0) |
| `(get-workspaces hyprland)` (GList return) | returns a **Scheme list** of `<astal-hyprland-workspace>`; `(get-monitors h)` likewise. **AGS's `overrides.ts` GList hack has no Guile equivalent and is not needed** |
| Dynamic property access by name | `(slot-ref obj 'name)` and `(slot-set! obj 'label v)` work on imported classes; `!name`/`(set! (!label w) v)` accessors also generated. `g-object-get-property` in G-Golf is the *low-level* API with a different signature — don't use it for `bind` |
| `(connect lbl 'notify::label proc)` then `(set! (!label lbl) …)` | handler fires |
| `GListModel` | `(get-monitors gdk-display)` → `<g-list-store>`; `get-n-items`, `get-item`, `items-changed` all bound. Per-monitor lifecycle can hang off this directly |
| Custom GObject with property | `(define-class <b> (<gobject>) (level #:g-param '(double #:minimum 0.0 #:maximum 1.0 #:default 0.5) #:accessor !level) #:g-type-name "…")` — `notify::level` fires on both `set!` and `slot-set!`. **The first draft's `#:g-property-type` syntax silently registers nothing** |
| D-Bus server | `g-dbus-node-info-new-for-xml` → `register-object` with a G-Golf `<closure>` (pass `(!g-closure c)`, param type `'variant` for `GVariant`) → `busctl` round-trip returned `"pong"`; `Quit` stopped the loop; exit 0. **This is the whole `io.Astal.Application` server mechanism** |
| GI naming quirk | `(gi-import-by-name "Gio" "bus_own_name_on_connection")` imports the `_with_closures` variant (GIR `shadows=`) and G-Golf names it **`g-bus-own-name-on-connection-with-closures`**. Expect this for every `*_with_closures` function; `(describe f)` on the import result shows the Scheme name |
| vfunc invocation | **no API in `hl-api/vfunc.scm`** (only `define-vfunc`, `vfunc` for defining). Design consequence in § M1 |

**Three environment traps to fix in M0** (traps 1 and 2 re-confirmed this pass):

1. **`LD_LIBRARY_PATH=/usr/local/lib` is required.** The ldconfig cache has zero
   astal entries. Without it GI silently loads the typelib *enums only* —
   `Astal-4.0` yields 24 bindings instead of 143, no error.
2. **GSettings schemas are uncompiled** — `/usr/local/share/glib-2.0/schemas/`
   contains `io.astal.notifd.gschema.xml` and **no `gschemas.compiled`**.
   `AstalNotifd` aborts the process. Fix: `sudo glib-compile-schemas
   /usr/local/share/glib-2.0/schemas/`, or install Astal via a proper package.
3. **`GI_TYPELIB_PATH=/usr/local/lib/girepository-1.0`** is needed for the Astal
   typelibs.

Also previously verified: a full `AstalWindow` layer-shell lifecycle works in
Guile, and a 25-cycle build/destroy stress test produced no GObject ownership
assertions — the "ownership is fatal" concern in `GUILE-PORT-AGS.md` was a
guile-gi problem, not a GTK4-under-Guile problem.

---

## 4. Dependency inventory

### Reuse — do not rewrite

| Need | Use | Notes |
|---|---|---|
| GI bridge | **G-Golf 0.8.7** | LGPL, GNU |
| Config / persisted state | **Guile's own `read` + `write`** | § 4.1 |
| Cairo drawing | **guile-cairo** (installed, see § 3) | custom widgets, cava |
| Misc utilities | **guile-lib** | SRFI gaps, string/IO |
| HTTP (weather etc.) | **Guile `(web client)`** | replaces Gnim's 411-line `fetch.ts` polyfill |
| GLib main loop, sources, timeouts, fd watches | G-Golf `glib` API | |
| GObject subclassing / signals / properties / vfuncs / interfaces | G-Golf `hl-api` | § 2 |
| **Subprocesses with line-streamed stdout/stderr, `exec`, `exec_async`** | **`AstalIO.Process`** **(new)** | AGS `lib/process.ts` is a JS port of this class. Wrap, don't rewrite |
| **`interval` / `timeout` / `idle` as cancellable GObjects with a `now` signal** | **`AstalIO.Time`** **(new)** | AGS `lib/time.ts` likewise |
| **Compositor-agnostic workspaces** | **`AstalWorkspace`** **(new)** — `WorkspaceManager.get_default()`, `WorkspaceGroup`, `Workspace` (`activate`, `name`, `coordinates`, `state`), `for_output`, `is_supported()` | Implements `ext-workspace-v1`. Hyprland ≥ 0.50 supports it; this machine runs 0.56.2 — **confirm with `is_supported` in M0**. Replaces the hand-built "compositor abstraction" (DESKTOP § 1) |
| **Backlight / keyboard / LED brightness** | **`AstalBrightness`** **(new)** — `screen`, `keyboard`, `backlights`, `leds`, `Device` with `brightness`/`max-brightness` | Covers the sysfs half of ags2-shell's 591-line `service/brightness.ts`. Only DDC/CI (`ddcutil`) remains to be written |
| **GdkMonitor ↔ Wayland output mapping** | **`AstalWl4.find_output_by_gdk_monitor`** + `AstalWl.Registry` (outputs with `name`, `description`, `make`, `model`, `scale`) **(new)** | Replaces every shell's `hyprctl monitors -j` connector-matching hack (ags2-shell `lib/hyprland.ts`) |
| **Idle detection** (auto-dim/lock timers) | **`AstalIdleNotify`** **(new)** — `get_idle_notification(timeout)` → `Notification` with `idle` property | This is idle *detection*, not idle *inhibit*; inhibit still needs the logind D-Bus `Inhibit` call |
| **Remote control / live introspection of the running shell** | **Guile `(system repl coop-server)`** + `(system repl server)` sockets | The shell's control surface is "evaluate Scheme in the process" (§ M0.5). Replaces AGS's `Request` string protocol and colorshell's 1,358-line CLI parser. `Quarrel` (Astal's GObject arg parser) exists if a shell ever wants a verb-style CLI, but is not planned |
| Services (battery, network, bluetooth, audio, mpris, tray, notifd, hyprland, power-profiles, cava, apps, auth) | Astal typelibs | § 7 |
| Layer-shell surfaces | `Astal.Window` | `Gtk4LayerShell` typelib is the fallback |
| Adwaita widgets | `Adw-1` (widgets only) | **call `(adw-init)`** if any Adw widget is used — AGS does this in `app.ts:21` because it is a common pitfall when the application is not `Adw.Application` |
| Icons/themes | `GtkIconTheme`, `GdkPixbuf`, `Gly`/`GlyGtk4` | colorshell's `pkg.ts` lists `Gly 2`/`GlyGtk4 2` as requirements |
| Notifications D-Bus | `Gio.DBus` + `AstalNotifd` | |

### 4.1 JSON: not needed

Walking through every place JSON appears in the reference shells, none survives
scrutiny:

**(a) Our own config and persisted state — use s-expressions.** `read`/`write`
are built in, give comments, proper types, no escaping rules, and the ability to
embed computed values. Every reference shell uses JSON (`options.json`,
`config.json`) because in JavaScript JSON is a one-liner; that reason does not
transfer. HyprPanel's author lists the "JSON mess" as a motivating pain point.
*Only reason to keep JSON:* a one-off import script for a user's existing
`options.json`.

**(b) Theming — the colour tools are template-driven.** matugen emits whatever
our template says; pywal writes `colors.css`/`colors.sh`/`colors.scss` alongside
`colors.json`. Read a text format.

**(c) `hyprctl -j` — use Astal's object model.** ags2-shell `lib/hyprland.ts:57`
parses the whole monitor JSON array just to build a set of monitor names;
`AstalHyprland.Monitor` exposes `name`, `description`, `width`, `height`,
`refresh-rate`, `x`/`y`, `scale`, `transform`, `focused`, `dpms-status`, `vrr`,
`disabled`, `active-workspace`, `special-workspace`, `reserved-*`. And **(new)**
`AstalWl4` gives the GdkMonitor mapping directly. The one genuine gap
(colorshell reads `configProvider` from `hyprctl status -j`) is answerable from
the filesystem or not worth implementing. `jq` is installed if a raw dump is
ever needed.

**(d) D-Bus — not JSON.** GVariant end to end (§ M5).

**If JSON is ever genuinely required: `guile-json`** (native Scheme data), not
`json-glib` via GI (`Json.Node` objects to walk through GOOPS). Neither is
installed today; neither is planned.

### Deliberately not used

| Avoid | Why |
|---|---|
| `use-typelibs` (guile-gi) | core-syntax shadowing (§ 2) |
| `Adw.Application` / `Adw.ApplicationWindow` | wrong base for layer-shell surfaces. `Gtk.Application` + `Astal.Window`. (colorshell subclasses `Adw.Application` and gets away with it; AGS deliberately doesn't) |
| `AstalIO.Application` / `acquire_socket` / `AstalIO.Variable` | the v2 mechanism; AGS v3 serves D-Bus directly and `Variable` is deprecated upstream |
| **guile-fibers** | GLib's main loop covers the shell's async needs; a second scheduler invites deadlocks. Not installed |
| A JSX-alike *macro* system | the element runtime is an ordinary *procedure* in Gnim too (`jsx(ctor, props)`); Scheme keyword procedures are the DSL (§ M1) |
| SCSS toolchain | generate CSS from Scheme (§ M7) |
| A WHATWG `fetch` polyfill | `(web client)` |

---

## 5. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ SCHEME-DESKTOP   bar · dock · launcher · notifications ·     │
│                  OSD · control centre · desktop icons        │  ← separate project
├──────────────────────────────────────────────────────────────┤
│ (scheme-toolkit launcher)  providers/plugins/frecency        │  M8
│ (scheme-toolkit notify)    daemon ownership + popups         │  M8
│ (scheme-toolkit style)     CSS generation + provider mgmt    │  M7
│ (scheme-toolkit config)    schema · typed accessors · persist│  M6
│ (scheme-toolkit app)       GtkApplication · lifecycle ·      │  M5
│                            optional io.Astal D-Bus shim      │
│ (scheme-toolkit dbus)      serve/proxy interfaces, GVariant  │  M5
│ (scheme-toolkit service)   define-service · singletons       │  M3
│ (scheme-toolkit astal)     thin wrappers, is-supported checks│  M4
│ (scheme-toolkit widget)    element runtime · For/With/This   │  M1
│ (scheme-toolkit reactive)  accessor · state · computed ·     │  M2
│                            effect · binding · scope          │
│ (scheme-toolkit process/time/file/result)                    │  M9
├──────────────────────────────────────────────────────────────┤
│ (scheme-toolkit repl)      coop REPL server · wake · client  │  M0.5
│ (scheme-toolkit gi)        G-Golf bootstrap · import hygiene │  M0
├──────────────────────────────────────────────────────────────┤
│ G-Golf → GObject Introspection → GTK4 / Astal / Adw / Gio   │
└──────────────────────────────────────────────────────────────┘
```

Suggested repo layout:

```
scheme-toolkit/
  scheme-toolkit/          ; the library modules
  bin/scheme-toolkit       ; `run` (env + LD_PRELOAD + guile), `eval`, `repl`, `list`
  examples/                ; minimal shells proving each layer
  tests/                   ; srfi-64, see M10
  docs/
  guix.scm  flake.nix  PKGBUILD
```

---

## 6. Milestones

Each milestone lists: **Goal**, **Build**, **Use**, **Reference**, **C?**, **Done when**.
`→ DESKTOP Dx` links to the companion plan.

---

### M0 — GI bootstrap and import hygiene  *(~2–3 days)*

**Goal:** make importing safe, fast and repeatable, and catch the environment
traps before anything else runs.

> **Status: core paths validated.** `Gtk-4.0` and `Astal-4.0` import; `make`,
> `connect`, `append`, `set-child`, layer-shell window lifecycle, GList and
> GListModel access, custom GObject properties with `notify`, and a D-Bus
> server all work (§ 3). M0 is packaging + diagnostics, not research.

**Build:**
- `(scheme-toolkit gi)`:
  - **sets `default-duplicate-binding-handler` to
    `'(merge-generics replace warn-override-core warn last)` before
    `(use-modules (g-golf))`** inside `eval-when (expand load eval)`. Mandatory;
    every G-Golf example opens with it (`examples/gtk-4/hello-world`).
  - asserts the environment (§ 3 traps) with a clear error message rather than
    failing silently.
  - **selective imports.** `(gi-import "Gtk")` costs 2.7 s and `(gi-import "Adw")`
    1.6 s (§ 3). Provide `define-gi-imports` that lists the classes a module
    needs and calls `gi-import-by-name` per class; whole-namespace `gi-import`
    only for the small Astal namespaces (≤ 0.13 s each). Measure the resulting
    cold start; target < 1.5 s to first window.
  - `gi-check`: loads every required namespace, reports missing typelibs/schemas,
    **binding counts** (a low count = the silent enum-only degradation), and
    `(astal-workspace-is-supported)` / `(astal-idle-notify-is-supported)` so the
    shell knows which optional protocols the compositor offers.
- `tools/check-env.scm` — standalone diagnostic printing versions, typelib and
  schema presence, binding counts, protocol support.

**Use:** G-Golf `gi-import`, `gi-import-by-name`, `g-irepository-require`,
`describe` (to discover Scheme names of `*_with_closures` imports, § 3).

**Reference:** G-Golf `examples/gtk-4/hello-world` (idiom), `examples/adw-1/demo`
(a large multi-module G-Golf app — the best example of how to structure imports
across modules). Astal's `examples/gtk4/simple-bar/py/src/main.in.py` for the
language-neutral `CDLL(libgtk4-layer-shell.so)` bootstrap.

**C?** No.

**Done when:** `check-env.scm` is all green; a ten-line script opens an
`Astal.Window` on Wayland and exits 0; first-window time is measured and recorded.

**→ DESKTOP D0.**

---

### M0.5 — REPL back door  *(~2–3 days; before any widget work)*

**Goal:** talk to a *running* shell in Scheme — read and poke its state, call
its procedures, redefine a widget — from a terminal, from Geiser/Emacs, and
from the test runner. This is the toolkit's remote-control mechanism *and* its
test harness, which is why it comes before M1: every later "done when" is
checked through it rather than through screenshots and synthesized keypresses.

**Why this replaces AGS's protocol.** AGS has a D-Bus interface with four
verbs and a `requestHandler` that string-switches on `argv` because JavaScript
cannot evaluate code in a running process from outside. Guile can. With a
REPL in the shell, `toggle-window`, `quit`, `inspect`, screenshot, "search the
launcher for X" are all just procedures the shell exports, and the keybinding
is `scheme-toolkit eval '(toggle-window "launcher")'`. No verb list, no parser,
no per-verb plumbing, and anything not anticipated is one expression away.

**Reference implementation: `~/GIT/schemacs/schemacs/{repl,coop-server,repl-client}.scm`.**
Read all three; they encode the GTK-specific lessons:

1. **Use `(system repl coop-server)`, never `(system repl server)`.** The
   plain server runs each session in its own thread; GTK is single-threaded,
   and Guile *parameters are thread-local*, so a REPL thread would see the
   default value of every `parameterize`d variable — including this toolkit's
   own current-scope and dependency-tracking parameters (M2). An effect
   created from such a thread would have no scope. The coop server reads in a
   thread but **evaluates on the main thread** when it is polled.
2. **Wake, don't poll.** Upstream's coop server only offers
   `poll-coop-repl-server`, and polling it on a timer cost schemacs a quarter
   of a CPU idle. schemacs's `coop-server.scm` is upstream's file plus a
   `#:notify` hook called from the reader thread whenever work is queued;
   the GTK front end's notify is `g-idle-add` → `poll-repl!`. Vendor that file
   (it is ~100 lines and written up for upstreaming) rather than polling.
3. **Drain the whole queue per wake**, pin `current-module` to a known
   module before evaluating (the main thread may be arbitrarily deep in a
   signal handler with some other module current), and suppress the welcome
   banner (`%inhibit-welcome-message`) because this is a program you
   *connected to*, not one you started.
4. **Make the endpoint discoverable.** schemacs writes a TCP port to
   `$XDG_RUNTIME_DIR/schemacs-repl-<pid>.port`. For a shell use a **Unix
   socket** named by instance — `$XDG_RUNTIME_DIR/scheme-toolkit/<instance>.sock`
   via `make-unix-domain-server-socket` — which needs no port hunting, is
   `0700` by default under the runtime dir, and makes `scheme-toolkit list`
   a directory listing. A stale socket from a crashed shell is detected by
   trying to connect.
5. **Client protocol** is just the coop server's: banner, prompt, one answer
   per expression. schemacs `repl-client.scm` copies server→terminal a
   *character* at a time (a prompt has no newline), terminal→server a line at
   a time, and offers `repl-file-expression`-style one-shot evaluation with
   error detection (`repl-answer-error?`). Port it; ~150 lines.

**Build:** `(scheme-toolkit repl)`:
- `(start-repl! #:instance name #:module '(scheme-desktop user))` — spawns the
  coop server on the instance socket with `#:notify` wired to `g-idle-add`.
- `poll-repl!` as above; `stop-repl!` removes the socket on shutdown.
- `bin/scheme-toolkit eval [-i INSTANCE] EXPR…` (one-shot, prints the value or
  the error, non-zero exit on error), `scheme-toolkit repl [-i INSTANCE]`
  (interactive, with readline), `scheme-toolkit list` (sockets that answer).
- A tiny `(scheme-toolkit repl client)` library the test runner (M10) uses to
  drive a live shell: `(with-shell-repl instance (lambda (eval) …))`.
- **Security note:** this is arbitrary code execution over a socket. The
  runtime dir is per-user `0700` and the socket inherits that; document it,
  refuse to start if `XDG_RUNTIME_DIR` is unset rather than falling back to
  `/tmp`, and never bind TCP by default.

**Use:** `(system repl coop-server)` (vendored with `#:notify`), `(system repl
server)` `make-unix-domain-server-socket`, G-Golf `g-idle-add`, `(ice-9 readline)`
for the client.

**C?** No.

**Done when:** with the M0 ten-line window running, `scheme-toolkit eval
'(set! (!label lbl) "hi")'` changes the label on screen; `scheme-toolkit repl`
gives an interactive session evaluating on the main thread (`(current-thread)`
equals the GTK thread); idle CPU with the REPL open is 0 %; an srfi-64 test
drives the window through the client library and passes headless of any
keyboard input.

**→ DESKTOP D0** (the proof script grows a REPL) and **every later D-milestone's
acceptance check**.

---

### M1 — Element runtime (the JSX equivalent)  *(~1 week)*

**Goal:** reproduce Gnim's element contract as an ordinary Scheme procedure
layer over G-Golf, so widget code's *shape* mirrors the tree's shape and
reactive values can be dropped in anywhere a property goes.

**Read `~/GITE/gnim/src/jsx/jsx.ts` and `src/gtk4/jsx-runtime.ts` first.** Gnim's
`jsx(ctor, props)` is a 130-line procedure; the whole contract is:

| Gnim prop / child | Semantics (from `jsx.ts`) | Scheme form |
|---|---|---|
| ordinary prop `label="x"` | passed to the constructor | `#:label "x"` → `(make <gtk-label> #:label "x")` |
| prop whose value is an **Accessor** | constructor gets `peek()`; after construction, `subscribe` → `set(obj, prop, peek())`; the dispose is registered with `onCleanup` in the current scope | `#:label time-acc` → same, via `(slot-set! obj 'label …)`; dispose registered in current scope (M2) |
| `on<Signal>={fn}`, `onNotify<Prop>={fn}`, `on<Sig>:<detail>` | `connect(signalName(key))`; disconnect registered with `onCleanup` | `#:on-clicked proc`, `#:on-notify-visible proc`, `#:on-changed:detail proc` |
| `class="a b"` (string or Accessor) | `set_css_classes(split)`; reactive if Accessor | `#:class "a b"` |
| `css="…"` (string or Accessor) | per-widget `Gtk.CssProvider` at USER priority on the widget's style context | `#:css "…"` |
| `$={(self) => …}` | setup callback after construction and children | `#:$ (lambda (self) …)` (or `#:setup`) |
| `$type="start"` | tags the child with its GtkBuilder child type for the parent's insertion logic | `#:$type "start"` (or `#:slot 'start`) |
| `$constructor` | alternate constructor (e.g. `Gtk.Label.new`) | `#:constructor proc` |
| **deferred props** (`Gtk.Stack` `visible-child-name`; `Adw.ToggleGroup` `active`) | set *after* children are added, else they are meaningless | same table in `env.initProps` |
| child: string/number | becomes `Gtk.Label.new(text)` | same |
| child: `Gtk.EventController` | `add_controller` (via Buildable) | `(add-controller parent child)` |
| child: `Gtk.Adjustment` to a parent with `set_adjustment` | `set_adjustment` | |
| child: `Gtk.Popover` to `Gtk.MenuButton` | `set_popover` | |
| child: `Gio.MenuModel` to `MenuButton`/`PopoverMenu` | `set_menu_model` | |
| child: named widget to `Gtk.Stack` with `$type="named"` | `add_named(child, name)` | |
| child: `Gtk.Window` to `Gtk.Application` | `add_window` | |
| child: `Gtk.TextBuffer` to `Gtk.TextView` | `set_buffer` | |
| child: anything else | **`parent.vfunc_add_child(dummyBuilder, child, type)`** — GtkBuildable handles CenterBox start/center/end, Overlay overlays, Box append, Window/Button/Revealer/Bin set-child, Grid, ListBox, … | **not available in G-Golf** (§ 2). Replace with an explicit GOOPS generic — see below |
| child: `Fragment` | iterate + subscribe to its `append`/`remove` signals so `For`/`With` can mutate the parent later | same, Fragment as a Scheme record with observers |
| `remove` | `remove_controller` / `set_child(null)` / `remove(child)` | same dispatch |

**The child-insertion generic.** Because G-Golf cannot call
`Gtk.Buildable.add_child`, `(scheme-toolkit widget)` defines
`(add-child! parent child type)` as a GOOPS generic with methods for the parent
classes that matter, in this order of specificity:

```scheme
(define-method (add-child! (p <gtk-center-box>) (c <gtk-widget>) type)
  (case type ((start) (set-start-widget p c)) ((end) (set-end-widget p c))
             (else (set-center-widget p c))))
(define-method (add-child! (p <gtk-overlay>) (c <gtk-widget>) type)
  (if (eq? type 'overlay) (add-overlay p c) (set-child p c)))
(define-method (add-child! (p <gtk-box>) (c <gtk-widget>) type) (append p c))
(define-method (add-child! (p <gtk-stack>) (c <gtk-widget>) type) …)
(define-method (add-child! (p <gtk-grid>) …) …)          ; needs row/col props
(define-method (add-child! (p <gtk-widget>) (c <gtk-event-controller>) type)
  (add-controller p c))
;; fallback: any parent whose class has a writable "child" GObject property
(define-method (add-child! (p <gtk-widget>) (c <gtk-widget>) type)
  (if (class-has-property? (class-of p) 'child) (slot-set! p 'child c)
      (error "cannot add" c p)))
```

This is *more* explicit than Gnim's vfunc trick and is where any new container
gets registered (e.g. `Adw.Bin`, `Adw.Clamp`, `Astal.Box`, `Gtk.FlowBox`,
`Gtk.ListBox`, `Gtk.ScrolledWindow`, `Gtk.Revealer`, `Gtk.Expander`,
`Gtk.Fixed` with `put`). Gnim's own comment in `gtk4/jsx-runtime.ts:78` admits the
generic path "might be way too generic"; an explicit table is the right Scheme
answer.

**Why a procedure, not a macro.** JSX evaluates children eagerly and passes a
props object; a Scheme variadic keyword procedure does exactly the same:

```scheme
(define (bar monitor)
  (window #:name "bar" #:class "Bar" #:gdkmonitor monitor
          #:exclusivity 'exclusive #:anchor '(top left right) #:application app
    (centerbox
      (button #:$type 'start #:on-clicked (lambda (b) (exec-async "echo hello"))
        (label #:label "Welcome"))
      (box #:$type 'center)
      (menubutton #:$type 'end
        (label #:label time)                ; `time` is an accessor → live
        (popover (calendar))))))
```

That is the AGS starter template (`~/GITE/ags/cli/data/gtk4/Bar.tsx`) line for
line. Build:

- `(element <class> . args)` — the runtime: splits keywords into props /
  signals / bindings / specials, constructs with `make`, applies deferred props,
  inserts children via `add-child!`, connects signals, subscribes bindings,
  registers cleanups in the current scope (M2), calls `$`.
- `define-elements` — a macro that generates the short names (`box`, `label`,
  `button`, `centerbox`, `window`, `menubutton`, `popover`, `revealer`,
  `scrolledwindow`, `slider`, `stack`, `switch`, `togglebutton`, `levelbar`,
  `image`, `entry`, `overlay`, `drawingarea`) — the 17 intrinsics in AGS's
  `gtk4/jsx-runtime.ts` — plus whatever DESKTOP needs. Any GI class also works
  directly: `(element <gtk-calendar>)`.
- `This` → `(this! obj . props)` applies props/children to an existing object
  (colorshell uses it 6×, e.g. to configure the window returned by a factory).
- `Fragment` (record with `append!`/`remove!` and observer list), `For`
  (keyed reconcile by `id`, index accessor per item, per-item child scope,
  default cleanup = `unparent`/`run_dispose`) and `With` (single-child swap,
  `createMemo` on the value) — ported from `~/GITE/gnim/src/jsx/{For,With}.ts`
  (105 + 64 lines). Note Gnim's `For` has no "insert at index": it removes all
  and re-appends in order; copy that, it is simple and correct.
- Text children → `Gtk.Label`.
- The `$type` tag must be *stored on the child* (Gnim uses a Symbol property)
  because the child is constructed before the parent sees it. Use a weak hash
  table keyed on the GObject, or a GOOPS slot on `<gobject>` if G-Golf allows.

**Alternative static route — GtkBuilder.** `.ui` XML via `GtkBuilder` and
`GtkBuilderScope`, and G-Golf's `(g-golf support sxml)` `sxml->ui`, were
verified to work. Keep as a documented *option* for large static layouts (G-Golf's
`adw-1/demo` uses `#:template` + `#:child-id` slots this way), not as the primary
DSL — the reference shells are 100 % JSX-style and the port should feel like them.

**Explicitly do NOT build:** a widget registry, a class-per-widget hierarchy, or
anything that wraps `make` beyond `element`.

**Use:** G-Golf `make` with property keywords, `connect`, `append`,
`set-start-widget` etc., `add-controller`, `slot-set!`, `class-slots`
(for the "has a `child` property" fallback).

**Reference implementations, in priority order:**
1. **`~/GITE/gnim/src/jsx/jsx.ts`** and **`src/gtk4/jsx-runtime.ts`** — the
   contract. Also `docs/jsx.md` for the user-facing semantics.
2. **G-Golf `examples/gtk-4/*`** and `examples/adw-1/demo` — the construction
   idiom this expands into; `demos/demo-widget.scm`, `demo-layout.scm`,
   `demo-child.scm` for custom widgets (`define-vfunc` `measure`/`allocate`).
3. **ags2-shell** `widget/Bar/components/Buttons/Battery.tsx`, **colorshell**
   `src/window/bar/widgets/Clock.tsx` — target ergonomics.
4. **`~/GITE/ags/cli/data/gtk4/Bar.tsx`** — the 30-line acceptance test.
5. **`tsyesika/guile-gui-sandbox`** (Codeberg) — a Guile declarative-GTK sketch
   with reactive cells; design reference only, its author says "do not use".

**C?** No.

**Done when:** the AGS starter bar renders from the Scheme above; `For` adds and
removes workspace pills; a test asserts `add-child!` dispatch for every
registered container; the bar's widget tree can be walked and mutated from
`scheme-toolkit repl` (M0.5).

**→ DESKTOP D1** (static bar) and D2 (first `For`).

---

### M2 — Reactive core  *(~1–2 weeks)*

**Goal:** port Gnim's `state.ts` + `scope.ts` semantics faithfully. This is the
biggest piece of genuinely new work, and the reference shells depend on its
exact behaviour (colorshell: 268 `createBinding` uses, 17 `createComputed`;
ags2-shell: 19 `onCleanup`, 17 `createComputed`, 13 `createState`, 10 `For`).

**Port `~/GITE/gnim/src/jsx/state.ts` (847 lines) and `scope.ts` (185 lines)
semantics, not the first draft's sketch.** The essentials:

- **Accessor** — callable: `(acc)` reads *and records a dependency* if a
  computation is tracking; `(peek acc)` reads without tracking;
  `(subscribe acc thunk)` → dispose procedure (not scope-aware);
  `(as acc f)` → derived accessor; `(acc f)` → shorthand for
  `(create-computed (lambda () (f (acc))))`.
  **Accessors must be distinguishable from ordinary procedures** because
  `element` has to tell a signal handler from a bound value. Make `<accessor>` an
  applicable GOOPS class (`(define-class <accessor> (<applicable-struct>) …)`)
  so `(acc)` works *and* `(accessor? x)` is a real predicate — plain lambdas
  cannot do this.
- **Cold by default.** Every accessor subscribes to its sources only when it
  gains its first subscriber and unsubscribes when it loses its last
  (`createBinding`, `createComputed`, `createConnection`, `createExternal`,
  `createPoll`, `createSubprocess` all follow this). This is what makes
  `createBinding` on hundreds of Astal properties free until a widget actually
  shows them.
- **Implicit tracking.** `(create-computed thunk)` runs `thunk` with a fresh
  dependency set pushed on a tracking stack; every `(acc)` read inside adds
  itself. On any dependency change, the cached value is invalidated and
  subscribers notified; dependencies are re-diffed on recompute. The tracking
  stack is a Guile **parameter** (`make-parameter` + `parameterize`) — the
  natural replacement for Gnim's module-level `accessStack`.
  The explicit-deps form `(create-computed (list a b) f)` may be kept as sugar
  but is deprecated upstream.
- **`create-memo`** — like computed but only notifies when the value changes
  (`equal?` or custom `#:equals`); `With` uses it.
- **`create-effect`** — runs *on mount* (after the enclosing scope returns)
  unless `#:immediate #t`; re-runs on dependency change; disposes and recreates
  its own child scope each run; warns if created outside a root.
- **`create-state`** → two values: accessor and setter (setter accepts a value
  or an updater procedure; equality `eqv?`/custom). In Scheme:
  `(define-values (count set-count!) (create-state 0))`.
- **`create-binding obj "prop" ["prop2" …]`** — `notify::prop` on a GObject or
  `changed::key` on `Gio.Settings`; nested path form follows null-safely via
  computed. Getter: `slot-ref` (verified) with fallback to `get-<prop>`.
- **`create-connection init (obj "signal" f) …`** — accessor fed by signal
  handlers; `create-external init producer`; `create-settings`.
- **Scope** — `parent`, cleanups, mounts, contexts; `(create-root (lambda (dispose) …))`,
  `on-cleanup`, `on-mount`, `get-scope`, `(create-context default)` with
  `provide`/`use`. `Scope.current` is again a parameter. Gnim's rule: `onMount`
  callbacks bubble to the nearest *unmounted* ancestor so they run once the
  whole tree is built — keep that.

**Bind semantics and GObject lifetime.** A binding's `notify` handler holds the
GObject alive via G-Golf's closure cache; disposing the scope must disconnect
it. Add a test that builds and disposes 1,000 bound labels and checks no
handlers remain (`g-signal-handler-find`) and RSS is flat.

**Use:** G-Golf `connect`/`disconnect` (`notify::` detail — verified), `slot-ref`,
`g-signal-handler-disconnect`; Guile parameters, `(oop goops)`
`<applicable-struct>`, weak hash tables for subscriber sets.

**Reference implementations:**
- **`~/GITE/gnim/src/jsx/state.ts`, `scope.ts`** — port these. `docs/jsx.md`
  explains the intended semantics and pitfalls (e.g. effects outside roots).
- **ags2-shell `tests/lib/core.test.ts`** (915 lines) and `tests/lib/textures.test.ts`
  — load the *real* Gnim and exercise it; these are ready-made behavioural specs
  to translate into srfi-64.
- **HyprYou** `hypryou/utils/ref.py` (520 lines) — a non-JS reactive layer with
  the same shape; useful second opinion on API naming.
- **Astal `lang/lua/astal/{variable,binding}.lua`** — design reference only.

**Design note.** The first draft proposed `(count)` to read and `(count 1)` to
write on the same procedure. Don't: Gnim reserves the one-argument call for
"derive a computed from this accessor" (`time((t) => …)` is used constantly in
the shells), and a read/write pun hides mutation. Keep the accessor/setter pair.

**C?** No.

**Done when:** a translated subset of `core.test.ts` passes; a live clock and
battery percentage update without polling; disposing a root leaves no handlers
— asserted from the REPL against the live shell (`(g-signal-handler-find …)`
counts before and after `dispose`).

**→ DESKTOP D2.**

---

### M3 — GObject service authoring  *(~3–4 days)*

**Goal:** a thin, idiomatic way for a shell to define its own observable
GObject services — the pattern every shell uses for what Astal doesn't cover.

**Build:** `(scheme-toolkit service)`

```scheme
(define-service <night-light>
  #:g-type-name "StNightLight"
  (enabled     #:g-param '(boolean #:default #f) #:accessor !enabled)
  (temperature #:g-param '(uint #:minimum 1000 #:maximum 10000 #:default 4000)
               #:accessor !temperature)
  #:g-signal (changed)
  #:init (lambda (self) …))
```

- Expands to G-Golf `define-class` over `<gobject>` with the **verified
  `#:g-param` slot syntax** (§ 3) — `notify::` fires on `set!`/`slot-set!`, so
  M2's `create-binding` works unchanged on these classes.
- Adds a memoised `get-default` singleton and a `(service-ref <class>)` lookup.
- Signals via G-Golf's class-level signal declaration (check
  `test-suite/tests/hl-api.scm` for the exact option name in 0.8.7).
- `service-supervise` for restartable services (HyprYou `utils/service.py`).

Note Brightness is no longer the motivating example — `AstalBrightness` exists.
Good first services for DESKTOP: night light, screen capture, clipboard.

**Reference:** **colorshell** `src/modules/*.ts` (`@register({GTypeName})` +
`@getter`/`@property`/`@signal`, 25 uses of `register`); **ags2-shell**
`service/*.ts` (every service is a GObject — more consistent than colorshell,
which mixes in static classes like `modules/battery.ts`); **G-Golf**
`test-suite/tests/hl-api.scm:158` and `examples/adw-1/demo/pages/tab-view/
tab-view-demo-page.scm:63` for `#:g-param` usage; **Gnim** `docs/gobject.md` for
what the decorator layer offered (nothing more is needed).

**C?** No.

**Done when:** a custom service property drives a widget via `create-binding`
and is visible to `g-object-class-find-property`.

**→ DESKTOP D3.**

---

### M4 — Astal binding layer  *(~2–3 days)*

**Goal:** thin wrappers so desktop code never touches raw GI for common
services; plus feature detection.

**Build:** `(scheme-toolkit astal)` — `get-default` singletons for Battery,
Network, Bluetooth, Wp, Mpris, Tray, Notifd, Hyprland, PowerProfiles, Apps,
Cava, Auth, **Brightness, Workspace, IdleNotify, Wl**; `(astal-supported? 'workspace)`
style predicates wrapping `is_supported`; convenience accessors that return
M2 accessors (`(battery-percentage)` → accessor).

ags2-shell's entire Astal surface is 21 `get_default()` calls across 11
namespaces; this module is small. colorshell `src/pkg.ts` is a ready-made
manifest of namespace versions.

**Reference:** ags2-shell (measure the surface), colorshell `src/pkg.ts`, and
the **counter-example HyprYou**, which hand-rolls network (911 lines), tray
(557), mpris (425), upower (248) that Astal provides.

**C?** No.  **Done when:** battery/volume/workspaces bind in ≤ 5 lines each.

**→ DESKTOP D2/D3.**

---

### M5 — Application shell, layer surfaces, lifecycle, D-Bus  *(~1–2 weeks)*

**Goal:** turn a widget tree into a running shell with correct multi-monitor
lifecycle, controlled through the REPL (M0.5), with D-Bus available for the
things that genuinely need it.

**What AGS does, from `~/GITE/ags/lib/gtk4/app.ts` and `cli/lib/astal.go`, and
what we do instead:**

| Piece | AGS 3.1.2 behaviour | Scheme |
|---|---|---|
| Application | `Gtk.Application` with `Gio.ApplicationFlags.HANDLES_COMMAND_LINE`; `application-id = "io.Astal." + instanceName` | same via `make <gtk-application>`; the id is kept for the shim below and for single-instance behaviour |
| Remote control | D-Bus `io.Astal.Application` (`Quit`, `Inspector`, `ToggleWindow(s)`, `Request(as)→s`) + a `requestHandler` string-switch in the shell | **the REPL (M0.5).** The shell exports ordinary procedures (`toggle-window`, `quit`, `inspect`, …); clients `eval` them. No `Request` protocol |
| `ags`/`astal` CLI compatibility | the Go client calls the four methods | **optional shim**: `(serve-astal-dbus-shim)` registers the same interface in ~40 lines of `(scheme-toolkit dbus)` (verified, § 3) and maps `Request(argv)` to `(eval (read-from-string (string-join argv)))` in the user module. Keeps existing `ags toggle` keybindings working during migration. Off by default |
| Second invocation of the binary | `vfunc_command_line` with `is_remote` → `request` | `scheme-toolkit eval`; no `command-line` vfunc needed. (`HANDLES_COMMAND_LINE` still prevents a second instance from stealing the id — keep the flag, print "already running, use `scheme-toolkit eval`" and exit) |
| `Inspector` | `Gtk.Window.set_interactive_debugging(true)` | `(inspect)` procedure doing the same, callable from the REPL |
| `windowToggled`, `monitors` notify | `notify::visible` on each added window; `items-changed` on `Gdk.Display.get_monitors()` | same (GListModel verified) |
| CSS helpers | `apply_css(path-or-string, reset?)` at **`STYLE_PROVIDER_PRIORITY_USER`**, `reset_css`, `add_icons`, `parsing-error` logging with file:line:col | move to `(scheme-toolkit style)` (M7), keep the API names |
| Theme shortcuts | `gtk-theme`, `icon-theme`, `cursor-theme` over `Gtk.Settings` | same |
| Env hygiene | **`GLib.unsetenv("LD_PRELOAD")` immediately after `Gtk.init()`** so subprocesses and `gio launch` don't inherit the layer-shell preload (also done by colorshell `app.ts:125`) | same — easy to forget, breaks launched apps if forgotten |
| Adwaita | `Adw.init()` attempted if available | `(adw-init)` when Adw is imported |
| Startup | `hold()`; serve D-Bus; `createRoot((dispose) => { connect("shutdown", dispose); main() })` | same with M2 `create-root` |

**Build:** `(scheme-toolkit app)` and `(scheme-toolkit dbus)`:
- `app`: the table above, plus `define-layer-window` (`Astal.Window` with
  anchors/exclusivity/layer/margins/namespace/keymode/gdkmonitor) and
  **per-monitor lifecycle**: `(for-each-monitor (lambda (gdk-monitor) …))`
  creating a root per monitor from `Gdk.Display.get_monitors()` and disposing
  on `items-changed`; monitor identity via **`AstalWl4.find_output_by_gdk_monitor`**
  (output `name`/`description`) instead of connector-string hacks.
  `start` wires `start-repl!` (M0.5) before `main` so a shell that fails during
  startup can still be inspected. `run` / `before-quit` (ags2-shell's async
  `before_quit` that flushes options and stops recorders is the right shape) /
  `quit` / `inspect` / `toggle-window` / `windows` / `monitors` as exported
  procedures — the REPL vocabulary.
- **`<popup-window>`** — an `Astal.Window` subclass (G-Golf `define-class` with
  `#:g-param` properties) for the pattern every shell reimplements: anchored to
  all four edges, `exclusivity 'ignore`, content aligned to a corner, properties
  `close-on-click-outside`, `close-on-escape`, `position` (`'top-right` etc.),
  `transition` (`Gtk.Revealer` type), and an optional `follow-window` so a
  popup's position tracks the bar's. Model: **colorshell
  `src/widget/PopupWindow.tsx`** (the subclass-with-properties shape) plus
  ags2-shell `widget/shared/PopupWindow.tsx` for `create_popup_position` and
  the revealer animation. Every DESKTOP popup (launcher, control centre,
  notifications, date menu, power menu) is an instance.
- **`panel-button`** — a `Gtk.Button` element that toggles a named window and
  tracks that window's `notify::visible` to set an `active` CSS class; model
  **ags2-shell `widget/Bar/components/PanelButton.tsx`**. Together with
  `<popup-window>` this makes "a feature = its bar button + its window" a
  two-line pattern for any shell.
- `dbus`: still needed, but not for shell control. The *server* half serves
  the notification daemon (M8) and the optional Astal shim; the *client* half
  does logind `Inhibit`, `GetNameOwner`, NetworkManager odds and ends.
  `serve-interface` (XML or SXML description → closures; GVariant marshalling
  helpers — method parameters arrive as a raw `GVariant` pointer and need
  `g-variant-get-strv`/`get-child-value` unpacking), `proxy` (sync + async via
  `g-dbus-connection-call`), `own-name` (note the `-with-closures` naming
  quirk, § 3), property/signal emission. Gnim's `dbus.ts` (870 lines,
  `docs/dbus.md`) is the spec for the shape.

**Use:** G-Golf `hl-api closure`; `g-dbus-*`; `Gtk.Window.set_interactive_debugging`;
`(scheme-toolkit repl)`.

**Reference implementations:**
- **`~/GITE/ags/lib/gtk4/app.ts`** (328 lines) — the lifecycle, CSS and theme
  helpers to mirror; `lib/app/dbus.ts` (51) + **`~/GITE/ags/cli/lib/astal.go`**
  for the shim's exact contract (the Go client treats `NoReply`/"Remote peer
  disconnected" on `Quit` as success).
- **`~/GITE/gnim/src/dbus.ts`** + `docs/dbus.md` — the D-Bus layer's shape.
- **`~/GIT/schemacs/schemacs/main.scm`** — how `--server`/`--repl`/`--remote`
  are wired into one entry point; `se --remote FILE` is the model for
  "a keybinding that evaluates one expression in the running process".
- **ags2-shell `shell/main.tsx`** (309 lines) — multi-monitor roots keyed by
  connector, deferred window mounting in nested `idle`s, wallpaper child
  supervision with exponential backoff, request handling guarded by
  `ready`/`quitting`/`stopping` (the guard logic transfers to the exported
  procedures). **Best lifecycle reference.**
- **colorshell `src/windows.ts`** (45) + `src/window/index.ts` (356) — a
  declarative window registry (`shellWindows` name → factory) with
  `open`/`isOpen`/`forFocusedMonitor`/`forAllMonitors`. Cleaner; adopt the
  registry shape.
- **Astal** `lib/astal/gtk4/src/widget/window.vala` — the layer-shell window.
- **HyprYou** `hypryou/src/widget.py` `LayerWindow` — proof the `Gtk4LayerShell`
  typelib route works if `Astal.Window` ever limits us.

**C?** No.

**Done when:** `scheme-toolkit eval '(toggle-window "bar")'` toggles the bar;
two monitors get independent bars; hot-unplug disposes cleanly (handler counts
checked over the REPL); a `<popup-window>` opens from a `panel-button`, closes
on click-outside and Escape, and the button's `active` class tracks it; with
the shim enabled, `ags list`/`toggle`/`quit`/`inspect` work with the unmodified
`ags` binary.

**→ DESKTOP D4.**

---

### M6 — Configuration / options  *(~1 week)*

**Goal:** typed, validated, persisted, live-reloading options that are M2 accessors.

**Build:** `(scheme-toolkit config)` — schema with types + defaults; accessors
returning M2 accessors (the key integration point); s-expression persistence
with **debounced atomic writes**; corrupt-file recovery (rename to `.bad`,
regenerate); live reload via `Gio.FileMonitor` (`(scheme-toolkit file)`
`monitor-file`, M9).

Consider also wrapping **`Gio.Settings`** via `create-settings` (Gnim has it):
a compiled GSettings schema gives `dconf` tooling, type validation and change
notification for free and is the GNOME-native answer. Offer both; let DESKTOP
pick at D5.

**Reference:** **ags2-shell `shell/options.ts`** (609 lines) — `Opt<T>` over
`createState`, validation, `Store` namespace, `set_aside_unreadable_store()`
→ `options.json.bad`. **colorshell** `src/modules/config.ts` (310) +
`src/config.ts` (152) — path-keyed store with typed `bindProperty`. **matshell**
`options.ts`. **Gnim** `state.ts:817 createSettings`.

**C?** No.  **Done when:** editing the config file live-updates the bar; a
truncated file is recovered.

**→ DESKTOP D5.**

---

### M7 — Styling subsystem  *(~1 week)*

**Goal:** CSS generation, provider management, hot reload.

**Build:** `(scheme-toolkit style)` — CSS AST → string (SXML-like
`(rule ".Bar" (background …))`) with palette variables; `apply-css` /
`reset-css` / `add-icons` with AGS's API shape and its `parsing-error` → 
`file:line:col` logging; provider priority **`APPLICATION` (600) or `USER`
(800)** — AGS uses USER, colorshell APPLICATION; both beat libadwaita's
stylesheet, pick one and document it; per-widget `#:css` support for M1;
reload on palette change.

**Reference:** **colorshell `src/modules/stylemanager.ts`** (189) — reload on
wallpaper change, `colors-updated` signal. **ags2-shell `style/`** +
`style/runtime-css.ts` (314) — runtime CSS from options. **`~/GITE/ags/lib/gtk4/app.ts:183`**
`apply_css` for the error-reporting pattern. **Gnim `gtk4/jsx-runtime.ts:29
setCss`** for per-widget providers.

**C?** No.  **Done when:** wallpaper change recolours live, Adw widgets included.

**→ DESKTOP D6.**

---

### M8 — Launcher and notification frameworks  *(~1–2 weeks)*

**Build:**
- `(scheme-toolkit launcher)` — prefix-routed plugin registry
  (`{prefix name init handle on-close prioritize icon-name}`), frecency, async
  result streaming via accessors.
- `(scheme-toolkit notify)` — own `org.freedesktop.Notifications` (using
  M5's `dbus` server + `GetNameOwner` takeover logic), popups, history, DND,
  timeouts, on top of `AstalNotifd`.

**Reference:** **colorshell `src/runner/`** (1,526 lines; 7 plugins with
prefixes `? # ! > :`; `RunnerWindow.addPlugin`) — **best plugin architecture**.
**matshell `utils/picker/`** (frecency + providers; byte-identical to Ateon's
copy, confirming origin). **ags2-shell `service/notifications.ts`** (146) +
`lib/notifications.ts` (302) — **best daemon-ownership reference**.
**colorshell `src/modules/notifications.ts`** (371) — history/DND/hold data model.

**C?** No.  **Done when:** ≥ 3 plugins route by prefix; the shell owns the bus
name and shows history.

**→ DESKTOP D7/D8.**

---

### M9 — Process, time, file, result  *(~3–4 days, shrunk)*

**Goal:** the utility layer, now mostly wrappers.

**Build:**
- `(scheme-toolkit process)` — `exec`, `exec-async`, `subprocess` with
  stdout/stderr line callbacks, `kill`, `signal`, `write`; **over
  `AstalIO.Process`** (`subprocessv`, `execv`, `exec_asyncv`, signals `stdout`,
  `stderr`, `exit`). Plus `create-subprocess init cmd [transform]` → cold accessor
  (AGS `process.ts:309`).
- `(scheme-toolkit time)` — `interval`, `timeout`, `idle` returning cancellable
  `AstalIO.Time` objects (`now`, `cancelled` signals); `create-poll init ms
  cmd-or-thunk [transform]` → cold accessor (AGS `time.ts:93`). Verify G-Golf
  handles the `GAsyncReadyCallback` in `exec_asyncv` (in M0's `check-env`).
- `(scheme-toolkit file)` — `read-file[-async]`, `write-file[-async]` (creates
  parent dirs, `REPLACE_DESTINATION`), **`monitor-file`** with AGS's recursive
  directory behaviour and the "keep the monitor referenced" set (`file.ts:83`).
- `(scheme-toolkit result)` — `ok`/`err`/`attempt`/`attempt-async`/`unwrap-or`
  /`with-context`/`log-error`. **Adopt ags2-shell `lib/result.ts` wholesale**
  (119 `attempt`, 73 `attempt_async`, 13 `unwrap_or` uses; `unwrap_or(result,
  fallback, tag)` logs *and* degrades). Guile has exceptions; `attempt` wraps
  `with-exception-handler`.

**CLI:** none here. Remote control is `scheme-toolkit eval` (M0.5); a
per-shell convenience CLI (colorshell style `shell volume up`) is a DESKTOP
concern and is a shell script of `eval` calls, not a parser.

**Reference:** `~/GITE/ags/lib/{process,time,file}.ts` (API surface to match);
`AstalIO-0.1.gir` (`Process`, `Time`); ags2-shell `lib/result.ts`,
`lib/commands.ts` (one subprocess chokepoint).

**C?** No.  **Done when:** `create-poll` drives a clock; `Result` covers every
fallible boundary in DESKTOP D3.

**→ DESKTOP D2 (clock), D3/D4.**

---

### M10 — Testing harness  *(~3–5 days)*

**Goal:** three tiers of tests, the top two of which run through the REPL.

**Build:**
1. **Pure logic, headless** — srfi-64 suites for `reactive` (translate
   ags2-shell `tests/lib/core.test.ts`), `config`, `result`, `time`,
   `add-child!` dispatch (with a stub layer where GI isn't needed).
2. **Live-shell tests over the REPL** — the test runner starts the shell (or
   attaches to a running one), then uses `(scheme-toolkit repl client)` to
   evaluate expressions *in the shell process*: walk the widget tree, read
   accessor values, trigger procedures, count signal handlers, assert. This is
   the tier ags2-shell can only approximate with `node:vm` stubs, and it needs
   no fake JSX tree — it inspects the real one. It also replaces screenshot +
   `wtype` style UI testing, which schemacs documents as unreliable (a
   mis-focused window produces a convincing screenshot of the wrong thing).
3. **Display-dependent tests in CI** — tier 2 under a nested headless
   compositor (`WLR_BACKENDS=headless` with sway/labwc, or Hyprland headless);
   GTK4 has no offscreen backend. Monitor hotplug tests add/remove headless
   outputs and assert over the REPL that roots were created/disposed.

**Reference:** **`~/GIT/schemacs/schemacs/repl-client.scm`** and
`tools/repl.py` — the client side a test runner needs. **ags2-shell `tests/`**
— 38 files, ~11k lines, the only tested shell in the set; `overview.test.ts`,
`GridGeometry.test.ts`, `textures.test.ts`, `native-smoke.js`. No other
surveyed shell has tests.

**C?** No.  **Done when:** CI runs tiers 1–2 headless under a nested
compositor; a hotplug test passes.

---

### M11 — Packaging and developer experience  *(~3–5 days)*

**Build:**
- `bin/scheme-toolkit run <dir>` wrapper: exports `LD_LIBRARY_PATH`,
  `GI_TYPELIB_PATH`, `LD_PRELOAD=libgtk4-layer-shell.so`, then `guile -L … -e main`.
  Compile with `guild compile` at install; document `~/.cache/guile/ccache`.
- **REPL polish** (the server exists since M0.5): Geiser/Emacs integration
  notes (`geiser-connect` to the Unix socket), readline history for
  `scheme-toolkit repl`, `,inspect-widget` style REPL meta-commands via
  `(system repl command)` `define-meta-command`.
- Hot reload: `monitor-file` on the shell's source tree → `reload-module`,
  itself just an expression sent over the REPL.
- `guix.scm`, `flake.nix`, `PKGBUILD` (depends: `guile`, `guile-g-golf`,
  `guile-lib`, guile-cairo, `astal-*`, `gtk4-layer-shell`, `libadwaita`).

**Reference:** AGS `ags run` ergonomics; **lambdock**
(`codeberg.org/jjba23/lambdock`) for Guile-shell socket REPL + hot reload prior
art (uses neither Astal nor G-Golf).

**C?** No.  **Done when:** installs from a package; Geiser connects to a
running shell and a widget is redefined live from Emacs.

---

## 7. What NOT to build

| Don't build | Because |
|---|---|
| A widget abstraction layer / registry | `element` + `add-child!` over G-Golf `make` is the whole runtime (§ M1) |
| A GI/typelib bridge in C | G-Golf |
| Service backends (network, bluetooth, audio, mpris, tray, battery, notifd, hyprland, power-profiles, cava, apps, auth) | Astal. HyprYou's ~2,400 hand-rolled lines are the cautionary tale |
| **A compositor abstraction** | **`AstalWorkspace`** (ext-workspace-v1) + `AstalHyprland` for Hyprland-only extras. colorshell's `src/compositor/` (1,220 lines) and matshell's `utils/compositor/` solve a problem Astal now solves |
| **A brightness backend** | **`AstalBrightness`**; only DDC/CI remains |
| **Subprocess / timer classes** | **`AstalIO.Process` / `AstalIO.Time`** |
| **A remote-control protocol** (verbs, request handlers, CLI parser) | **the Guile REPL** (§ M0.5). The shell's control surface is "evaluate an expression"; `ags`-compatibility is an optional 40-line D-Bus shim |
| A JSON parser | s-expressions (§ 4.1) |
| A CSS/SCSS compiler | generate CSS from Scheme (M7) |
| A bundler | `guild compile` |
| A layer-shell implementation | `libgtk4-layer-shell.so` + `Astal.Window` |
| A concurrency runtime | GLib main loop; no fibers |
| A `fetch` polyfill | `(web client)` |
| GObject decorator layer (Gnim `gobject.ts`) | G-Golf `define-class` already is one |

**Total C expected: none.**

---

## 8. Deferred / optional

- **i18n** — colorshell `src/i18n/` (899 lines, 6 locales); runtime ~160 lines,
  `lang/*.ts` are pure data.
- **GtkBuilder / `.ui` / SXML authoring** — verified working; keep as an option.
- **Cava visualiser** — matshell/Ateon `widgets/music/modules/cava/` (~1,089
  lines, framework-independent geometry).
- **`AstalIdleNotify`-driven auto-dim/lock** — new capability; cheap once M4 exists.
- **`AstalGreet`** — a greetd greeter in Scheme is a plausible third consumer of
  the toolkit (HyprYou ships one in `greeter/`), and a good "is the toolkit
  really generic?" test.

---

## 9. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Silent enum-only typelib degradation (trap 1) | **High** — wastes days | `gi-check` asserts binding counts |
| Startup time from whole-namespace imports | **Medium (new)** | 2.7 s + 1.6 s measured; `gi-import-by-name` per class; measure in M0 |
| `add-child!` table misses a container | Medium (new) | clear error naming parent/child classes; test per registered container; fallback on a writable `child` property |
| Reactive semantics drift from Gnim | Medium | port `state.ts` faithfully; translate `core.test.ts` |
| GVariant marshalling ergonomics in `dbus` | Medium (new) | parameters arrive as raw pointers; write unpack helpers once in M5 and test against `busctl` |
| REPL socket is arbitrary code execution | Medium (new) | Unix socket under `$XDG_RUNTIME_DIR` (0700), refuse to start without it, never TCP by default; document it as the development/control back door it is |
| REPL evaluating off the main thread | **High if done wrong** | coop server only; the "done when" test checks `(current-thread)` from the REPL equals the GTK thread |
| G-Golf naming surprises (`*-with-closures`, low-level vs hl-api procedures sharing names) | Low–Medium (new) | document in `(scheme-toolkit gi)`; `describe` imports when unsure |
| G-Golf maturity on long-running / custom-widget paths | Medium | core paths verified; `define-vfunc` widgets in M1; D12 soak |
| Astal upstream churn (git build, new namespaces still settling) | Medium | pin the Astal commit in packaging; `is_supported` checks at runtime |
| `AstalWorkspace` unsupported on a given compositor | Low | fall back to `AstalHyprland` for workspaces; detect in `gi-check` |

---

## 10. Milestone order at a glance

| # | Toolkit | Est. | Exercises via | Easy win? |
|---|---|---|---|---|
| M0 | GI bootstrap + hygiene + timing | 2–3 d | D0 | ✅ first green light |
| M0.5 | **REPL back door** (coop server, wake, client) | 2–3 d | D0, then every D | ✅ **poke the running shell**; testing hangs off this |
| M1 | Element runtime, `add-child!`, For/With/This | 1 w | D1 | ✅ **visible bar** |
| M2 | Reactive core (Gnim port) | 1–2 w | D2 | ✅ **live widgets** |
| M9 | process/time/file/result (wrappers) | 3–4 d | D2 | ✅ cheap, pulled forward |
| M4 | Astal wrappers + feature detection | 2–3 d | D2/D3 | ✅ cheap |
| M3 | Service authoring | 3–4 d | D3 | |
| M5 | App + layer + lifecycle (+ optional `ags` shim) | 1–2 w | D4 | ✅ **real multi-monitor shell** |
| M6 | Config | 1 w | D5 | |
| M7 | Styling | 1 w | D6 | ✅ **looks good** |
| M8 | Launcher + notify frameworks | 1–2 w | D7/D8 | |
| M10 | Test harness (tiers 1–3, REPL-driven) | 3–5 d | all | |
| M11 | Packaging + REPL polish | 3–5 d | D12 | |

**Critical path:** M0 → M0.5 → M1 → M2 → M5 → M7. M9 and M4 are cheap and should
be done alongside M2 so D2 has `create-poll` and Astal singletons on day one.
The REPL is deliberately second: everything after it is verified through it.
