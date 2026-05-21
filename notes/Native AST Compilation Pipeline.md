---
id: 20260521120000
aliases: []
tags: [architecture, compiler]
---
Stem compiles `{{ }}` templates through a native four-stage pipeline that produces Elixir AST directly, without translating to EEx first.

## What

Compilation flows `source -> Stem.Frontmatter -> Stem.Tokenizer -> Stem.Parser -> Stem.AST -> Stem.Compiler -> quoted Elixir`.
Before tokenization, YAML frontmatter is extracted to apply per-template configurations. The tokenizer is purely lexical, the parser matches blocks and expands partials into an AST, and the compiler lowers the AST into quoted Elixir while `Stem.Expression` parses tag contents into its own expression AST.
That expression AST now also owns helper-pipeline nodes, so `lhs |> trim |> truncate(20)` stays structured until the compiler lowers it into nested helper calls.

## Why

The earlier design rewrote `{{ }}` into EEx text and reused the EEx tokenizer and compiler.
That added a translation layer, leaked EEx error messages and escaping markers, and constrained the language to EEx semantics.
Owning the pipeline gives precise error positions, a real AST to analyse, and full control over semantics.

## How

Treat the stages as the contract: configure template behavior via frontmatter, add lexical concerns to the tokenizer, structural concerns to the parser, and lowering concerns to the compiler.
Keep expression semantics in `Stem.Expression` so the parser stays independent of how tags are interpreted.
Subexpressions, helper pipelines, block parameters, whitespace control, diagnostics, and safe-mode checks all attach to one of these owned stages instead of re-parsing raw template text later.
Whitespace control includes the one-sided variants `{{~ ...}}` and `{{... ~}}` as well as the symmetric `{{~ ... ~}}` form.

## Links

- [[Configuration and Frontmatter]] - How the frontmatter extraction stage is used.
- [[Handlebars Expression Resolution]] - How tag contents become Elixir.
- [[Template Variable Hygiene]] - Why generated and parsed variables unify.
- [[Compile-Time-Only Security Model]] - Runtime trust-boundary guidance for this pipeline.
