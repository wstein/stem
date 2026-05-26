---
id: 20260521131400
aliases: [Scoping, Context]
tags: ['semantics', 'compiler']
---

Stem manages context scoping and iteration through local bindings that unify with template-parsed variables.

## What

`{{#each list}}` binds the current item to `@this` (and to bare identifiers), the zero-based index to `@index`, the one-based index to `@index1`, the key (for maps) to `@key`, and the first/last step to `@first`/`@last`. `{{#with object}}` pushes the object as `@this`. `@parent` reaches the immediate enclosing context and `@root` the render assigns from any depth (`@this` itself is the render assigns at the top level, so `{{@this.name}}` works outside any block). `{{#each list as |item idx|}}` (or `as |item i0 i1|` for both indices) and `{{#with object as |value|}}` expose those same scopes through explicit block parameters. The five iteration variables (`@index`/`@index1`/`@key`/`@first`/`@last`) are valid only inside an `#each`.

## Why

Consistent scoping makes it easy to work with nested data structures while maintaining access to global state. The use of `../` for parent access mirrors the Handlebars convention and simplifies templates that need to combine list items with global configuration.

## How

Iterate over lists or maps using `{{#each}}`. Use `{{#with}}` to clean up deep property access. Reference `@index`/`@index1` for list positions and `../` for external assignments. Use block parameters when a template should name its scope explicitly instead of relying on `this`. If an iteration list is `nil` or empty, the `{{else}}` block (if present) is rendered based on Elixir truthiness.


## Links

- [[Each Index Variables and Block Params]] - Zero- vs one-based indices and the three-param block form.
- [[Template Variable Hygiene]] - How these bindings are implemented in the compiler.
- [[Handlebars Truthiness Semantics]] - How empty collections are handled in iteration.
- [[Handlebars Expression Resolution]] - The resolution order for these tokens.
