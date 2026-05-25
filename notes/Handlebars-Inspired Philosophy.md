---
id: 20260521131000
aliases: []
tags: [philosophy, architecture]
---
Stem is "Handlebars-inspired" rather than fully compatible because it prioritizes Elixir-native performance and explicit semantics over bug-for-bug parity with the JavaScript reference implementation.

## What

Stem adopts the Handlebars tag syntax and aligns with Handlebars truthiness semantics, while chaining transformations with a left-to-right `|` pipe operator. It uses a native four-stage pipeline that emits Elixir AST and supports both compile-time macros and runtime compile/eval APIs.

## Why

Full compatibility would require simulating a JavaScript-like environment, carrying significant performance overhead and complicating Elixir integration. However, earlier versions that strictly enforced Elixir truthiness created cognitive friction for frontend developers. By adopting Handlebars truthiness (where `0`, `""`, `[]`, and `%{}` are falsey) and explicit data pipelines, Stem provides familiar frontend ergonomics while remaining a performant Elixir citizen.

## How

When authoring templates, expect Handlebars-style truthiness for conditional blocks and empty collections. Use helper pipelines (`{{ value | trim | upcase }}`) to format data declaratively instead of relying on implicit engine mutations.

## Links

- [[Handlebars Truthiness Semantics]] - Where the semantics diverge most clearly.
- [[Native AST Compilation Pipeline]] - The mechanism enabling this performance.
- [[Compile-Time-Only Security Model]] - The runtime trust-boundary trade-off.
- [[Strict CLI Contract and Launcher]] - The philosophy of explicit data separation in tooling.
- [[Whitespace Trim Markers]] - Native control over surrounding template layout.
