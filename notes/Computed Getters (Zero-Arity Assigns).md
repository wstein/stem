---
id: 20260523030741
title: "Computed Getters (Zero-Arity Assigns)"
aliases: []
tags: ['design', 'runtime', 'rationale', 'history']
---

## What

> **Removed (2026-05-25).** Computed getters are gone from both backends. A
> zero-arity function bound as an assign is no longer auto-invoked, and the
> native `{"$getter": "name"}` host hook (`GetterResolver`, `handle_with_getters`)
> is removed.

Historically, an assign whose value was a zero-arity function (BEAM) — or a
field valued `{"$getter": "name"}` resolved by an embedder hook (native) — was
computed lazily at render time, an ST4-style getter that stayed declarative
because the template could not pass arguments.

## Why it was removed

Getters were a non-portable, backend-specific convenience: JSON/CLI/native data
cannot carry functions, so the feature existed only on the BEAM (closures) with
a parallel host-hook on the native side, neither covered by the conformance
corpus. They also pushed lazy logic into the data layer. Computing values in the
controller and passing them as plain assigns is portable, simpler, and keeps the
model-view boundary crisp (see [[Strict Model-View Separation and State Isolation]]).

## Links

- [[Strict Model-View Separation and State Isolation]] - The boundary getters straddled.
- [[Handlebars Expression Resolution]] - How `{{name}}`/`{{a.b}}` resolve now (plain values).
- [[Native Backend Strategy]] - The host-hook surface that no longer includes getters.
