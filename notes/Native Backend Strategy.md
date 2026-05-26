---
id: 20260522221055
aliases: []
tags: ['architecture', 'compiler', 'native', 'decision', 'security']
---

Stem's native backend ships templates as portable bytecode run by one small interpreter, not transpiled Rust source, targeting cross-language parity rather than BEAM speed.

## What

- Decision: **reject** the "transpile `Stem.AST` → Rust source → LLVM, integrated into mainline" proposal. **Adopt**: lower the existing `Stem.AST` to a portable bytecode (see [[Portable Stem Bytecode]]), executed by one small interpreter compiled once — an Elixir reference VM first, then a Rust core compiled to a single WASM module.
- The BEAM backend ([[Native AST Compilation Pipeline]]) is unchanged and stays the default; native is purely additive.
- The interpreter boundary is bytes-in / bytes-out: `render(program_bytes, data_msgpack, caps) -> utf8_bytes`. No per-node host callbacks, no shared pointers, no `unsafe` FFI, no per-template native compilation.
- The goal is **parity and portability** — render the same template identically off-BEAM (browser, edge worker, Python/Node) — **not** beating the BEAM, which wins locally.

The Rust-host API update and typed embedding surface live in [[Rust Host API for Native Backend]].

## Why

- Transpiling an AST to a high-level language's *source text* is string codegen with its own escaping hazards, couples two implementations forever, and drags `rustc`/LLVM into the build pipeline (per-template native artifacts, nondeterministic builds, larger supply-chain surface).
- Stem transformers are **host closures** (`(args, ctx)`; `json` calls Elixir `JSON.encode!`, `i18n.t` delegates to the host translator), so they cannot be C function pointers. A closure-based "native core" would call back into the BEAM per dynamic node, re-creating the FFI bottleneck it claimed to remove. Bytecode plus a native stdlib sidesteps this (see [[Portable Stem Bytecode]]).
- SSTI is already closed on the BEAM via the compile-time-only model ([[Compile-Time-Only Security Model]]) and the Minimum-only capability allowlist ([[Helper Capability Groups]]). A native engine adds no security; an `unsafe`-FFI / `dlopen`-generated-code design would *regress* it. The bytes-in/bytes-out plus WASM-sandbox boundary preserves the safety we have.
- The durable, low-risk asset is portability of *semantics*, captured by a spec, not a second engine (see [[Cross-Backend Conformance Spec]]).

## How

Deliver in independently-useful phases:

1. **Spec + conformance vectors** — pin the authoritative rules and generate vectors from the Elixir reference. See [[Cross-Backend Conformance Spec]].
2. **Bytecode + pure-Elixir VM** — prove `VM(compile(ast), data) == Compiler(ast).(data)` and ship a serializable compiled-template artifact. See [[Portable Stem Bytecode]].
3. **Rust interpreter -> single WASM module** — port the VM and native stdlib, then run the same vectors and differential fuzzing. See [[Native Backend Phase 2 Gate]].
4. **Host shims** — thin Python/Node loaders plus an edge-render demo.

Gate phases 3-4 on a real non-BEAM/edge demand signal and a benchmark; until then they stay feature-gated and out of mainline. Host transformers mirror the BEAM `transformers:` binding, but embedder-specific logic stays out of the conformance corpus.

## Links

- [[Portable Stem Bytecode]] - The compiled form this strategy produces.
- [[Cross-Backend Conformance Spec]] - The authoritative semantics both backends honor.
- [[Native AST Compilation Pipeline]] - The unchanged BEAM backend this runs beside.
- [[Universal Architecture Principles]] - Why Stem's constraints are portable in the first place.
- [[Compile-Time-Only Security Model]] - The existing trust boundary the native path must not weaken.
- [[Helper Capability Groups]] - The Minimum-only allowlist the bytecode capability header mirrors.
- [[Rust Host API for Native Backend]] - The typed Rust embedding surface and first-class-host update.
