---
id: 20260523000000
title: "Parser-Tokenizer Fusion Decision"
aliases: ["ADR: Parser-Tokenizer Fusion"]
tags: ['architecture', 'parsing', 'adr']
---

## Status

Accepted and implemented in commit `6d55257` in May 2026.

## Context

Before the change, the pipeline was `source -> Stem.Tokenizer -> Stem.Parser -> Stem.AST -> Stem.Compiler`. `Stem.Tokenizer` only existed to lex source for `Stem.Parser`, and the NimbleParsec migration removed the last good reason for that module boundary.

## Decision

Fuse the tokenizer into `Stem.Parser`:

1. Move the NimbleParsec lexing rules into `Stem.Parser`.
2. Replace the byte-by-byte position scanner with a `post_traverse` hook that injects end positions into each token.
3. Keep the recursive-descent block parser in Elixir, since block matching remains context-sensitive.
4. Delete `lib/stem/tokenizer.ex` and keep `Stem.Parser.tokenize/2` as a `@doc false` testing seam.

The pipeline becomes `source -> Stem.Parser -> Stem.AST -> Stem.Compiler`.

## Why not full NimbleParsec blocks

Recursive block matching needs context-aware close-tag validation and error reporting that is easier to keep in Elixir. The existing `collect/4` and `parse_block/6` code already handles those cases well, so the simpler split is to let NimbleParsec handle lexing and Elixir handle structure.

## Consequences

- One fewer public module and no separate tokenizer maintenance.
- Position metadata comes from NimbleParsec instead of manual byte scanning.
- The internal token format still exists, but only behind `Stem.Parser.tokenize/2` for tests.
- The parser module is larger, but the overall codebase is smaller because the standalone tokenizer is gone.
