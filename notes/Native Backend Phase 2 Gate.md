---
id: 20260523002744
aliases: []
tags: ['architecture', 'native', 'performance', 'decision']
---

The Rust/WASM native core stays gated for *production* on a BEAM perf basis, but a proof-of-concept now exists (`native/`) and validates byte-for-byte against the conformance corpus.

## What

- A **PoC** Rust→`wasm32-wasip1` renderer lives in `native/` (crate `stem_native`, Node WASI runner `native/run.mjs`). It consumes `Stem.Bytecode.to_wire/1` programs and renders the structured language off the BEAM; `mix stem.native.verify` confirms 27/27 conformance vectors match the BEAM reference byte-for-byte. This proves the architecture in [[Native Backend Strategy]].
- A **production** native core is still gated behind two conditions: (1) a real non-BEAM or edge consumer that must render Stem off the BEAM, and (2) a benchmark showing the compiled BEAM backend is a bottleneck. The PoC's stdlib is a subset and is not production-hardened.
- `bench/render.exs` (run with `mix run bench/render.exs`) is that benchmark: it compares the compiled backend against the bytecode VM, compile-once / render-many, for a simple and a loop-heavy template.

## Why

- The compiled backend runs as native BEAM code with no serialization boundary; the benchmark shows it renders at least as fast as the VM for both templates. A native core would have to beat that *and* pay to serialize assigns across an FFI/WASM boundary, so for a BEAM host it would be slower, not faster.
- The only real case for the native core is therefore portability — a non-BEAM or edge host with no in-process compiler — not BEAM speed. Building it on a perf hunch would add a second engine, a build pipeline, and a parity-test burden for no BEAM benefit (see [[Native Backend Strategy]]).

## How

- Before starting Phase 2, run `bench/render.exs` and confirm a concrete, measured regression in the compiled path on representative templates, and name the non-BEAM consumer that needs it.
- Keep any native work in a separate experimental repo, feature-gated, validated against [[Cross-Backend Conformance Spec]]; never ship per-template native artifacts into mainline.

## Links

- [[Native Backend Strategy]] - The plan this gate belongs to.
- [[Portable Stem Bytecode]] - The VM the benchmark compares against.
- [[Cross-Backend Conformance Spec]] - What any native core must satisfy.

