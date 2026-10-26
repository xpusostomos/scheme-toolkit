# scheme-toolkit

A Guile Scheme desktop-shell toolkit built on [Astal](https://github.com/aylur/astal) --
to Scheme what [AGS](https://github.com/Aylur/ags) v3 is to TypeScript.

**Status: M0 complete.** GI bootstrap, environment assertions, selective
imports and the `check-env` diagnostic are working. See `AGENTS.md` for the
full plan.

## Quick start

    bin/scheme-toolkit check-env      # diagnose the environment; expect ALL GREEN

## Layout

    scheme-toolkit/     the library modules
    bin/scheme-toolkit  run / eval / repl / list / check-env
    tools/              check-env.scm and other standalone diagnostics
    docs/               environment.md -- the traps, and the measurements
    tests/              srfi-64 suites
    examples/           minimal shells proving each layer

## The one thing to read first

`docs/environment.md`. Three environment details on this machine fail
*silently* -- a missing `LD_PRELOAD` makes every layer-shell property a no-op
with no error, and a missing library path makes Astal import as enums only.
`check-env` asserts all of them.

## Environment

The wrapper script owns the environment, because it is load-bearing:

    LD_LIBRARY_PATH=/usr/local/lib
    GI_TYPELIB_PATH=/usr/local/lib/girepository-1.0
    LD_PRELOAD=libgtk4-layer-shell.so

Always run through `bin/scheme-toolkit` rather than calling `guile` directly.
