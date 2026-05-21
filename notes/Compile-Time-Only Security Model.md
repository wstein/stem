---
id: 20260521120100
aliases: []
tags: [security, api]
---
Stem supports both compile-time and runtime template compilation; security now depends on explicit trust boundaries and explicit output transformations.

## What

`Stem.function_from_string/5` and `Stem.function_from_file/5` remain the compile-time APIs.
`Stem.compile_string/2`, `Stem.compile_file/2`, `Stem.eval_string/3`, and `Stem.eval_file/3` provide runtime equivalents.
`{{...}}` output is unescaped by default, so escaping/sanitization must be performed via helpers or calling code.

## Why

Some use cases need EEx-style runtime template evaluation.
Keeping runtime APIs while requiring explicit transformations makes dynamic rendering possible without hidden output mutation.

## How

Use compile-time macros for static templates and runtime APIs when templates are selected dynamically.
Treat runtime template input as untrusted.
Apply sanitization and escaping through helpers such as `escape_html` or project-specific helper functions at the output boundary.
Use `mode: :safe` when runtime templates should reject arbitrary Elixir fallback expressions and stay within Stem's structured expression model.
Use `contract: [required: [...]]` when a template needs an explicit assign boundary at call time.
Helper pipelines fit that safe subset because they only allow structured Stem input on the left-hand side and helper stages on the right-hand side.
Pipeline stages are intentionally limited to helper names and helper calls so templates cannot escalate into arbitrary module pipelines.

## Links

- [[Native AST Compilation Pipeline]] - The pipeline these macros drive.
- [[HTML Escaping Behavior]] - Explicit transformation guidance.
- [[Strict CLI Contract and Launcher]] - How this model persists at the command-line boundary.
