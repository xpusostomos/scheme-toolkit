# scheme-toolkit

A Guile Scheme desktop-shell toolkit built on [Astal](https://github.com/aylur/astal) --
to Scheme what [AGS](https://github.com/Aylur/ags) v3 is to TypeScript.

## Status

| Milestone | What | State |
|---|---|---|
| M0 | GI bootstrap, environment assertions, selective imports | done |
| M0.5 | REPL back door | server + client vendored and loading; the socket wiring is outstanding |
| M1 | Element runtime | done — 19 tests |
| M2 | Reactive core | done — 28 tests |
| M9 | process / time / file / result | done — 28 tests |
| M4 | Astal singletons + feature detection | done — all 12 services live |
| M5 | App shell, layer windows, per-monitor roots | done — `examples/bar.scm` renders |
| M3, M6–M8, M10–M11 | services, config, styling, launcher, tests, packaging | not started |

## Quick start

    bin/scheme-toolkit check-env            # expect ALL GREEN
    bin/scheme-toolkit run examples/bar.scm # a bar on every monitor
    bin/scheme-toolkit guile -s tests/m9.scm

## The two vocabularies

    (make <gtk-label> #:label "x")      ; a static leaf — G-Golf's own API
    (element <gtk-box> child ...)       ; children, signals, reactive props,
                                        ; css, child slots

`element` exists only for what `make` cannot express: nesting children,
`#:on-clicked` signal wiring, a property bound to an accessor, `#:class`/`#:css`,
and `#:slot`. A static leaf needs nothing from it.

There is deliberately no third layer of per-widget shorthands. AGS registers
intrinsic element names because JSX cannot be written without them; in Scheme
`element` already takes any class, so the mechanism has no reason to exist here.

## Layout

    scheme-toolkit/     the library modules
    bin/scheme-toolkit  run / eval / repl / list / check-env
    tools/              check-env.scm and other standalone diagnostics
    examples/           bar.scm — the AGS starter bar in Scheme
    tests/              srfi-64 suites, runnable headless
    docs/               environment.md — the environment traps and measurements

## Read this first

`docs/environment.md`. Three environment details on this machine fail
*silently*: a missing `LD_PRELOAD` makes every layer-shell property a no-op
with no error, and a missing library path makes Astal import as enums only.
Always run through `bin/scheme-toolkit`, which owns that environment.

## Environment the wrapper sets

    LD_LIBRARY_PATH=/usr/local/lib
    GI_TYPELIB_PATH=/usr/local/lib/girepository-1.0
    LD_PRELOAD=libgtk4-layer-shell.so
