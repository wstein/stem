---
id: 20260521210600
aliases: [Truthiness, Handlebars Truthiness]
tags: ['semantics', 'logic', 'v0-2-0']
---

Block conditionals in Stem (v0.2.0+) follow **Handlebars truthiness rules**: `false`, `nil`, `0`, `""`, `[]`, and `{}` (empty map) are falsey. All other values are truthy.

## What

In `{{#if expr}}`, `{{#unless expr}}`, `{{#each expr}}`, and `{{#with expr}}`, falsey values trigger the `{{else}}` branch or skip the block entirely.

**Falsey values:** `false`, `nil`, `0` (int/float), `""`, `[]`, `%{}` (empty map). All other values are truthy, including `1`, `"0"`, `" "`, `[nil]`, `%{a: nil}`.

## Why

Handlebars truthiness is the standard in frontend template languages and aligns with JavaScript conventions, improving familiarity for frontend developers.

It also creates **cognitive dissonance for Elixir/Erlang developers**, where everything except `false`/`nil` is truthy. A backend engineer can pass an empty list expecting a zero-state UI, only for `{{#if list}}` to silently skip it. This is a deliberate, documented tradeoff in favor of frontend familiarity.

## Design decision: surface coercions, do not add a strict mode

To keep the backend engineer's mental model aligned with template output, Stem makes the coercion **visible** rather than forbidding it:

- `warn_on_falsy_coercion` logs a warning whenever an Elixir-truthy value (`0`, `""`, `[]`, `%{}`) is coerced to false. Its compile default falls back to `Application.get_env(:stem, :warn_on_falsy_coercion, false)`, so projects can switch it on for development/test with one line: `config :stem, warn_on_falsy_coercion: true`.
- A hard "strict truthiness" compile mode (erroring on coercion) was **considered and rejected**: it would fork the language into two dialects and add compiler complexity, while the warning delivers ~all of the visibility benefit at a fraction of the cost. Use explicit predicates (`{{#if (present? list)}}`) when you need Elixir-style semantics.

## How

```handlebars
{{#if 0}}t{{else}}f{{/if}}     → "f"
{{#if ""}}t{{else}}f{{/if}}    → "f"
{{#if []}}t{{else}}f{{/if}}    → "f"
{{#if 1}}t{{else}}f{{/if}}     → "t"
{{#each []}}x{{else}}empty{{/each}}  → "empty"
{{#with nil}}...{{else}}missing{{/with}}  → "missing"
```

## Breaking Change (v0.1 → v0.2)

Breaking change from v0.1 (Elixir truthiness: only `false`/`nil` falsey). Migration:

- Explicit comparisons: `{{#if count > 0}}` instead of `{{#if count}}`
- Predicate helpers: `{{#if (present? list)}}` to check for non-empty
- Enable `warn_on_falsy_coercion` in dev/test to find coercions during rollout


## Links

- [[Handlebars-Inspired Philosophy]] - Why Stem targets Handlebars conventions
- [[Iteration and Context Scoping]] - How truthiness affects each/with blocks
- [[Transformer Capability Groups]] - `present?`/`empty?` predicates for explicit checks
