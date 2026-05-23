---
id: 20260521120200
aliases: []
tags: [compiler, semantics]
---
`Stem.Expression` maps the contents of a tag onto Elixir using fixed Handlebars conventions, so the same source resolves predictably depending on context.

## What

A bare identifier resolves to an assign at the top level and to the current item inside `{{#each}}`. Keys that are not valid identifiers — dashes, spaces, dots, leading digits, or reserved words — are written as **bracketed literal segments**: `{{[first-name]}}`, `{{user.[first-name]}}`, `{{[a.b]}}`. Bare names may also use any leading letter case (`{{Item1}}`). Stem supports nested subexpressions `(helper arg)` and Elixir-style helper pipelines (`lhs |> helper(a, b)`). Anything else is treated as an Elixir expression with its identifiers rewritten to assigns.

## Why

Handlebars is inherently ambiguous: `{{a b}}` means "helper a with argument b", not the expression `a b`. A single, documented resolution order keeps templates predictable. Supporting pipelines and subexpressions allows templates to chain transformations declaratively without escalating into arbitrary, unsafe Elixir code.

## How

Read `Stem.Expression.translate/2` as the authority for how a tag becomes Elixir. Use parentheses for nested helper evaluation, and use the pipe operator to chain built-in or custom helpers. Wrap genuine Elixir expressions in operators or parentheses when a helper call is not intended.

## Links

- [[Native AST Compilation Pipeline]] - Where translation sits in the pipeline.
- [[Template Variable Hygiene]] - Why the emitted variables resolve at runtime.
- [[Literal Variable Keys and Anonymous Params]] - Bracket literal keys and how they lower.
