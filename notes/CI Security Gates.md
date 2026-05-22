---
id: 20260522200003
title: "CI Security Gates"
aliases:
  - mix stem.audit
  - Security Audit Task
tags:
  - security
  - ci-cd
  - tooling
---

## What

`mix stem.audit` is a static analysis task that scans configuration files for
`allow_elixir_expressions: true` and **fails the build** (exit code 1) if any
occurrences are found. It is designed to run in CI/CD pipelines as an
enforcement gate for the `allow_elixir_expressions` security boundary.

## Why

It is too easy for a `allow_elixir_expressions: true` setting added for local
debugging to be accidentally committed and deployed to production. Once in
production, it reopens the Server-Side Template Injection (SSTI) attack surface.
An automated gate in CI prevents this class of configuration drift without
requiring manual code review to catch it.

This mirrors the principle that the cost of misuse should be high and visible —
the same principle behind the `Stem.Unsafe` namespace.

## How

### CI setup

```yaml
# .github/workflows/ci.yml (or equivalent)
- run: mix stem.audit
```

By default, `mix stem.audit` scans `config/prod.exs` and `config/runtime.exs`.
Non-existent files are skipped silently.

### Custom paths

```sh
mix stem.audit --paths config/prod.exs --paths config/releases.exs
# or using positional args
mix stem.audit config/prod.exs config/runtime.exs config/releases.exs
```

### Output

On a clean run:

```
Stem audit passed — no insecure settings found.
```

On a violation:

```
config/prod.exs:12: [stem.audit] allow_elixir_expressions: true must not be
used in production configuration.
  config :stem, allow_elixir_expressions: true

** (Mix) Stem audit failed: 1 violation(s) found.
Remove allow_elixir_expressions: true from production config files.
```

### What is detected

The pattern `allow_elixir_expressions\s*:\s*true` (case-sensitive, regex) on any
line of any scanned file. Commented-out lines are still flagged — remove or
restructure them rather than commenting.

### What is NOT detected

The task is a fast text scan, not a semantic Elixir parser. It cannot detect
`allow_elixir_expressions: true` set programmatically at runtime (e.g., passed
as an argument in code). For those cases, code review and `Stem.Unsafe` namespace
friction are the defences.

## Links

- [[Compile-Time-Only Security Model]] - The security principle this gate enforces
- [[Runtime Evaluation and Sandboxing]] - Context for when allow_elixir_expressions is used
- [[Helper Capability Groups]] - The companion audit signal for Collections loading
