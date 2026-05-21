---
id: 20260521120200
aliases: []
tags: [compiler, semantics]
---
`Stem.Expression` maps the contents of a tag onto Elixir using fixed Handlebars conventions, so the same source resolves predictably depending on context.

## What

A bare identifier resolves to an assign (`@name`) at the top level and to the current item (`current.name`) inside `{{#each}}`.
`this`, `@index`, and `@key` map to the loop bindings; `../name` strips parent segments to a top-level assign; and a word followed by arguments is a helper call routed through `Stem.Helpers.invoke/3`.
Anything else is treated as an Elixir expression with its identifiers rewritten to assigns.

## Why

Handlebars is ambiguous: `{{a b}}` means "helper `a` with argument `b`", not the expression `a b`.
A single, documented resolution order keeps templates predictable and matches author expectations.

## How

Read `Stem.Expression.translate/2` as the authority for how a tag becomes Elixir.
Remember that any space-separated tag whose first token looks like a name is interpreted as a helper call, so wrap genuine expressions in operators or parentheses when that is not intended.

## Links

- [[Native AST Compilation Pipeline]] - Where translation sits in the pipeline.
- [[Template Variable Hygiene]] - Why the emitted variables resolve at runtime.
