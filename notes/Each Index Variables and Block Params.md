---
id: 20260523120000
aliases: ["index0 index1", "one-based index", "each block params"]
tags: ["semantics", "blocks", "iteration", "stringtemplate"]
---
Stem exposes both a zero-based (`@index`) and a one-based (`@index1`) iteration index inside `{{#each}}`, mirroring StringTemplate 4's `i0` vs `i` convention, and supports a three-parameter block form `{{#each list as |el i0 i1|}}`.

#### What
Inside `{{#each}}`:

- `{{@index}}` — zero-based index (`0, 1, 2, …`), for array-style positioning.
- `{{@index1}}` — one-based index (`1, 2, 3, …`), for human-facing display ("Item 1").
- `{{@key}}` — the key when iterating a map; `{{this}}` — the current item.

Block parameters accept up to three names:

- `as |el|` — current item only.
- `as |el i0|` — item plus zero-based index.
- `as |el i0 i1|` — item, zero-based index, one-based index.

#### Why
This matches StringTemplate 4, which distinguishes `i0` (zero-based) from `i` (one-based) so templates can both index data and render ordinals without arithmetic. The one-based variant is not mere sugar in Stem: because inline math is forbidden (see [[Jinja2 Logic Gap and State Mutation]]), a template **cannot** write `@index + 1`. Providing `@index1` / the `i1` block param directly is therefore the only declarative way to display a one-based position while keeping templates side-effect free.

#### How
The `{{#each}}` body runs inside a generated `fn {current, stem_key}, stem_index -> ... end`, where `stem_index` is zero-based. The compiler lowers `@index` to `stem_index` and `@index1` to `stem_index + 1` (the addition is engine-generated, not user expression, so it is not subject to the safe-mode arbitrary-expression check). The three-param `as |el i0 i1|` form binds `el = current`, `i0 = stem_index`, `i1 = stem_index + 1`. The parser allows at most three `{{#each}}` block parameters.

#### Links
* [[Iteration and Context Scoping]] - How each-block locals bind to compiled variables.
* [[Jinja2 Logic Gap and State Mutation]] - Why `@index + 1` is impossible, motivating `@index1`.
* [[Handlebars-Inspired Philosophy]] - Stem prioritizes explicit, declarative semantics over JS parity.
