---
id: 20260521131300
aliases: []
tags: [extensibility, macros]
---
Stem resolves helpers and partials through a combination of compile-time expansion and a runtime registry, allowing for efficient Elixir integration.

## What

Helpers are functions registered in `Stem.Helpers` or passed in the `helpers` assign; they are invoked when a tag's first token is a name followed by arguments. Partials (`{{> name}}`) are expanded inline by the parser at compile time. Because that expansion is structural rather than runtime-dispatched, nested partials inherit the surrounding assign scope, and named `{{#region slot}}...{{/region}}` blocks can be rendered later with `{{yield slot}}` inside those expanded partials. Stem ships with a robust set of built-in pipeline-friendly helpers like `trim`, `upcase`, `map`, and `filter`.

## Why

Inlining partials at compile time removes recursive calls at runtime and allows the compiler to optimize the block as a single unit. Because `{{ ... }}` output is now HTML escaped by default (secure-by-default), helpers and pipelines provide the explicit, developer-controlled mechanism to apply safe formatting without disabling XSS protection.

## How

Register global helpers with `Stem.Helpers.register/2` or pass local helpers as a map. Provide partials as a map to `Stem.function_from_string/5`. Use named regions and yields when wrappers need explicit slots, and use nested partials when simple shared scope is enough. Use the pipe operator to chain built-in or custom helpers to explicitly shape output.

## Runtime Templates

Runtime templates default to permissive mode, so ordinary Elixir expressions can appear directly inside a tag when you want that escape hatch:

```elixir
import Stem

Stem.Unsafe.eval_string("{{1 + 2}}")
#=> "3"

Stem.Unsafe.eval_string("{{String.upcase(name)}}", assigns: [name: "nina"])
#=> "NINA"
```

Use `mode: :safe` when you want to block the arbitrary Elixir fallback path and keep runtime templates limited to structured Stem expressions.

## Links

- [[Handlebars Expression Resolution]] - How helper calls are distinguished from variables.
- [[Native AST Compilation Pipeline]] - Where partial expansion occurs.
- [[Handlebars Truthiness Semantics]] - How helper return values are interpreted in blocks.
