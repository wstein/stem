---
id: 20260521131300
aliases: []
tags: [extensibility, macros]
---
Stem resolves transformers and partials through a combination of compile-time expansion and a runtime registry, allowing for efficient Elixir integration.

## What

Transformers are functions registered in `Stem.Transformers` or passed via the `transformers:` option as a flat string-keyed map; they are invoked when a tag's first token is a name followed by arguments. Partials (`{{> name}}`) are expanded inline by the parser at compile time. Because that expansion is structural rather than runtime-dispatched, nested partials inherit the surrounding assign scope, and named `{{#region slot}}...{{/region}}` blocks can be rendered later with `{{yield slot}}` inside those expanded partials. Stem ships with a robust set of built-in pipeline-friendly transformers like `trim`, `upcase`, `map`, and `filter`.

Partials accept Handlebars-style arguments: `{{> name context}}` renders the partial with `context` as its scope, and `{{> name key=value ...}}` passes hash arguments that become assigns inside the partial (hash keys win over context keys). The two forms combine (`{{> name user role="admin"}}`). The first positional token is the context; any others raise a parse error. Argument values are parsed with the same expression grammar as helper arguments and evaluated in the caller's scope before the partial renders.

## Partial-argument scoping

A partial without arguments still expands inline and shares the caller's scope and `{{#each}}` context — this path is unchanged. When arguments are present, the parser wraps the inlined partial nodes in a `:partial_scope` AST node, and the compiler lowers it to a closure that rebinds `assigns` to `Stem.Runtime.partial_scope(base, hash)` so the rebinding never leaks to sibling nodes. The portable bytecode backend and the native Rust compiler lower the same node to a `:scope` instruction with byte-identical wire (see [[Portable Stem Bytecode]]), so partial arguments render identically in the browser playground. The `base` is the context value when given; otherwise it is the caller's current data context (the `{{#each}}` item when inside a loop, else the caller's assigns). The partial body always compiles in a fresh, non-each scope (`in_each: false`, no inherited block-param locals), so bare names resolve against the rebound `assigns`. `Stem.Runtime.partial_scope/2` coerces the base to a map (maps pass through, keyword lists convert, anything else becomes `%{}`) and merges the atom-keyed hash on top. A scalar or plain-list context therefore yields an empty keyed scope. Known v1 limitation: `{{../name}}` inside an arg'd partial reaches the rebound scope, not the original caller, because `assigns` is the rebinding target.

## Why

Inlining partials at compile time removes recursive calls at runtime and allows the compiler to optimize the block as a single unit. Because `{{ ... }}` output is now HTML escaped by default (secure-by-default), transformers and pipelines provide the explicit, developer-controlled mechanism to apply safe formatting without disabling XSS protection.

## How

Register global transformers with `Stem.Transformers.register/2` or pass local transformers as a `%{name => fn}` map via `transformers:`. Provide partials as a map to `Stem.function_from_string/5`. Use named regions and yields when wrappers need explicit slots, and use nested partials when simple shared scope is enough. Use the pipe operator to chain built-in or custom transformers to explicitly shape output.

## Runtime Templates

Runtime templates default to `allow_elixir_expressions: false`, so only structured Stem expressions (variable paths, helper calls, literals, pipelines) are allowed inside tags. Pass `allow_elixir_expressions: true` to opt in to arbitrary Elixir expressions when the template source is fully trusted:

```elixir
import Stem

Stem.Unsafe.eval_string("{{name}}", assigns: [name: "nina"])
#=> "nina"

Stem.Unsafe.eval_string("{{a + b}}", [assigns: [a: 1, b: 2]], allow_elixir_expressions: true)
#=> "3"
```

## Links

- [[Handlebars Expression Resolution]] - How helper calls are distinguished from variables.
- [[Native AST Compilation Pipeline]] - Where partial expansion occurs.
- [[Handlebars Truthiness Semantics]] - How helper return values are interpreted in blocks.
