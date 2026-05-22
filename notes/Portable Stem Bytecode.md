---
id: 20260522221115
aliases: []
tags: ['architecture', 'compiler', 'native', 'bytecode']
---

A second `Stem.AST` backend (`Stem.Bytecode`) lowers templates to a versioned, capability-aware `Stem.Bytecode.Program` that `Stem.Bytecode.VM` renders with output identical to the compiled backend.

## What

- A backend beside `Stem.Compiler` consumes the same `Stem.AST` and emits a `Stem.Bytecode.Program` (version `stem-bc/v1`) — a list of structured instructions, not quoted Elixir. Block instructions carry their bodies as nested instruction lists. The parser and AST are reused unchanged ([[Native AST Compilation Pipeline]]).
- The instruction set covers the whole structured language: `:text`, `:emit` (a `value_op` plus its escape mode), and the blocks `:if`, `:each`, `:with` (`{{#unless}}` lowers to an `:if` with swapped branches). A `value_op` is a small evaluation plan: literals, `:assign` (top-level; `../x` lowers the same), `:local` (block parameter), `:this`/`:index`/`:key`, `:get` (dotted-path access), and `:call` (transformer; pipelines nest). Lowering is scope-aware, mirroring `Stem.Expression.to_source/2`: a bare identifier is an `:assign` at top level but `{:get, {:this}, …}` inside an `each`.
- Regions are extracted before their siblings compile, and a `{{yield}}` inlines the region's compiled instructions at the yield site (with a recursion guard), so no runtime yield instruction is needed.
- The program records `:capabilities` (built-in groups it references) and `:host_transformers` (referenced names in no group) so a non-BEAM consumer can confirm support (see [[Helper Capability Groups]]).
- Only two constructs are out of scope and raise `Stem.Bytecode.UnsupportedError`: arbitrary Elixir (`allow_elixir_expressions: true`) and a top-level `this` (which the compiled backend also rejects as unbound).

## Why

- Emitting *data* (bytecode) instead of *source* avoids string-codegen hazards and keeps one interpreter compiled once — no `rustc`-per-template, no `dlopen` of generated code.
- The Phase-1 Elixir VM *reuses* host primitives — `Stem.Runtime.fetch_assign!/3`, `Stem.Runtime.is_truthy/1`, `Stem.Builtins.each/3`, `Stem.Transformers.invoke/3`, `Stem.Escaping` — so assign resolution, block semantics, dispatch, and escaping match by construction (see [[Native Backend Strategy]]).
- Capability gating is identical because the VM calls `Stem.Transformers.invoke/3`: the Minimum-only default and loaded groups apply, and custom `transformers:` work in the VM. Only a future non-BEAM core must reject a program listing `host_transformers` — hence the metadata.

## How

- `compile/2`, `disasm/1`, and `VM.render/2` are implemented in Elixir. A differential conformance suite asserts `VM(compile(ast), data) == Stem.compile_string(...)` across a corpus exercising text, expressions, every block helper, block parameters, block-scoped references, regions, and yields, backed by property-based fuzzing.
- Block instructions stay structured (nested lists) rather than a flat jump form — far less error-prone for the reference VM and still trivially serializable. A binary wire encoding (MessagePack/CBOR) is deferred to the native phase.

## Links

- [[Native Backend Strategy]] - Why bytecode over transpilation, and the phased rollout.
- [[Cross-Backend Conformance Spec]] - The escaping, truthiness, and path rules the VM must satisfy.
- [[Native AST Compilation Pipeline]] - The shared parser/AST and the sibling quoted-Elixir backend.
- [[Helper Capability Groups]] - The allowlist the program's capability metadata mirrors.
