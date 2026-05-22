---
id: 20260523002744
aliases: []
tags: ['architecture', 'native', 'performance', 'decision']
---

The Rust/WASM native core stays gated: a BEAM render benchmark shows no performance case for it, so build it only for a non-BEAM or edge consumer.

## What

- Phase 2 of the native plan (a Rust core compiled to WASM) is **not** built. It is gated behind two conditions, both required: (1) a real non-BEAM or edge consumer that must render Stem off the BEAM, and (2) a benchmark showing the compiled BEAM backend is a bottleneck.
- `bench/render.exs` (run with `mix run bench/render.exs`) is that benchmark: it compares the compiled backend (template lowered to a BEAM function) against the bytecode VM, compile-once / render-many, for a simple and a loop-heavy template.

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

