---
id: 20260522200003
title: "CI Security Gates"
aliases:
  - mix stem.audit
  - Security Audit Task
tags:
  - security
  - ci-cd
  - history
---

## What

> **Superseded (2026-05-25).** `mix stem.audit` and the `allow_elixir_expressions`
> flag it policed have been removed. There is no longer an arbitrary-Elixir
> escape hatch to guard, so no CI gate is needed.

Historically, `mix stem.audit` was a static-analysis task that scanned config
files for `allow_elixir_expressions: true` and failed the build (exit code 1) to
stop that SSTI escape hatch from drifting into production.

## Why it was removed

The escape hatch was non-portable (BEAM-only `Code.eval_quoted`; the native
engine has no equivalent) and a footgun even when guarded. Templates now accept
only structured Stem syntax — assigns, dotted paths, literals, and transformer
calls — so arbitrary-expression SSTI is impossible by construction and the gate
became unnecessary. See [[Runtime Evaluation and Sandboxing]].

## Links

- [[Compile-Time-Only Security Model]] - The security principle this gate enforced
- [[Runtime Evaluation and Sandboxing]] - Current structured-only model
- [[Helper Capability Groups]] - The companion audit signal for Collections loading
