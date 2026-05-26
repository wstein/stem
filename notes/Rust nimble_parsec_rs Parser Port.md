---
id: 20260526224655
aliases: []
tags: ['parsing', 'rust', 'native', 'architecture', 'refactor']
---

The Rust native parser's **lexer and expression tokenizer** were ported from hand-written byte scanning to `nimble_parsec_rs` (a Rust port of NimbleParsec), so the Rust front-end shares one conceptual model with the Elixir reference's `do_lex` grammar.

- `native/stem_compile/src/np_lexer.rs` — combinator lexer (`do_lex`) plus a `tokenize` assembler.
- `native/stem_compile/src/np_expr.rs` — the top-level expression tokenizer (quote / paren / bracket chunks, separators).

The bar was **conceptual parity, not byte-identical ASTs**. The structural recursive-descent block assembler (`collect` / `parse_block` / `expand_partial`) stays hand-written, deliberately mirroring Elixir's `Stem.Parser` structure rather than being expressed as combinators.

Safety: each migration phase was gated by the BEAM-vs-Rust differential staying green — `mix stem.native.compile_diff` (0 mismatches) and the fuzz corpus — before the swap landed.

## Links

- [[NimbleParsec Migration Strategy]] — the Elixir-side migration this mirrors.
- [[Native AST Compilation Pipeline]] — the pipeline the lexer feeds.
- [[Parser-Tokenizer Fusion Decision]] — the related front-end ADR.
## Links

