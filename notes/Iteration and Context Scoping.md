---
id: 20260521131400
aliases: [Scoping, Context]
tags: [semantics, compiler]
---
Stem manages context scoping and iteration through local bindings that unify with template-parsed variables.

## What

`{{#each list}}` binds the current item to `this` (and bare identifiers), the index to `@index`, and the key (for maps) to `@key`. `{{#with object}}` pushes the object as the current scope. `../name` allows reaching out of the current iteration/context to the parent (top-level) assigns.

## Why

Consistent scoping makes it easy to work with nested data structures while maintaining access to global state. The use of `../` for parent access mirrors the Handlebars convention and simplifies templates that need to combine list items with global configuration.

## How

Iterate over lists or maps using `{{#each}}`. Use `{{#with}}` to clean up deep property access. Reference `@index` for list positions and `../` for external assignments. If an iteration list is `nil` or empty, the `{{else}}` block (if present) is rendered based on Elixir truthiness.

## Links

- [[Template Variable Hygiene]] - How these bindings are implemented in the compiler.
- [[Elixir Truthiness Semantics]] - How empty collections are handled in iteration.
- [[Handlebars Expression Resolution]] - The resolution order for these tokens.
