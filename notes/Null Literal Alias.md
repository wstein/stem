---
id: 20260523130000
aliases: ["null keyword", "null alias"]
tags: ["semantics", "literals", "handlebars"]
---
Stem accepts `null` as an alias for the `nil` literal in template expressions, canonicalizing it to `nil`.

#### What
`{{null}}` and `null` in any expression position (helper arguments, block conditions) are treated exactly like the `nil` literal: they render as the empty string and are falsy under Handlebars truthiness. The formatter rewrites `null` to `nil`, so `nil` remains the single canonical spelling in source.

#### Why
Stem already consumes JSON on the data side (`bin/stem data.json template.stem`), where JSON `null` decodes to Elixir `nil`. Accepting `null` in template *source* removes a small friction point for developers arriving from Handlebars/JavaScript/JSON, without adding a genuinely new value — it is purely a spelling alias. Stem stays Handlebars-*inspired* (see [[Handlebars-Inspired Philosophy]]) while keeping `nil` as the Elixir-native canonical form.

#### How
Both expression parse sites in `Stem.Expression` map `trimmed == "null"` to `{:literal, "nil"}` (the `nil` literal node), so it lowers to Elixir `nil` and `format/1` emits `nil`. `Stem.CLI`'s assigns heuristic lists `null` among the non-assign literals alongside `nil`/`true`/`false`.

#### Tradeoff
`null` is now effectively reserved: `{{null}}` no longer reads an assign or map key literally named `null` (it always means `nil`). This shadowing is the deliberate cost of the alias; data whose key is the string `"null"` must be reached another way (e.g. `{{lookup map "null"}}`).

#### Links
* [[Handlebars Expression Resolution]] - How tag tokens resolve to Elixir.
* [[Handlebars-Inspired Philosophy]] - Why Stem favors familiarity without bug-for-bug parity.
