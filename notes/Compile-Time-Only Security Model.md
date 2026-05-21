---
id: 20260521120100
aliases: []
tags: [security, api]
---
Stem never compiles or evaluates template source at runtime; templates only become code through compile-time macros.

## What

`Stem.eval_string/3`, `Stem.eval_file/3`, `Stem.compile_string/2`, and `Stem.compile_file/2` raise `Stem.SecurityError`.
Templates are turned into functions only by `Stem.function_from_string/5`, `Stem.function_from_file/5`, and the `Stem.DSL` macros, all of which run during module compilation.

## Why

Compiling template source at runtime would let untrusted input reach the code path.
Restricting compilation to build time keeps that boundary closed and makes rendering a plain function call.

## How

Author templates as compile-time functions or via the DSL.
When a tool needs to render a template chosen at runtime, build a module with `Module.create/3` around `function_from_string/5` at the trust boundary, as the CLI does, rather than reaching for an eval entry point.

## Links

- [[Native AST Compilation Pipeline]] - The pipeline these macros drive.
