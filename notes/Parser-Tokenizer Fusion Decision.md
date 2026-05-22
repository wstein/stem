---
id: 20260523000000
title: "Parser-Tokenizer Fusion Decision"
aliases: ["ADR: Parser-Tokenizer Fusion"]
tags: ['architecture', 'parsing', 'adr']
---

## Status

Accepted — implemented in commit `6d55257` (May 2026).

## Context

Before this change the Stem compilation pipeline had four stages:

```
source -> Stem.Tokenizer -> Stem.Parser -> Stem.AST -> Stem.Compiler
```

`Stem.Tokenizer` was a standalone module that lexed source into a `[token()]`
list, which `Stem.Parser` consumed.  Both modules were owned by the same team
and changed together in lock-step.  The only caller of `Stem.Tokenizer.tokenize/2`
was `Stem.Parser.parse/2`.

During the NimbleParsec migration (commit `11ff419`) the tokenizer's hand-written
byte-scanner (`scan/6` / `advance_binary/3`) was replaced by NimbleParsec
combinators.  That refactor made the split between tokenizer and parser
accidental rather than intentional: the tokenizer no longer had an independent
reason to exist as a public module.

## Decision

Fuse `Stem.Tokenizer` into `Stem.Parser` as a single `Stem.Parser` module:

1. Move the NimbleParsec combinators (`text_chunk`, `block_comment`,
   `inline_comment`, `raw_tag`, `standard_tag`, `defparsec :do_lex`) directly
   into `Stem.Parser`.

2. Replace `advance_binary/3` (recursive byte-by-byte position scanner) with a
   `post_traverse` hook (`inject_end_pos/5`) on each combinator.  Each tagged
   raw token now carries `{:end_pos, line, col}` as its first element, injected
   from NimbleParsec's built-in position arguments.  `assemble_tokens/5` reads
   these directly without iterating bytes.

3. Retain the Elixir recursive-descent block parser (`collect/4`,
   `parse_block/6`, etc.) unchanged.  NimbleParsec handles the context-free
   lexical layer; Elixir handles the context-sensitive structural layer.

4. Delete `lib/stem/tokenizer.ex`.  The three-stage pipeline becomes:

   ```
   source -> Stem.Parser -> Stem.AST -> Stem.Compiler
   ```

5. Keep `Stem.Parser.tokenize/2` as a `@doc false` public function so existing
   lexer-level tests (position tracking, trim markers, error messages) can
   continue to run against the internal token format.

## Alternatives Considered

**Full NimbleParsec block grammar (`parsec/1` for recursive blocks)**

A fully declarative grammar would define a `nodes` rule that invokes
`parsec(:block)` for block expressions, which in turn invokes `parsec(:nodes)`
recursively for the body and else branch.  This is the idiomatic NimbleParsec
approach for recursive grammars.

Rejected for this iteration because:

- Block matching in Stem is context-sensitive: `{{/if}}` must close the
  enclosing `{{#if}}`.  NimbleParsec is context-free.  Kind matching would
  require a `post_traverse` validator on every block, adding complexity without
  clarity benefit.
- The error messages produced by the recursive-descent functions (`unclosed_block`,
  `mismatched_close`) carry the original opening tag position, which is naturally
  threaded through the Elixir call stack.  Replicating this in a pure NimbleParsec
  grammar requires explicit context plumbing.
- The existing `collect/4` / `parse_block/6` code is already well-tested and
  covers edge cases (second `{{else}}`, `{{else}}` inside region, partial
  recursion guard).  The risk/reward of replacing it is low.

**Keep `Stem.Tokenizer` as a separate module**

Retaining the module boundary would require both modules to continue evolving in
sync and would keep `advance_binary/3` in place.  Since no other code consumes
`Stem.Tokenizer`, the module boundary does not express a meaningful architectural
separation.

## Consequences

- **Positive**: One fewer public module.  `advance_binary/3` deleted.  Position
  metadata arrives from NimbleParsec's built-in tracking rather than manual byte
  iteration.  `Stem.Parser` is the single owner of all lexical and structural
  parsing concerns.
- **Positive**: `Stem.Parser.tokenize/2` (`@doc false`) exposes the internal
  token format for testing, keeping lexer-level assertions without requiring a
  public module.
- **Negative**: `Stem.Parser` is larger than either predecessor module alone
  (~450 lines vs ~260 + ~380 = ~640 total, an actual reduction).
- **Neutral**: The `[token()]` intermediate representation still exists inside
  `Stem.Parser`; it is simply no longer a public contract.  A future refactor
  could eliminate it entirely by wiring NimbleParsec output directly into the
  recursive-descent logic.

## Links

- [[NimbleParsec Migration Strategy]] - History of the NimbleParsec migration.
- [[Native AST Compilation Pipeline]] - The pipeline this decision reshapes.

## Links
