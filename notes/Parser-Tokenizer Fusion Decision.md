---
id: 20260523000000
title: "Parser-Tokenizer Fusion Decision"
aliases: ["ADR: Parser-Tokenizer Fusion"]
tags: ['architecture', 'parsing', 'adr']
---

## Status

Accepted — implemented in commit `6d55257` (May 2026).

## Context

The pipeline previously had four stages:

```
source -> Stem.Tokenizer -> Stem.Parser -> Stem.AST -> Stem.Compiler
```

`Stem.Tokenizer` lexed source into a `[token()]` list consumed only by `Stem.Parser.parse/2`. During the NimbleParsec migration (commit `11ff419`), the tokenizer's hand-written byte-scanner (`scan/6` / `advance_binary/3`) was replaced by NimbleParsec combinators, making the tokenizer/parser split accidental rather than intentional — the tokenizer no longer had an independent reason to exist as a public module.

## Decision

Fuse `Stem.Tokenizer` into `Stem.Parser`:

1. Move the NimbleParsec combinators (`text_chunk`, `block_comment`, `inline_comment`, `raw_tag`, `standard_tag`, `defparsec :do_lex`) into `Stem.Parser`.
2. Replace `advance_binary/3` (recursive byte scanner) with a `post_traverse` hook (`inject_end_pos/5`); each raw token carries `{:end_pos, line, col}` injected from NimbleParsec's position args, read by `assemble_tokens/5` without byte iteration.
3. Keep the Elixir recursive-descent block parser (`collect/4`, `parse_block/6`) unchanged: NimbleParsec handles the context-free lexical layer, Elixir the context-sensitive structural layer.
4. Delete `lib/stem/tokenizer.ex`; the pipeline becomes `source -> Stem.Parser -> Stem.AST -> Stem.Compiler`.
5. Keep `Stem.Parser.tokenize/2` as `@doc false` so lexer-level tests still run against the internal token format.

## Alternatives Considered

**Full NimbleParsec block grammar (`parsec/1` for recursive blocks)** — idiomatic for recursive grammars, but rejected: Stem's block matching is context-sensitive (`{{/if}}` must close `{{#if}}`) while NimbleParsec is context-free, so kind matching would need a `post_traverse` validator per block; the recursive-descent error messages (`unclosed_block`, `mismatched_close`) carry the opening tag position naturally through the Elixir call stack; and the existing `collect/4`/`parse_block/6` is well-tested (second `{{else}}`, else-in-region, partial-recursion guard). Low risk/reward.

**Keep `Stem.Tokenizer` separate** — rejected: no other code consumes it, so the module boundary expresses no meaningful separation and would keep `advance_binary/3` alive.

## Consequences

- **Positive**: one fewer public module; `advance_binary/3` deleted; position metadata now comes from NimbleParsec's built-in tracking; `Stem.Parser` solely owns lexical + structural parsing.
- **Positive**: `Stem.Parser.tokenize/2` (`@doc false`) keeps lexer-level assertions without a public module.
- **Neutral**: the `[token()]` representation still exists inside `Stem.Parser`, just no longer a public contract; a future refactor could wire NimbleParsec output directly into the recursive-descent logic.

## Links

- [[NimbleParsec Migration Strategy]] - History of the NimbleParsec migration.
- [[Native AST Compilation Pipeline]] - The pipeline this decision reshapes.
