---
id: 20260521131300
aliases: []
tags: [extensibility, macros]
---
Stem resolves helpers and partials through a combination of compile-time expansion and a runtime registry, allowing for efficient Elixir integration.

## What

Helpers are functions registered in `Stem.Helpers` or passed in the `helpers` assign; they are invoked when a tag's first token is a name followed by arguments. Partials (`{{> name}}`) are expanded inline by the parser at compile time using the `:partials` option.

## Why

Inlining partials at compile time removes recursive calls at runtime and allows the compiler to optimize the entire block as a single unit. Using a registry for helpers allows modules to share common functionality without duplicating code in every template.

## How

Register global helpers with `Stem.Helpers.register/2` or pass local helpers as a map in the function arguments. Provide partials as a map to the `function_from_string` macro.

## Links

- [[Handlebars Expression Resolution]] - How helper calls are distinguished from variables.
- [[Native AST Compilation Pipeline]] - Where partial expansion occurs.
- [[Elixir Truthiness Semantics]] - How helper return values are interpreted in blocks.
