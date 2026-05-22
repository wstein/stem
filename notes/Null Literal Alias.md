---
id: 20260523130000
aliases: ["null keyword", "null alias"]
tags: ["semantics", "literals", "handlebars"]
---
Stem accepts both `null` and `nil` in template expressions, with `null` as the canonical source spelling.

#### What

`{{null}}`, `{{nil}}`, and the same tokens in helper arguments and block conditions represent the same null value: they render as the empty string and are falsy under Handlebars truthiness. The formatter rewrites `nil` to `null`, so `null` remains the single canonical spelling in source.

#### Why

Stem already consumes JSON and YAML on the data side, where null-like values map to Elixir `nil`. Using `null` as canonical in template source reduces friction for developers arriving from JSON/YAML/Handlebars conventions, while still preserving Elixir runtime semantics. This keeps Stem Handlebars-inspired (see [[Handlebars-Inspired Philosophy]]) and friendly to non-Elixir template authors.

#### How

Expression parsing normalizes both `null` and `nil` to a canonical literal node whose formatter spelling is `null`. Runtime code generation lowers that canonical `null` literal to Elixir `nil`, so rendering and truthiness behavior are unchanged. `Stem.CLI`'s assigns heuristic treats both `null` and `nil` as literals (not assign names), alongside `true` and `false`.

#### Tradeoff

`null` and `nil` are effectively reserved literal keywords: `{{null}}` and `{{nil}}` do not read assigns or map keys with those names. This shadowing is the deliberate cost of supporting both spellings as literals; data whose key is `"null"` or `"nil"` must be reached another way (for example `{{lookup map "null"}}`).

#### Links

* [[Handlebars Expression Resolution]] - How tag tokens resolve to Elixir.
* [[Handlebars-Inspired Philosophy]] - Why Stem favors familiarity without bug-for-bug parity.
