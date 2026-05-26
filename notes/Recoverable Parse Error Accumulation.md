---
id: 20260526224646
aliases: []
tags: ['compiler', 'parser', 'errors', 'native', 'conformance']
---

Both backends collect **every** recoverable parse error in one pass instead of stopping at the first.

Rust `compile_to_wire_all` (`native/stem_compile/src/lib.rs`) and Elixir `Stem.Parser.parse_all/2` accumulate invalid expressions, reserved operators (`||`/`&&`), unknown/recursive partials, and bad block or partial arguments — substituting a placeholder node (a `nil` literal) so collection keeps going. A *structural* error that desyncs the token stream (an unclosed or mismatched block) still ends the pass and is reported last.

Each error is attributed to the **file** it occurred in (`"main"` or a partial name), stamped at the assembly boundary that knows the context. The fail-fast entries (`compile_to_wire`, `Stem.parse/2`) are unchanged: collection always accumulates and they simply surface the first error in source order.

The playground's Problems pane lists them all (deduped by file:line:col), each clickable to its tab. `mix stem.native.compile_diff` gains an error-accumulation parity check: both backends must report the same errors (count + ordered file attribution) for multi-error templates — wording differs per backend, so the gate compares files, not message text.

## Links

- [[Cross-Backend Conformance Spec]] — the parity harness this extends.
- [[Native AST Compilation Pipeline]] — the assembly stage that accumulates.
- [[Playground Diagnostics Dock]] — where the accumulated errors surface.
## Links

