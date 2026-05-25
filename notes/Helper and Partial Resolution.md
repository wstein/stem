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

A no-arg partial expands inline and shares the caller's scope and `{{#each}}` context (unchanged). With arguments, the parser wraps the inlined nodes in a `:partial_scope` node; the compiler lowers it to a closure that rebinds `assigns` to `Stem.Runtime.partial_scope(base, hash)`, so the rebinding never leaks to siblings. The bytecode backend and native Rust compiler lower it to a byte-identical `:scope` instruction (see [[Portable Stem Bytecode]]), so it renders the same in the playground. `base` is the context when given, else the caller's current data context (the `{{#each}}` item, or the caller's assigns). The body compiles in a fresh non-each scope, so bare names resolve against the rebound `assigns`. `partial_scope/2` coerces `base` to a map and merges the atom-keyed hash on top, so a scalar/list context yields an empty keyed scope. Known v1 limitation: `{{../name}}` inside an arg'd partial reaches the rebound scope, not the original caller.

## Why

Inlining partials at compile time removes recursive calls at runtime and allows the compiler to optimize the block as a single unit. Because `{{ ... }}` output is now HTML escaped by default (secure-by-default), transformers and pipelines provide the explicit, developer-controlled mechanism to apply safe formatting without disabling XSS protection.

## How

Register global transformers with `Stem.Transformers.register/2` or pass local transformers as a `%{name => fn}` map via `transformers:`. Provide partials as a map to `Stem.function_from_string/5`. Use named regions and yields when wrappers need explicit slots, and use nested partials when simple shared scope is enough. Use the pipe operator to chain built-in or custom transformers to explicitly shape output.

## Runtime Templates

Runtime templates accept only structured Stem expressions (variable paths, helper calls, literals, pipelines) inside tags. There is no arbitrary-Elixir escape hatch; an unrecognised expression raises `Stem.SyntaxError`:

```elixir
import Stem

Stem.Unsafe.eval_string("{{name}}", assigns: [name: "nina"])
#=> "nina"

Stem.Unsafe.eval_string("{{name | upcase}}", assigns: [name: "nina"], transformers: Stem.Transformers.Strings.all())
#=> "NINA"
```

## Links

- [[Handlebars Expression Resolution]] - How helper calls are distinguished from variables.
- [[Native AST Compilation Pipeline]] - Where partial expansion occurs.
- [[Handlebars Truthiness Semantics]] - How helper return values are interpreted in blocks.
