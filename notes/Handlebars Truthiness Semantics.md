---
id: 20260521210600
aliases: [Truthiness, Handlebars Truthiness]
tags: [semantics, logic, v0.2.0]
---

Block conditionals in Stem (v0.2.0+) follow **Handlebars truthiness rules**: `false`, `nil`, `0`, `""`, `[]`, and `{}` (empty map) are falsey. All other values are truthy.

## What

In `{{#if expr}}`, `{{#unless expr}}`, `{{#each expr}}`, and `{{#with expr}}`, falsey values trigger the `{{else}}` branch or skip the block entirely.

**Falsey values:**
- `false` - boolean false
- `nil` - Elixir null
- `0` - zero (integer or float)
- `""` - empty string
- `[]` - empty list
- `%{}` - empty map

All other values are truthy, including `1`, `"0"`, `" "`, `[nil]`, `%{a: nil}`.

## Why

Handlebars truthiness is the standard in frontend template languages and aligns with JavaScript conventions. This improves developer familiarity and reduces cognitive load when working with Handlebars-inspired templates.

## How

**Conditionals trigger else on falsey values:**
```handlebars
{{#if 0}}truthy{{else}}falsey{{/if}}        → "falsey"
{{#if ""}}truthy{{else}}falsey{{/if}}       → "falsey"
{{#if []}}truthy{{else}}falsey{{/if}}       → "falsey"
{{#if {}}}truthy{{else}}falsey{{/if}}       → "falsey"
{{#if nil}}truthy{{else}}falsey{{/if}}      → "falsey"

{{#if 1}}truthy{{else}}falsey{{/if}}        → "truthy"
{{#if "0"}}truthy{{else}}falsey{{/if}}      → "truthy"
```

**Each skips empty/falsey collections:**
```handlebars
{{#each [1, 2, 3]}}item{{/each}}            → item rendered 3x
{{#each []}}item{{else}}empty{{/each}}      → "empty"
{{#each 0}}item{{else}}falsey{{/each}}      → "falsey"
```

**With blocks skip falsey subjects:**
```handlebars
{{#with person}}name: {{name}}{{/with}}     → renders if person truthy
{{#with nil}}...{{else}}missing{{/with}}    → "missing"
{{#with 0}}...{{else}}falsey{{/with}}       → "falsey"
```

## Breaking Change (v0.1 → v0.2)

This is a **breaking change** from v0.1, which used Elixir truthiness (only `false` and `nil` falsey). Code that relied on `0`, `""`, or `[]` being truthy must be updated.

Migration path:
- Explicit comparisons: `{{#if count > 0}}` instead of `{{#if count}}`
- Use helpers: `{{#if (present? list)}}` to check for non-empty
- Update template logic to match Handlebars conventions

## Links

- [[Handlebars-Inspired Philosophy]] - Why Stem targets Handlebars conventions
- [[Iteration and Context Scoping]] - How truthiness affects each/with blocks
