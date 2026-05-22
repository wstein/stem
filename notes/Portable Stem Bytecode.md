---
id: 20260522221115
aliases: []
tags: ['architecture', 'compiler', 'native', 'bytecode']
---

A second `Stem.AST` backend (`Stem.Bytecode`) lowers templates to a versioned, capability-aware `Stem.Bytecode.Program` that `Stem.Bytecode.VM` renders with output identical to the compiled backend.

## What

- A backend beside `Stem.Compiler` consumes the same `Stem.AST` and emits a `Stem.Bytecode.Program` (version `stem-bc/v1`) — a flat list of structured instructions, not quoted Elixir. The parser and AST are reused unchanged ([[Native AST Compilation Pipeline]]).
- The v1 instruction set covers the text-and-expression core: `{:text, binary}` and `{:emit, value_op, escape_mode}`. A `value_op` is one of `{:lit, term}`, `{:assign, atom}` (a top-level assign; parent paths `../x` lower to the same), `{:get, base, segments}` (dotted-path access), or `{:call, name, positional, keyword}` (a transformer or, nested, a pipeline). The per-expression escape mode is resolved against the `:escape` option at compile time, so the program is self-contained.
- The program records `:capabilities` (the built-in groups it references — Minimum/Strings/Collections/Predicates/I18n) and `:host_transformers` (referenced names in no built-in group) so a non-BEAM consumer can confirm it implements them (see [[Helper Capability Groups]]).
- Out-of-scope constructs — block helpers (`{{#if}}`, `{{#each}}`, …), regions, yields, block-scoped references (`this`, `@index`, `@key`, `this.x`), and arbitrary Elixir — raise `Stem.Bytecode.UnsupportedError` at compile time rather than emit a program that could diverge from the compiled backend.

## Why

- Emitting *data* (bytecode) instead of *source* avoids string-codegen hazards and keeps one interpreter compiled once — no `rustc`-per-template, no `dlopen` of generated code.
- A self-contained instruction set lets a future native core render structure without a per-node host callback (the FFI bottleneck that sinks a closure-based core, see [[Native Backend Strategy]]). The Phase-1 Elixir VM instead *reuses* the host primitives — `Stem.Runtime.fetch_assign!/3`, `Stem.Transformers.invoke/3`, `Stem.Escaping` — so parity is guaranteed by construction.
- Capability gating is identical to the compiled backend because the VM calls `Stem.Transformers.invoke/3`: the Minimum-only default and any loaded groups apply, and **custom transformers passed via the `transformers:` binding work in the Elixir VM**. Only a future non-BEAM core, which cannot call host closures, needs to reject a program that lists `host_transformers` — hence the recorded metadata.
- A bytecode form is independently valuable even without a native runtime: a serializable, inspectable, cacheable compiled template.

## How

- `Stem.Bytecode.compile/2` (AST → `Program`), `Stem.Bytecode.disasm/1`, and `Stem.Bytecode.VM.render/2` are implemented in Elixir. A differential conformance suite asserts `VM(compile(ast), data) == Stem.compile_string(...)` across a template corpus, backed by property-based fuzzing of random pipelines.
- Keep the instruction set minimal and versioned. Constructs beyond the v1 scope raise `UnsupportedError` with a "render this template with `Stem.compile_string/2`" message; the next phase adds block helpers and regions/yields by reusing `Stem.Runtime.is_truthy/2` and `Stem.Builtins`.
- A binary wire encoding (MessagePack/CBOR) and a flat jump-based control-flow form are deferred to the native phase; the Phase-1 program is the in-memory struct the Elixir VM renders.

## Links

- [[Native Backend Strategy]] - Why bytecode over transpilation, and the phased rollout.
- [[Cross-Backend Conformance Spec]] - The escaping, truthiness, and path rules the VM must satisfy.
- [[Native AST Compilation Pipeline]] - The shared parser/AST and the sibling quoted-Elixir backend.
- [[Helper Capability Groups]] - The allowlist the program's capability metadata mirrors.
