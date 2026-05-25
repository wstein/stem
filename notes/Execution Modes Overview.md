---
id: 20260522131203
aliases: []
tags: ['security', 'execution-modes', 'architecture']
---

## Overview

> **Updated (2026-05-25).** Stem no longer has two execution modes. The
> `allow_elixir_expressions` flag was removed; templates are always
> structured-only.

Templates accept only structured Stem syntax — assigns, dotted paths, literals,
and transformer calls. An expression the parser does not recognise (e.g.
`{{a + b}}`) raises `Stem.SyntaxError` at parse time; there is no opt-in to
arbitrary Elixir.

## Why

- **Portable**: the language is identical on the BEAM and the native engine,
  which has no Elixir runtime.
- **Secure by construction**: arbitrary-expression SSTI is impossible — there is
  no flag to misconfigure.
- **Strict separation**: logic that needs more than a transformer call belongs
  in a registered helper or a backend service, not the template.

The remaining trust boundary is the *template source* itself, which is why
runtime evaluation lives under `Stem.Unsafe`.

## Links

- [[Compile-Time-Only Security Model]] — How compile-time templates are intrinsically safe
- [[Project Configuration Defaults]] — How to configure defaults via `.stem.config.json`
- [[Runtime Evaluation and Sandboxing]] — The runtime API and its trust boundary
