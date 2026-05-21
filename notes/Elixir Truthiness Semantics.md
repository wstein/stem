---
id: 20260521131100
aliases: [Truthiness, Elixir Truthiness (Deprecated)]
tags: [semantics, logic, deprecated, v0.1.0]
status: archived
---

> ⚠️ **ARCHIVED (v0.1.0)**: This note describes the truthiness semantics from Stem v0.1.0.
> As of v0.2.0, Stem uses **Handlebars truthiness** instead. See [[Handlebars Truthiness Semantics]].

## Historical: Elixir Truthiness (v0.1.0 only)

Block conditionals in Stem v0.1.0 followed Elixir truthiness rules: only `false` and `nil` were falsey, while all other values were truthy.

This decision was made to minimize translation overhead at runtime and provide Elixir semantics to Elixir developers. However, it created cognitive friction when working with Handlebars conventions.

### Why Changed

The shift to Handlebars truthiness (v0.2.0+) aligns Stem with:
- Frontend template language conventions (Handlebars, Liquid, EJS)
- JavaScript truthiness expectations
- Developer familiarity and reduced cognitive load

### Migration from v0.1 to v0.2

See [[Handlebars Truthiness Semantics]] for the breaking change details and migration guidance.
