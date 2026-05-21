---
id: 20260521120300
aliases: []
tags: [compiler, macros]
---
The compiler emits every template-introduced variable with a `nil` context so that block scaffolding built with `quote` unifies with variables parsed from embedded expression source.

## What

Block structures (`if`, `each`, `with`) are built with `quote`, while tag contents are parsed with `Code.string_to_quoted!/2`.
Variables from parsed source carry a `nil` context, so the compiler creates `assigns`, `helpers`, `current`, `stem_key`, `stem_index`, and `this` as `nil`-context variables (`Macro.var(name, nil)`) rather than hygienic ones.

## Why

If the loop variable `current` were hygienic but the expression `current.name` were parsed with a `nil` context, the two would be different variables and the body would not see the binding.
Aligning the context makes the scaffolding and the embedded expressions share the same bindings.

## How

When generating new bindings a template body can reference, create them with a `nil` context and mark them `generated: true` to avoid unused-variable warnings.
Rewrite `@assign` references to `Stem.Runtime.fetch_assign!/3` using the same `nil`-context `assigns` variable that the generated function receives.

## Links

- [[Native AST Compilation Pipeline]] - The compiler stage that applies this rule.
- [[Handlebars Expression Resolution]] - The source of the parsed variables.
