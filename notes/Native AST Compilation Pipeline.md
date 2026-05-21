---
id: 20260521120000
aliases: []
tags: [architecture, compiler]
---
Stem compiles `{{ }}` templates through a native four-stage pipeline that produces Elixir AST directly, without translating to EEx first.

## What

Compilation flows `source -> Stem.Tokenizer -> Stem.Parser -> Stem.AST -> Stem.Compiler -> quoted Elixir`.
The tokenizer is purely lexical, the parser matches blocks and expands partials into an AST, and the compiler lowers the AST into quoted Elixir while `Stem.Expression` translates the contents of each tag.

## Why

The earlier design rewrote `{{ }}` into EEx text and reused the EEx tokenizer and compiler.
That added a translation layer, leaked EEx error messages and escaping markers, and constrained the language to EEx semantics.
Owning the pipeline gives precise error positions, a real AST to analyse, and full control over semantics.

## How

Treat the four stages as the contract: add lexical concerns to the tokenizer, structural concerns to the parser, and lowering concerns to the compiler.
Keep expression semantics in `Stem.Expression` so the parser stays independent of how tags are interpreted.

## Links

- [[Handlebars Expression Resolution]] - How tag contents become Elixir.
- [[Template Variable Hygiene]] - Why generated and parsed variables unify.
- [[Compile-Time-Only Security Model]] - Runtime trust-boundary guidance for this pipeline.
