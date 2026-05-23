---
id: 20260522221132
aliases: []
tags: ['testing', 'security', 'native', 'conformance']
---

One authoritative specification and a vector suite, generated from the Elixir reference, keep every Stem backend's rendering byte-identical.

## What

- A versioned spec that pins the rendering semantics shared by all backends: the **single HTML-escaping table** (`&`, `<`, `>`, `"`, `'`), the Handlebars truthiness set ([[Handlebars Truthiness Semantics]]), path/segment resolution rules, the capability set, and contract semantics ([[Expanded Contracts]]).
- A machine-readable conformance suite under `conformance/` of `{template, data, caps, expected}` vectors, **generated from the Elixir reference** so the BEAM implementation is the oracle.
- A differential harness: any second implementation (the Elixir bytecode VM, the Rust/WASM core) must reproduce every vector byte-for-byte, plus property-based differential fuzzing (StreamData-generated AST + data) asserting cross-backend equality — extending [[Property and Fuzz Testing Strategy]].

## Why

- The original native proposal duplicated `escape_html`, and the copy already dropped `"` and `'` — a live XSS divergence. A single spec'd escaping table tested across backends is the only way to stop a security primitive drifting (see [[HTML Escaping Behavior]]).
- Stdlib transformers diverge across runtimes (`String.upcase` vs Rust `to_uppercase` on locale edges; number/float formatting; map iteration order), so fuzzing one pipeline is insufficient — parity must be asserted *differentially*.
- The spec, not an engine, is the durable cross-language asset: any host (Python, Node, JVM) can build a clean-room renderer against it (see [[Universal Architecture Principles]]).

## How

- This is Phase 0 of the native plan ([[Native Backend Strategy]]): write the spec and emit vectors from the Elixir reference before any second renderer exists.
- Run the same vectors in CI against every backend; a divergence fails the build like any other gate (see [[CI Security Gates]]).
- When adding a transformer or changing escaping, update the spec and vectors first; treat the Elixir output as authoritative until a backend disagrees for a documented reason.

## Known divergences (tracked, deferred)

These are points where the native (Rust/WASM) PoC does **not** yet match the BEAM oracle byte-for-byte. They are deliberately kept out of the conformance corpus and the differential fuzzer (which restricts inputs to integers + ASCII + the parity transformer set), so the green gates do **not** prove parity here. Each is a known gap, not a silent surprise.

- **G2 — float formatting.** The BEAM renders floats via `String.Chars.to_string/1` → Erlang `:erlang.float_to_binary(f, [:short])`, e.g. `1.0e8` for `100000000.0` and `1.0` for `1.0`. The native VM renders a float via serde_json's `Number` display (the `to_string` helper in [lib.rs](../native/stem_native/src/lib.rs)), whose fixed-vs-scientific threshold and exponent style differ. The integer path agrees; only floats diverge. *Plan:* port Erlang's short-float formatting rule (shortest round-trip digits — which Rust also produces — then Erlang's notation/exponent placement) and add float vectors to the corpus. The exact Rust output forms still need characterizing against a BEAM table before implementation.
- **G4 — Unicode casing.** `upcase`/`downcase` match only for ASCII; the fuzzer restricts inputs to ASCII so non-ASCII casing (locale/Turkish-i, ß, etc.) is untested and may diverge.
- **G5 — large-map `{{#each}}` order.** The BEAM iterates >32-key maps in hash order; the corpus uses single-key maps to stay deterministic. Small maps and the native BTreeMap both sort, so divergence is confined to large maps.
- **G6 — heterogeneous `sort`/`sort_by`.** The native `value_cmp` is an *approximate* Elixir term ordering; mixed-type lists may order differently.

Sequencing: these are gated behind the parity-matrix work (generate a per-construct/type match/divergent/unsupported table from the corpus generator) so frequency data, not guesswork, ranks them. Until then, treat float/Unicode/large-map/mixed-sort output from the native backend as **unverified**, and prefer the BEAM backend when byte-parity matters. Render-time *unsupported* features (non-parity transformers, `url`/custom escape, keyword args) are a separate, already-handled class — they return a structured error rather than diverging silently ([[Portable Stem Bytecode]]).

## Links

- [[Native Backend Strategy]] - The plan this spec anchors (Phase 0).
- [[Portable Stem Bytecode]] - The first non-default backend the vectors validate.
- [[HTML Escaping Behavior]] - The escaping rule the spec table pins.
- [[Property and Fuzz Testing Strategy]] - Extended here into differential fuzzing.
- [[Handlebars Truthiness Semantics]] - The falsy set the spec fixes across backends.
