# Known issues

## `create-poll` bound to a widget property fails

**Symptom.** This works:

```scheme
(define clock (create-poll 1000 '("date" "+%H:%M")))
(subscribe clock (lambda () (display (peek clock))))
;; => fires, prints the time
```

and this works:

```scheme
(element <gtk-label> #:label (car (create-state "x")))   ; any accessor
```

and this works:

```scheme
(create-poll 1000 '("date"))                             ; created, not bound
```

but this fails:

```scheme
(define clock (create-poll 1000 '("date" "+%H:%M")))
(element <gtk-label> #:label clock)
```

with

    ERROR: In procedure string->pointer:
    Wrong type argument in position 1 (expecting string): #<<accessor> ...>

and a backtrace entirely inside G-Golf's `hl-api/function.scm` — no frame from
this project at all, so the failing call is a GI call receiving an accessor
where a string was expected.

**What is ruled out.** The failure is not in `create-poll` itself (it works
standalone), not in accessor binding generally (a `create-state` accessor binds
fine), and not in the timer (instrumenting `create-poll`'s `run` and `start!`
produced no output, so neither is reached before the error). It occurs
somewhere between constructing the poll accessor and `element` reading it.

**Why it is not blocking.** D1's clock is a static string by design — the plan
says so explicitly — and a live clock is D2. Nothing else in the bar depends on
a poll. `examples/bar.scm` uses `clock-text` and notes the substitution.

**Next step.** Bisect inside `element` with a poll accessor: check whether
`(peek acc)` is the failing call, and whether the poll accessor differs from a
`create-state` accessor in a slot that `element` inspects. Both go through
`create-accessor`, so the difference is in `#:subscribe-fn` — and since
`subscribe` is not reached, look at `version-fn` and at anything `element` reads
before the subscribe loop.

## The REPL back door has no socket wiring

`(scheme-toolkit repl coop-server)` and `(scheme-toolkit repl client)` are
vendored from schemacs and load, but nothing yet calls `start-repl!`:
`run-shell` resolves `(scheme-toolkit repl)` at run time and calls it if
present, and there is no such module yet.

The client still speaks schemacs's discovery protocol — a TCP port written to
`$XDG_RUNTIME_DIR/schemacs-repl-<pid>.port` — rather than the Unix socket named
by instance this project wants. `client.scm` needs `repl-port-files` and
`repl-connect` adapted to `.sock` files under `$XDG_RUNTIME_DIR/scheme-toolkit/`.
