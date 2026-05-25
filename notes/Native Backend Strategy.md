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

### Update — 2026-05-25: Rust as a first-class host

The original framing treated the native core as gated, portability-only ([[Native Backend Phase 2 Gate]]). That gate is now **lifted**: Rust is a first-class Stem host/ecosystem alongside the BEAM. Concretely:

- The **bytes-in / bytes-out JSON boundary is demoted to the Elixir conformance seam** (`handle`/`handle_with_host`, the `stem_native error:` sentinel, the C ABI). It stays byte-identical there as the oracle interface.
- **In-process Rust uses a typed, idiomatic API**: `compile() -> Result<Program, CompileError>`, `Program::render(&Value, &RenderOptions) -> Result<String, RenderError>`, capabilities via `Group`, host extensions via `RenderOptions::with_host`. The JSON `handle*` path is now a thin wrapper over this same core (a drift-guard test asserts they agree).
- The "no per-node host callbacks" tenet was always partial for the rlib — custom transformers are host `fn` pointers (`Host`). That is intentional for trusted in-process embedding; the untrusted/WASM path still goes through the byte boundary.
- Next: **compile-time macros** (a `stem!` proc-macro compiling templates to bytecode at Rust build time) and **leaner WASM/JS interop** (wasm-bindgen / serde-wasm-bindgen instead of the hand-rolled `stem_alloc`/`stem_render` marshalling).

## Why

- Transpiling an AST to a high-level language's *source text* is string codegen with its own escaping hazards, couples two implementations forever, and drags `rustc`/LLVM into the build pipeline (per-template native artifacts, nondeterministic builds, larger supply-chain surface).
- Stem transformers are **host closures** (`(args, ctx)`; `json` calls Elixir `JSON.encode!`, `i18n.t` delegates to the host translator), so they cannot be C function pointers. A closure-based "native core" would call back into the BEAM per dynamic node, re-creating the FFI bottleneck it claimed to remove. Bytecode plus a native stdlib sidesteps this (see [[Portable Stem Bytecode]]).
- SSTI is already closed on the BEAM via the compile-time-only model ([[Compile-Time-Only Security Model]]) and the Minimum-only capability allowlist ([[Helper Capability Groups]]). A native engine adds no security; an `unsafe`-FFI / `dlopen`-generated-code design would *regress* it. The bytes-in/bytes-out plus WASM-sandbox boundary preserves the safety we have.
- The durable, low-risk asset is portability of *semantics*, captured by a spec, not a second engine (see [[Cross-Backend Conformance Spec]]).

## How

Deliver in independently-useful phases; never build a later phase on spec:

1. **Spec + conformance vectors** — pin the authoritative rules (single escaping table, truthiness, path resolution, capability set, contract semantics) and generate vectors from the Elixir reference. See [[Cross-Backend Conformance Spec]].
2. **Bytecode + pure-Elixir VM** — add a second AST backend and an Elixir interpreter; prove `VM(compile(ast), data) == Compiler(ast).(data)` across the suite. De-risks ~80% with zero Rust and yields a serializable compiled-template artifact on its own. *Landed* (`Stem.Bytecode`/`.VM` + differential conformance suite); blocks and regions/yields are next. See [[Portable Stem Bytecode]].
3. **Rust interpreter → single WASM module** — port the VM and native stdlib, run the same vectors, add differential fuzzing. *Landed* as a PoC (`native/stem_native`): the full built-in transformer stdlib gated by capability group, a host hook for custom transformers, differential fuzzing, and 35/35 conformance vectors green. See [[Native Backend Phase 2 Gate]].
4. **Host shims** — thin Python/Node loaders plus an edge-render demo.

Gate phases 3–4 on a real non-BEAM/edge demand signal and a benchmark; until then they live in a separate experimental repo, feature-gated, out of mainline. Custom host transformers *are* supported, mirroring the BEAM `transformers:` binding: a host `TransformerResolver` (consulted before the built-ins) supplies or overrides names, and `i18n`'s `t`/`translate` are delivered this way. As with the BEAM `transformers:` binding, the host logic lives in the embedder, so it carries no cross-backend byte-parity and stays out of the conformance corpus.

## Links

- [[Portable Stem Bytecode]] - The compiled form this strategy produces.
- [[Cross-Backend Conformance Spec]] - The authoritative semantics both backends honor.
- [[Native AST Compilation Pipeline]] - The unchanged BEAM backend this runs beside.
- [[Universal Architecture Principles]] - Why Stem's constraints are portable in the first place.
- [[Compile-Time-Only Security Model]] - The existing trust boundary the native path must not weaken.
- [[Helper Capability Groups]] - The Minimum-only allowlist the bytecode capability header mirrors.
