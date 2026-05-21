---
id: 20260521131200
aliases: [Escaping]
tags: [security, html]
---
Stem does not perform automatic HTML escaping; `{{ expression }}` renders the expression result directly as a string.

## What

Only `{{ expression }}` is supported for expression output.
Any output transformation, including sanitization and escaping, must be done explicitly through helper functions or ordinary Elixir function calls used in expressions.

## Why

Keeping the rendering model to one expression form removes ambiguous output modes and keeps template semantics simple.
Explicit transformation avoids hidden behavior and makes security-sensitive formatting decisions visible at the call site.

## How

Use helpers for output shaping, for example `{{escape_html body}}`.
If a helper is not needed globally, call local functions through expression-compatible helper wrappers.
Treat all user-provided content as untrusted and enforce escaping/sanitization where the value is produced.

## Links

- [[Helper and Partial Resolution]] - Where custom transformation logic is integrated.
- [[Compile-Time-Only Security Model]] - The broader security context of Stem.
