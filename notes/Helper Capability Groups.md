---
id: 20260522140000
title: "Transformer Capability Groups"
aliases: []
tags: ['security', 'transformers', 'api', 'capabilities']
---

## What

Stem enforces **capability management** for transformer functions to reduce Server-Side Template Injection (SSTI) attack surface. Rather than exposing all transformers globally by default, Stem provides a secure minimum and requires explicit opt-in to capability groups for complex data operations.

## Why

In an SSTI attack, an attacker with access to powerful helpers can chain operations to extract internal state or manipulate data structures. By explicitly restricting what helpers are available in a given execution context, Stem raises the barrier for exploitation:

- **Secure by default**: Only essential helpers for output escaping and basic operations are always available
- **Explicit opt-in**: Complex data transformation requires deliberate declaration in code or config
- **Auditable surface**: When a developer enables a capability group, it becomes a visible review flag

This mirrors the principle behind Stem's `allow_elixir_expressions` flag: intentional friction makes dangerous choices visible.

## How

### Capability Groups

Stem provides four helper capability groups:

**`Stem.Transformers.Minimum` (always available)**
- Output escaping: `escape_html`, `escape_json`, `json`, `inspect`
- Safe defaults: `default`
- Essential operations: `lookup`, `join`, `log`

This group is always available and cannot be disabled. It is designed to never expose dangerous operations.

**`Stem.Transformers.Strings`**
- Case conversion: `trim`, `upcase`, `downcase`, `capitalize`
- Text manipulation: `truncate`, `replace`, `take`, `drop`, `slice`, `first`, `reverse`
- Pattern matching: `starts_with`, `ends_with`

Use when templates need to transform text without exposing collection operations.

**`Stem.Transformers.Collections`**
- Filtering: `filter`, `compact`, `uniq`
- Sorting: `sort`, `sort_by`
- Grouping: `group_by`
- Transformation: `map`
- Slicing: `take`, `drop`, `slice`, `first`
- Other: `flatten`, `reverse`

⚠️ **Security note**: These helpers enable powerful data operations. An attacker with access to these could chain operations to extract internal states. Only enable for trusted template sources.

**`Stem.Transformers.Predicates`**
- Boolean tests: `contains`, `empty?`, `present?`

Use in `{{#if}}` blocks and with the `filter` helper for advanced predicates.

### Loading Capability Groups

#### Runtime API

Pass `transformers:` (a flat function map) to `eval_string/3` or `eval_file/3`. Call `.all()` on each group and merge with `Map.merge/2`:

```elixir
# Minimal: only built-ins available (no transformers: key needed)
Stem.Unsafe.eval_string("{{name |> trim}}", assigns: [name: "Nina"])
# Error: trim is not a built-in — pass Stem.Transformers.Strings.all()

# Explicit opt-in for Strings
Stem.Unsafe.eval_string(
  "{{name |> trim |> upcase}}",
  assigns: [name: "nina"],
  transformers: Stem.Transformers.Strings.all()
)
#=> "NINA"

# Multiple groups — caller merges explicitly
Stem.Unsafe.eval_string(
  "{{items |> map(author) |> take(5)}}",
  assigns: [items: books],
  transformers: Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
)
```

#### Configuration Default

Pin approved helper groups in `.stem.config.json`:

```json
{
  "transformers": "Stem.Transformers.Strings,Stem.Transformers.Collections"
}
```

Format: comma-separated module names (no quotes around individual names).

### Custom Transformers

Custom transformers can be registered globally via `Stem.Transformers.register/2` or passed per-call by merging into the `transformers:` map. These are always available regardless of built-in groups:

```elixir
Stem.Transformers.register(:my_custom, fn [value], _ctx -> transform(value) end)

custom = %{"my_other" => fn [v], _ -> v end}

Stem.Unsafe.eval_string(
  "{{value |> my_custom |> my_other}}",
  assigns: [value: data],
  transformers: Map.merge(Stem.Transformers.Strings.all(), custom)
)
```

## Migration Path

**Existing code**: If your application currently uses all the helpers from `Stem.Transformers`, they remain available in full at the module level. The capability system is opt-in for runtime evaluation.

**To adopt capability groups**:

1. Identify which templates need which operations
2. Add `transformers: Stem.Transformers.SomeGroup.all()` (or `Map.merge/2` for multiple groups) to `eval_string/3`/`eval_file/3` calls
3. Pin defaults in `.stem.config.json` to reduce boilerplate
4. For compile-time templates, no changes needed — the compiler inlines all operations into Elixir AST at build time

## Links

- [[Execution Modes Overview]] - Understand allow_elixir_expressions alongside capability groups
- [[Compile-Time-Only Security Model]] - Why compile-time templates are safer
- [[Runtime Evaluation and Sandboxing]] - Runtime API details
