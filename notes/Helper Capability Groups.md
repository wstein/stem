---
id: 20260522140000
title: "Helper Capability Groups"
aliases: []
tags: ['security', 'helpers', 'api', 'capabilities']
---

## What

Stem enforces **capability management** for helper functions to reduce Server-Side Template Injection (SSTI) attack surface. Rather than exposing all helpers globally by default, Stem provides a secure minimum and requires explicit opt-in to capability groups for complex data operations.

## Why

In an SSTI attack, an attacker with access to powerful helpers can chain operations to extract internal state or manipulate data structures. By explicitly restricting what helpers are available in a given execution context, Stem raises the barrier for exploitation:

- **Secure by default**: Only essential helpers for output escaping and basic operations are always available
- **Explicit opt-in**: Complex data transformation requires deliberate declaration in code or config
- **Auditable surface**: When a developer enables a capability group, it becomes a visible review flag

This mirrors the principle behind Stem's `allow_elixir_expressions` flag: intentional friction makes dangerous choices visible.

## How

### Capability Groups

Stem provides four helper capability groups:

**`Stem.Helpers.Minimum` (always available)**
- Output escaping: `escape_html`, `escape_json`, `json`, `inspect`
- Safe defaults: `default`
- Essential operations: `lookup`, `join`, `log`

This group is always available and cannot be disabled. It is designed to never expose dangerous operations.

**`Stem.Helpers.Strings`**
- Case conversion: `trim`, `upcase`, `downcase`, `capitalize`
- Text manipulation: `truncate`, `replace`, `take`, `drop`, `slice`, `first`, `reverse`
- Pattern matching: `starts_with`, `ends_with`

Use when templates need to transform text without exposing collection operations.

**`Stem.Helpers.Collections`**
- Filtering: `filter`, `compact`, `uniq`
- Sorting: `sort`, `sort_by`
- Grouping: `group_by`
- Transformation: `map`
- Slicing: `take`, `drop`, `slice`, `first`
- Other: `flatten`, `reverse`

⚠️ **Security note**: These helpers enable powerful data operations. An attacker with access to these could chain operations to extract internal states. Only enable for trusted template sources.

**`Stem.Helpers.Predicates`**
- Boolean tests: `contains`, `empty?`, `present?`

Use in `{{#if}}` blocks and with the `filter` helper for advanced predicates.

### Loading Capability Groups

#### Runtime API

Pass `:helper_groups` to `eval_string/3` or `eval_file/3`:

```elixir
# Minimal: only Stem.Helpers.Minimum available
Stem.Unsafe.eval_string("{{name |> trim}}", assigns: [name: "Nina"])
# Error: trim is not available

# Explicit opt-in for Strings
Stem.Unsafe.eval_string(
  "{{name |> trim |> upcase}}",
  assigns: [name: "nina"],
  helper_groups: [Stem.Helpers.Strings]
)
#=> "NINA"

# Multiple groups
Stem.Unsafe.eval_string(
  "{{items |> map(author) |> take(5)}}",
  assigns: [items: books],
  helper_groups: [Stem.Helpers.Collections, Stem.Helpers.Strings]
)
```

#### Configuration Default

Pin approved helper groups in `.stem.config.json`:

```json
{
  "helper_groups": "Stem.Helpers.Strings,Stem.Helpers.Collections"
}
```

Format: comma-separated module names (no quotes around individual names).

### Custom Helpers

Custom helpers can be registered globally via `Stem.Helpers.register/2` or passed per-call via the `helpers:` option. These are always available regardless of capability groups:

```elixir
Stem.Helpers.register(:my_custom, fn [value], _ctx -> transform(value) end)

Stem.Unsafe.eval_string(
  "{{value |> my_custom}}",
  assigns: [value: data],
  helpers: [my_other: fn [v], _ -> v end]  # Per-call custom helper
)
```

## Migration Path

**Existing code**: If your application currently uses all the helpers from `Stem.Helpers`, they remain available in full at the module level. The capability system is opt-in for runtime evaluation.

**To adopt capability groups**:

1. Identify which templates need which operations
2. Add `:helper_groups` to `eval_string/3`/`eval_file/3` calls
3. Pin defaults in `.stem.config.json` to reduce boilerplate
4. For compile-time templates, no changes needed — the compiler inlines all operations into Elixir AST at build time

## Links

- [[Execution Modes Overview]] - Understand allow_elixir_expressions alongside capability groups
- [[Compile-Time-Only Security Model]] - Why compile-time templates are safer
- [[Runtime Evaluation and Sandboxing]] - Runtime API details
