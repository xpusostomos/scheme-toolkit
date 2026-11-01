# Warnings this project filters out

`bin/scheme-toolkit` runs the interpreter with its **stderr filtered** through a
short list of known patterns. A shell's stderr is where a real problem has to be
seen, so this file exists to justify every entry: what emits it, why it is
deliberate or not ours, and what is lost by hiding it.

    bin/scheme-desktop run          # filtered
    SCHEME_TOOLKIT_UNFILTERED=1 bin/scheme-desktop run    # the raw stream

The escape hatch is not decoration — it is how each entry below was measured, and
it is what to reach for when something about a start does not add up.

**What is NOT filtered, and will never be:** `possibly unbound variable`,
`Gtk-CRITICAL`, anything from GLib or GTK, every diagnostic from
`check-unbound` and `check-env`, and every error message. Only the three
patterns below are hidden.

## The rule for adding a pattern here

A pattern earns a place only if all four are true, and the answer goes in this
file:

1. **Counted** — how many lines, on what kind of start.
2. **Attributed** — the exact code that emits it, named, not guessed.
3. **Justified** — why it cannot or should not be fixed instead.
4. **Costed** — what a reader loses by not seeing it.

A pattern that fails any of these is a bug to fix, not noise to hide.

---

## 1. `imported module (scheme-toolkit gi) overrides core binding NAME`

**Count.** 36 lines on an ordinary start, 94 on a cold compile, across 30
modules. The names are always the same eight: `for-each`, `map`, `connect`,
`member`, `append`, `max`, `read`, `unsetenv`.

**Attributed.** Guile's module system, when a module imports
`(scheme-toolkit gi)`. That module re-exports the whole G-Golf interface, and
G-Golf's merged generics deliberately shadow those eight core bindings.

**Justified — both halves are load-bearing.**

- The *wholesale* re-export is what lets `gi-import-by-name` resolve type-tag
  names (`int32`, `uint32`, …) in the importing module. `gi.scm` records what a
  hand-picked subset does instead: every import fails with "Unbound variable:
  int32", an error that names nothing to do with the real problem.
- The *merged generics* are what make the element runtime's `(append box child)`
  and friends work at all.

And it cannot be switched off from inside Guile. Measured, each attempt with
identical output:

| attempt | result |
|---|---|
| three different `default-duplicate-binding-handler` lists, including dropping the `warn-override-core` and `warn` entries | unchanged |
| that handler set from a prelude loaded with `-l`, so it is in place before anything compiles | unchanged |
| per-module `#:duplicates` (seven modules already declare it) | unchanged |
| wrapping `current-warning-port`, then `fluid-set!` on it | unchanged |

The warning does not consult the duplicate-binding machinery at any level a
Scheme program can reach, which is why the filter sits on the file descriptor.

**Costed.** Nothing that has ever mattered. The one warning of this shape that
did matter — a name that does not exist at all — is a *different* message
(`possibly unbound variable`), it is not filtered, and it now has a tool of its
own: `bin/scheme-toolkit check-unbound`. Ironically, the noise here is what hid
it: a build that shouts 111 times about the collision we intend is a build whose
warnings nobody reads, and a real one sat unread in the log while the shell
segfaulted — see "an unbound name raised in a signal handler" in
`known-issues.md`.

## 2. `NAME imported from both (scheme-toolkit gi) and (MODULE)`

**Count.** 3 lines on an ordinary start. Seen for `append`, `member`, `filter`.

**Attributed.** The same cause at one remove: a module imports both
`(scheme-toolkit gi)` — which re-exports G-Golf's merged generics — and
`(srfi srfi-1)`, which exports procedures of the same name.

**Justified.** The merge is the intended behaviour (that is what
`merge-generics` is for), and it is the same design decision as entry 1, so it
cannot be fixed without breaking that.

**Costed.** Nothing beyond entry 1's: an accidental collision between *our own*
modules would be reported by this message, and is now not. The class of
collision that actually bit this project — a GI class import at *runtime*
replacing a binding in `(scheme-toolkit reactive)` — is done by
`gi-import-by-name` long after these compile-time checks have run, so this
message never reported it and never could.

## 3. `Json-CRITICAL **: json_object_get_int_member: assertion 'node != NULL' failed`

**Count.** ~14 lines on a start, in bursts — more when the shell is doing things.

**Attributed — to the library, established two ways.**

*From the symbol table:* `libastal-hyprland.so.0.1.0` is the **only** library in
the process that imports `json_object_get_int_member` (`nm -D
--undefined-only`). `astal-apps`, `astal-greet` and `astal-tray` link json-glib
too, but for other calls.

*From the running process:* a breakpoint on `json_object_get_int_member` gives

    #0 json_object_get_int_member (…, member_name="pid")
    #1 astal_hyprland_client_sync (…)     libastal-hyprland …/src/client.c:270
    #2 astal_hyprland_hyprland_init (…)   …/src/hyprland.c:2019
    #3 astal_hyprland_hyprland_get_default ()

— so it fires while AstalHyprland builds its singleton, inside the client sync.
The members that function reads are `client.vala:42-55`: `pid`,
`focusHistoryID`, `fullscreen`, `fullscreenClient`, `workspace` (its `id`) and
`monitor`.

**The count matches, and that is the strongest clue.** `hyprctl -j clients`
reports *n* open windows and a start prints the same *n* CRITICAL lines — 13 and
13 when measured here. One failed read per client.

**What is NOT established.** All six of those members *are* present in this
Hyprland's `hyprctl -j clients`, with real values, so this is not a field the
compositor fails to send. An earlier version of this file said the failing
payloads "must be the IPC event ones": that was an inference from seeing an
event handler near the message, not a measurement, and it is not supported now
that the counts match the client list so exactly. The library, the function and
the member being read are nailed down; *why* that lookup returns NULL belongs
upstream.

**Justified — not fixable from here.** The reads are inside the library; our code
cannot reach them. The three routes that exist are all outside this repository:
rebuild Astal from the checkout at `~/GITE/astal` in case upstream has already
fixed it, report it upstream, or stop using `AstalHyprland` for this (the
project's own direction is `AstalWorkspace` plus `AstalHyprland` only for
extras, but clients and `dispatch` are extras we do use).

**Costed — and this is the entry to be least comfortable with.** It hides a
CRITICAL, which normally means "something is wrong". What is being hidden is a
library assertion on a field it cannot read; the values still arrive for every
payload checked here. The real cost is that the mismatch becomes invisible: if
AstalHyprland's view of a monitor or workspace ever goes wrong, this filter
removes the symptom that would have hinted at it. `SCHEME_TOOLKIT_UNFILTERED=1`
is the answer when Hyprland-related behaviour looks wrong.
