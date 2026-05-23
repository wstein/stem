---
id: 20260523120000
aliases: [index0 index1, one-based index, each block params]
tags: ['semantics', 'blocks', 'iteration', 'stringtemplate']
---

Stem exposes both a zero-based (`@index`) and a one-based (`@index1`) iteration index inside `{{#each}}`, mirroring StringTemplate 4's `i0` vs `i` convention, and supports block parameters up to three names including a Handlebars-style `as |value key|` form.

#### What
Inside `{{#each}}`:

- `{{@index}}` — zero-based index (`0, 1, 2, …`), for array-style positioning.
- `{{@index1}}` — one-based index (`1, 2, 3, …`), for human-facing display ("Item 1").
- `{{@key}}` — the key when iterating a map; `{{this}}` — the current item.

Block parameters accept up to three names:

- `as |item|` — current item only.
- `as |item key|` — item plus the **iteration key**: the map key when iterating a map, or the numeric index when iterating a list (Handlebars `{{#each obj as |value key|}}`).
- `as |item i0 i1|` — item, zero-based index, one-based index (ST4-style explicit positions; always numeric regardless of collection type).

Parameter names may use any leading letter case (`as |Item|`, `as |I1|`); they bind to a fresh internal variable, so the author's casing is unconstrained (see [[Literal Variable Keys and Anonymous Params]]). The underscore `_` is the **anonymous/wildcard** parameter: it skips a positional slot and may repeat (`as |_ _ i1|` to read only the one-based index), so it is exempt from the "block parameters must be unique" check. Named parameters must still be unique.

#### Why
This matches StringTemplate 4, which distinguishes `i0` (zero-based) from `i` (one-based) so templates can both index data and render ordinals without arithmetic. The one-based variant is not mere sugar in Stem: because inline math is forbidden (see [[Jinja2 Logic Gap and State Mutation]]), a template **cannot** write `@index + 1`. Providing `@index1` / the `i1` block param directly is therefore the only declarative way to display a one-based position while keeping templates side-effect free. The two-param `as |value key|` form mirrors Handlebars so map entries can bind a value and its key without reaching for `@key`.

#### How
The `{{#each}}` body runs inside a generated `fn {current, stem_key}, stem_index -> ... end`, where `stem_index` is the zero-based position and `stem_key` is the map key (or `nil` for lists). The compiler lowers `@index` to `stem_index` and `@index1` to `stem_index + 1` (the addition is engine-generated, not user expression, so it is not subject to the safe-mode arbitrary-expression check). Block-param binding:

- `as |item key|` binds `key = stem_key || stem_index`, so it is the map key for maps and the index for lists.
- `as |item i0 i1|` binds `i0 = stem_index`, `i1 = stem_index + 1`.

The parser allows at most three `{{#each}}` block parameters, and the `as |...|` keyword is required.

#### Links
* [[Iteration and Context Scoping]] - How each-block locals bind to compiled variables.
* [[Jinja2 Logic Gap and State Mutation]] - Why `@index + 1` is impossible, motivating `@index1`.
* [[Handlebars-Inspired Philosophy]] - Stem prioritizes explicit, declarative semantics over JS parity.
* [[Literal Variable Keys and Anonymous Params]] - Bracket keys, uppercase names, and the `_` wildcard.

## Links
