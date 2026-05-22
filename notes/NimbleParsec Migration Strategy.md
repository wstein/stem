---
id: 20260522110000
title: "NimbleParsec Migration Strategy"
aliases: []
tags: ['parsing', 'refactor', 'architecture']
---

#### What
Stem's parsing pipeline has been migrated from manual, byte-by-byte recursive descent functions to `nimble_parsec` combinators. `nimble_parsec` compiles declarative parsing rules directly into highly optimized binary pattern-matching Elixir code.

Migration was completed in two phases:

1. **Tokenizer phase** (commit `11ff419`): Replaced `Stem.Tokenizer.scan/6` with NimbleParsec combinators (`choice`, `string`, `ignore`, `repeat`, `tag`, `reduce`). The module `Stem.Tokenizer` was fully rewritten around `defparsec :do_tokenize`.

2. **Parser fusion phase**: Fused `Stem.Tokenizer` entirely into `Stem.Parser`, eliminating the intermediate token-list abstraction. `Stem.Tokenizer` was deleted. The NimbleParsec combinators now live directly in `Stem.Parser`, and token assembly feeds the existing Elixir recursive-descent block parser in the same module. The pipeline shrank from four stages to three: `source → Stem.Parser → Stem.AST → Stem.Compiler`.

#### Why
While hand-written binary matching avoids dependencies, it is difficult to maintain and expand. Manually tracking line and column numbers across CRLF boundaries, managing whitespace trim markers (`~`), and extracting nested subexpressions creates brittle, error-prone code. Migrating to `nimble_parsec` delegates the low-level string traversal to a robust, community-standard library, significantly reducing codebase complexity while maintaining native compilation speed.

Fusing the tokenizer into the parser also removes the intermediate `[token()]` list as a shared contract between two modules: ownership of the lexical detail now lives entirely in `Stem.Parser`, making changes to token representation trivial.

#### How
Each NimbleParsec combinator (`text_chunk`, `block_comment`, `inline_comment`, `raw_tag`, `standard_tag`) has a `post_traverse({__MODULE__, :inject_end_pos, []})` hook applied before its `tag/1` call. The hook injects `{:end_pos, end_line, end_col}` as the first element of each tagged tuple using NimbleParsec's built-in position arguments:

```elixir
def inject_end_pos(rest, args, context, {line, line_offset}, byte_offset) do
  col = byte_offset - line_offset + 1
  {rest, [{:end_pos, line, col} | args], context}
end
```

`assemble_tokens/5` reads each `{:end_pos, ...}` to advance the current position without any manual byte iteration. A narrow helper `advance_through/3` handles only the trim-marker case where leading whitespace is stripped from a text chunk and the start position of the remaining text must be computed.

Context-sensitive block matching (validating that `{{/kind}}` matches the opening `{{#kind}}`) is handled by Elixir recursive descent (`collect/4`, `parse_block/6`) rather than by NimbleParsec grammar rules. NimbleParsec is context-free; embedding kind matching would require post-traversal validation with no clarity benefit.

#### Links
* [[Native AST Compilation Pipeline]] - The pipeline this migration affects.
* [[Whitespace Trim Markers]] - Lexical rules that the new combinators must carefully replicate.

## Links
