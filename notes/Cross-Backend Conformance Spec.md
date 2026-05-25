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

## Transformer parity

The native core implements the **full** built-in transformer stdlib — Minimum, Strings, Collections, and Predicates — byte-for-byte, gated by capability group exactly as the BEAM dispatcher gates the `transformers:` binding (Minimum is the always-on floor; the rest are opt-in; see [[Helper Capability Groups]]). The render request carries the loaded groups in its `transformers` list, and a call into an unloaded group is refused before render with a group-naming message — the native analogue of `Stem.Transformers` raising. `json` and `inspect` now render natively over the JSON value domain, and `log` renders to `""` (its BEAM output). The `i18n` group's `t`/`translate` are **host-delegated**: no native built-in, resolved through the custom-transformer hook (a Rust `TransformerResolver`, the native analogue of the `transformers:` binding), requiring both the group and a host translator. Host transformers and computed getters live in the embedder, carry no cross-backend parity, and stay out of the corpus.

## Known divergences (tracked, deferred)

These are the remaining value-formatting points where the native (Rust/WASM) core does **not** match the BEAM oracle byte-for-byte. They are deliberately kept out of the conformance corpus and the differential fuzzer (which restricts inputs to ASCII strings, integers, floats, and the deterministic transformer domain), so the green gates do **not** prove parity here. Each is a known gap, not a silent surprise.

- **G2 — float formatting. *(Resolved.)*** Floats now render byte-for-byte. The native core decodes JSON floats with serde_json's `float_roundtrip` feature (correctly rounded to the same `f64` the BEAM holds), takes the shortest digits from the `ryu` crate (the same algorithm — and the same round-half-to-even tie-breaking — as the BEAM's `:short`), and applies Erlang's notation policy (scientific at magnitude `2^53` or when strictly shorter, decimal otherwise). Float vectors are in the corpus and the differential fuzzer exercises floats across a wide magnitude range. See `format_float`/`shortest_digits` in [lib.rs](../native/stem_native/src/lib.rs).
- **G4 — Unicode casing.** `upcase`/`downcase` match only for ASCII; the fuzzer restricts inputs to ASCII so non-ASCII casing (locale/Turkish-i, ß, etc.) is untested and may diverge.
- **G5 — map key order.** Native always sorts object keys (serde_json's BTreeMap); the BEAM iterates a map in its internal order, which varies by key **type** and **size** — notably `JSON.encode!` of an atom-keyed map is *not* sorted (e.g. `%{a: 1, b: 2}` → `{"b":2,"a":1}`), while a string-keyed one is. So `{{#each}}` over a multi-key map, `group_by`, and `json` object key order are **not** cross-backend stable; the corpus uses single-key maps to stay deterministic. (In-process differential parity still holds for any single fixed map, since the two backends are fed the same map.)
- **G6 — heterogeneous `sort`/`sort_by`.** The native `value_cmp` is an *approximate* Elixir term ordering; mixed-type lists may order differently.
- **G7 — `inspect` of maps.** Native values are always string-keyed, so a map prints as `%{"k" => v}`; the conformance harness builds atom-keyed maps from JSON, which the BEAM prints as `%{k: v}`. The two agree for any string-keyed input, so `inspect` is exercised over scalars and lists in the corpus, where the question does not arise.

Sequencing: these are gated behind the parity-matrix work (generate a per-construct/type match/divergent/unsupported table from the corpus generator) so frequency data, not guesswork, ranks them. Until then, treat Unicode-casing/large-map/mixed-sort/`inspect`-of-map output from the native backend as **unverified**, and prefer the BEAM backend when byte-parity matters. Render-time *refused* features (transformers from an unloaded group, `i18n` without a host translator, keyword args to a built-in, `url`/custom escape) are a separate, already-handled class — they return a structured error rather than diverging silently ([[Portable Stem Bytecode]]).

## Links

- [[Native Backend Strategy]] - The plan this spec anchors (Phase 0).
- [[Portable Stem Bytecode]] - The first non-default backend the vectors validate.
- [[HTML Escaping Behavior]] - The escaping rule the spec table pins.
- [[Property and Fuzz Testing Strategy]] - Extended here into differential fuzzing.
- [[Handlebars Truthiness Semantics]] - The falsy set the spec fixes across backends.
