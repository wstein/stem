---
id: 20260521120000
aliases: []
tags: [architecture, compiler]
---
Stem compiles `{{ }}` templates through a native three-stage pipeline that produces Elixir AST directly, without translating to EEx first.

## What

Compilation flows `source -> Stem.Parser -> Stem.AST -> Stem.Compiler -> quoted Elixir`.
`Stem.Parser` performs both lexing (via NimbleParsec combinators) and structural parsing (block nesting, partial expansion, region and yield resolution) in a single module, producing `Stem.AST` nodes.
The compiler lowers that AST into quoted Elixir while `Stem.Expression` parses tag contents into its own expression AST.
That expression AST owns helper-pipeline nodes, so `lhs |> trim |> truncate(20)` stays structured until the compiler lowers it into nested helper calls.

The pipeline was originally four stages (`source -> Stem.Tokenizer -> Stem.Parser -> Stem.AST -> Stem.Compiler`).
`Stem.Tokenizer` was deleted when lexing was fused into `Stem.Parser`: the NimbleParsec combinators and the recursive-descent block parser now share a single module boundary.
See [[NimbleParsec Migration Strategy]] for the migration history.

## Why

The earlier design rewrote `{{ }}` into EEx text and reused the EEx tokenizer and compiler.
That added a translation layer, leaked EEx error messages and escaping markers, and constrained the language to EEx semantics.
Owning the pipeline gives precise error positions, a real AST to analyse, and full control over semantics.

Fusing `Stem.Tokenizer` into `Stem.Parser` removed the intermediate `[token()]` list as a module-boundary contract: all lexical detail is now private to `Stem.Parser`, and position metadata arrives from NimbleParsec's built-in `post_traverse` hooks rather than manual byte iteration.

## How

Treat the stages as the contract: add lexical concerns to `Stem.Parser`, structural concerns to `Stem.Parser`, and lowering concerns to the compiler.
Keep expression semantics in `Stem.Expression` so the parser stays independent of how tags are interpreted.
Subexpressions, helper pipelines, block parameters, whitespace control, diagnostics, and safe-mode checks all attach to one of these owned stages instead of re-parsing raw template text later.
Whitespace control includes the one-sided variants `{{~ ...}}` and `{{... ~}}` as well as the symmetric `{{~ ... ~}}` form.

## Links

- [[Project Configuration Defaults]] - How project defaults feed the pipeline.
- [[Handlebars Expression Resolution]] - How tag contents become Elixir.
- [[Project Configuration Defaults]] - How project defaults feed the pipeline.
- [[Handlebars Expression Resolution]] - How tag contents become Elixir.
- [[Template Variable Hygiene]] - Why generated and parsed variables unify.
- [[Compile-Time-Only Security Model]] - Runtime trust-boundary guidance for this pipeline.
- [[NimbleParsec Migration Strategy]] - How the tokenizer was migrated and then fused into the parser.
