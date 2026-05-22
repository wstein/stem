---
id: 20260522140000
title: "Transformer Capability Groups"
aliases: []
tags: ['security', 'transformers', 'api', 'capabilities']
---

## What

Stem enforces **capability management** for transformer functions to reduce Server-Side Template Injection (SSTI) attack surface. Rather than exposing all transformers globally, Stem provides a secure minimum and requires explicit opt-in to capability groups for complex data operations.

## Why

An SSTI attacker with access to powerful helpers can chain operations to extract internal state or manipulate data. Restricting available helpers per execution context raises the exploitation barrier:

- **Secure by default**: only essential output-escaping and basic helpers are always available
- **Explicit opt-in**: complex data transformation must be deliberately declared in code or config
- **Auditable surface**: enabling a capability group is a visible review flag

This mirrors the `allow_elixir_expressions` flag: intentional friction makes dangerous choices visible.

## How

### Capability Groups

- **`Stem.Transformers.Minimum`** (always on, cannot be disabled): `escape_html`, `escape_json`, `json`, `inspect`, `default`, `lookup`, `join`, `log`. Never exposes dangerous operations.
- **`Stem.Transformers.Strings`**: `trim`, `upcase`, `downcase`, `capitalize`, `truncate`, `replace`, `take`, `drop`, `slice`, `first`, `reverse`, `starts_with`, `ends_with`.
- **`Stem.Transformers.Collections`**: `map`, `filter`, `compact`, `uniq`, `sort`, `sort_by`, `group_by`, `take`, `drop`, `slice`, `first`, `flatten`, `reverse`. ⚠️ Powerful — an attacker could chain these to extract internal state; enable only for trusted sources.
- **`Stem.Transformers.Predicates`**: `contains`, `empty?`, `present?`. For `{{#if}}` blocks and `filter`.

### Loading groups

Runtime APIs take a flat `transformers:` function map; call `.all()` on each group and `Map.merge/2` to combine:

```elixir
# Explicit opt-in for Strings
Stem.Unsafe.eval_string("{{name |> trim |> upcase}}",
  assigns: [name: "nina"],
  transformers: Stem.Transformers.Strings.all())

# Multiple groups
Stem.Unsafe.eval_string("{{items |> map(author) |> take(5)}}",
  assigns: [items: books],
  transformers: Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all()))
```

Pin defaults in `.stem.config.json` as comma-separated module names:

```json
{ "transformers": "Stem.Transformers.Strings,Stem.Transformers.Collections" }
```

### Custom transformers

Register globally with `Stem.Transformers.register/2`, or pass per-call by merging into the `transformers:` map. Custom entries are available regardless of built-in groups.

## Migration

Module-level access to all `Stem.Transformers` helpers is unchanged; the capability system is opt-in for runtime eval. To adopt: identify which templates need which operations, add `transformers: SomeGroup.all()` (or `Map.merge/2`) to `eval_string/3`/`eval_file/3`, and pin defaults in `.stem.config.json`. Compile-time templates need no changes — the compiler inlines operations into AST at build time.

## Links

- [[Execution Modes Overview]] - allow_elixir_expressions alongside capability groups
- [[Compile-Time-Only Security Model]] - Why compile-time templates are safer
- [[Runtime Evaluation and Sandboxing]] - Runtime API details
- [[Universal Architecture Principles]] - Capability management as a portable design principle
