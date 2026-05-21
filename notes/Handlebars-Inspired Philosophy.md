---
id: 20260521131000
aliases: []
tags: [philosophy, architecture]
---
Stem is "Handlebars-inspired" rather than fully compatible because it prioritizes Elixir-native performance and explicit semantics over bug-for-bug parity with the JavaScript reference implementation.

## What

Stem adopts the Handlebars tag syntax (`{{ }}`, `{{#each}}`, etc.) but maps it directly onto Elixir semantics. It uses a native four-stage pipeline that emits Elixir AST and supports both compile-time macros and runtime compile/eval APIs.

## Why

Full compatibility would require simulating a JavaScript-like environment (e.g., loose truthiness, prototype-based resolution) which carries significant performance overhead and complicates Elixir integration. By being "inspired," Stem provides the familiar ergonomics of Handlebars while behaving like a first-class Elixir citizen.

## How

When authoring templates, expect Elixir-style data resolution and truthiness. For features where Handlebars behavior is desired but differs from Elixir (like truthiness for `[]` or `0`), use explicit expressions within the tags.

## Links

- [[Handlebars Truthiness Semantics]] - Where the semantics diverge most clearly.
- [[Native AST Compilation Pipeline]] - The mechanism enabling this performance.
- [[Compile-Time-Only Security Model]] - The runtime trust-boundary trade-off.
- [[Strict CLI Contract and Launcher]] - The philosophy of explicit data separation in tooling.
- [[Whitespace Trim Markers]] - Native control over surrounding template layout.
