---
id: 20260522110000
title: "NimbleParsec Migration Strategy"
aliases: []
tags: ['parsing', 'refactor', 'architecture']
---

#### What
Stem's parsing pipeline is being migrated from manual, byte-by-byte recursive descent functions (in `Stem.Tokenizer` and `Stem.Expression`) to `nimble_parsec` combinators. `nimble_parsec` compiles declarative parsing rules directly into highly optimized binary pattern-matching Elixir code.

#### Why
While hand-written binary matching avoids dependencies, it is difficult to maintain and expand. Manually tracking line and column numbers across CRLF boundaries, managing whitespace trim markers (`~`), and extracting nested subexpressions creates brittle, error-prone code. Migrating to `nimble_parsec` delegates the low-level string traversal to a robust, community-standard library, significantly reducing codebase complexity while maintaining native compilation speed.

#### How
Define grammar rules using `NimbleParsec.defparsec/2`. Replace `Stem.Tokenizer.scan/6` with combinators like `choice`, `string`, `ignore`, and `repeat_while`. Use `nimble_parsec`'s built-in position tracking to generate the `meta` maps `%{line: line, column: column}` automatically.

#### Links
* [[Native AST Compilation Pipeline]] - The pipeline this migration affects.
* [[Whitespace Trim Markers]] - Lexical rules that the new combinators must carefully replicate.

## Links
