---
id: 20260522181812
aliases: []
tags: ['architecture', 'design', 'rationale', 'host-language']
---

#### What
Stem is a native template compiler that fuses Handlebars syntax with StringTemplate strictness, lowering `{{ }}` templates directly into Elixir AST rather than an intermediate text language. Elixir is the deliberate host language; LISP/Clojure were considered and rejected as direct targets.

#### Why Elixir is the match
- **Zero-overhead compilation**: Elixir's macro system lets `deftemplate`, `deftemplate_file`, and the `~STEM` sigil lower parsed AST directly into quoted Elixir. Rendering becomes a plain compiled function call, natively type-checked, with no runtime template evaluation on the hot path (see [[Native AST Compilation Pipeline]]).
- **Pipeline ergonomics**: Stem's Jinja2-style transformations use the Elixir pipe inside tags (`{{ name |> trim |> upcase }}`). The frontend pipeline is syntactically 1-to-1 with the host language's natural idiom, so translation stays structural.
- **Functional purity**: Immutable data aligns with strict model-view separation — attribute expressions must be side-effect free (see [[Strict Model-View Separation and State Isolation]]).

#### Why not LISP/Clojure
LISP and Clojure share the functional purity and homoiconicity needed to *theoretically* build a Stem-like engine, but are not a match for this implementation:
- **Pipeline mismatch**: LISP's prefix notation (`(upcase (trim name))`) creates syntactic dissonance with Stem's declarative left-to-right pipeline stages (`name |> trim |> upcase`).
- **Host-language binding**: Stem trades portability for deep BEAM integration. It relies on `Code.eval_quoted` for the `Stem.Unsafe` dynamic-eval APIs, NimbleParsec for lexing combinators ([[NimbleParsec Migration Strategy]]), and Elixir-specific AST node tuples — e.g. `{:if, expr, [body], [else_body], meta}`, with `{:each, expr, params, [body], [else_body], meta}` carrying a block-params list. Porting to Clojure would mean rewriting the whole `Parser -> AST -> Compiler` pipeline against the JVM/Clojure compiler.

#### Links
- [[Native AST Compilation Pipeline]] - The compile pipeline this rationale depends on
- [[Handlebars-Inspired Philosophy]] - Why Stem favors native semantics over JS parity
- [[NimbleParsec Migration Strategy]] - The Elixir-specific lexing layer
- [[Runtime Evaluation and Sandboxing]] - The `Code.eval_quoted`-backed dynamic APIs
- [[Universal Architecture Principles]] - The portable design ideas that outlive the host choice
## Links

