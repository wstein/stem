---
id: 20260522165045
aliases: []
tags: ['testing', 'property-testing', 'parser', 'compiler']
---

#### What
Stem fuzzes the parsing and compilation pipeline with StreamData property tests in `test/stem/fuzz_test.exs`. Generators build random but structurally valid template sources — expressions, helper calls, pipelines, blocks, comments, partials, and trim markers — and assert that `Stem.Expression.parse/1`, `Stem.Parser.parse/2`, and `Stem.Compiler.compile/2` never raise (they must return `{:ok, _}` or a structured `{:error, ...}` tuple). A bounded `depth` parameter caps nesting so generated trees stay finite.

#### Why
Parsers and compilers have large input spaces where hand-written examples miss edge cases (nested blocks, recursive partial expansion, pipeline-argument escaping). Property testing explores that space automatically and shrinks failures to minimal reproductions. The CLAUDE.md testing policy explicitly calls for "fuzz tests around parsing/compilation," and the parser's recursion-cycle protection (see [[Runtime Evaluation and Sandboxing]]) is exactly the kind of invariant fuzzing validates.

#### How — and the construction-time recursion gotcha
StreamData generators are **constructed eagerly**: Elixir evaluates a function's arguments before the combinator runs, so `one_of([base, recursive_self()])` evaluates `recursive_self()` *immediately* while building the generator tree — before any data is produced. A recursive generator that reaches a fixed point in its depth (e.g. several mutually-recursive helpers all pinned at `depth - 1 == 0`) then constructs forever and the test **hangs at build time**, not at run time. This looks like a hang with no output and no failing assertion.

Two rules keep recursive generators terminating:

1. **Bottom out at depth 0** with a guard clause that only emits non-recursive base generators.
2. **Defer recursive branches behind `bind`/`constant`**, which are lazy. Instead of `one_of([gen_a(), gen_b()])` where the branches recurse, wrap recursion in `bind(driver, fn x -> ... constant(...) end)` so the recursive generator is only built when reached during generation.

The current `helper_expression_generator`, `helper_argument_list_generator`, `pipeline_stage_generator`, and `pipeline_argument_list_generator` use the `bind`/`constant` deferral pattern for this reason. When debugging a hanging property, time pure generation (`Enum.take(StreamData.resize(gen, 50), N)`) separately from parsing to localize whether the hang is in generator construction, data generation, or the code under test.

#### Links
- [[Native AST Compilation Pipeline]] - The parse/compile pipeline these properties exercise
- [[Runtime Evaluation and Sandboxing]] - Partial recursion protection validated by the fuzz suite
- [[NimbleParsec Migration Strategy]] - The tokenizer/parser internals under test
## Links

