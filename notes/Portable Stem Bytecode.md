---
id: 20260522221115
aliases: []
tags: ['architecture', 'compiler', 'native', 'bytecode']
---

A second `Stem.AST` backend lowers templates to a versioned, capability-gated bytecode that a small interpreter renders without host callbacks.

## What

- A new backend beside `Stem.Compiler` consumes the same `Stem.AST` and emits a flat, versioned instruction stream (working name `stem-bc/v1`) instead of quoted Elixir. The parser and AST are reused unchanged ([[Native AST Compilation Pipeline]]).
- Opcodes are structural and self-contained: `EMIT text`, `RESOLVE path`, `CALL transformer/arity`, `ESCAPE mode`, `EMIT_TOP`, plus block control `JUMP_IF_FALSY`, `ITER_BEGIN`/`ITER_NEXT`/`ITER_END`, and scope push/pop for `../` and `as |x|`. The interpreter holds full render context (`this`, `@index`, `@key`, parent scope), so context-aware built-ins (`lookup`, `default`, `truncate(x, 20)`) work without a narrow FFI signature.
- A header carries the format version and a **capability bitmask** (Minimum / Strings / Collections / Predicates) mirroring the runtime allowlist; Minimum is always on, the rest opt-in (see [[Helper Capability Groups]]).
- Data crosses as one MessagePack/CBOR buffer of assigns; output returns as UTF-8 bytes. `ESCAPE` is applied by the interpreter from the shared escaping table (see [[Cross-Backend Conformance Spec]]).

## Why

- Emitting *data* (bytecode) instead of *source* avoids string-codegen hazards and keeps one interpreter compiled once — no `rustc`-per-template, no `dlopen` of generated code.
- A self-contained instruction set means structural rendering needs **no per-node host callback**, removing the FFI bottleneck that sinks a closure-based native core (see [[Native Backend Strategy]]).
- Built-in transformers are pure data ops and are reimplemented in the interpreter's native stdlib; **custom host closures are not lowerable** and must fail loudly at compile (`Stem.Bytecode.UnsupportedError`) rather than diverge silently. This preserves the capability boundary off-BEAM.
- A bytecode form is independently valuable even without a native runtime: a serializable, inspectable, cacheable, signable compiled template.

## How

- Add `Stem.Bytecode.compile/2` (AST → iodata), `Stem.Bytecode.disasm/1`, and a reference `Stem.Bytecode.VM` in Elixir. Validate `VM(compile(ast), data) == Compiler(ast).(data)` over the conformance vectors before any Rust exists.
- Keep the opcode set minimal and versioned; reject unknown/host transformers at compile with a clear "render on the BEAM backend or pre-resolve the value in assigns" message.
- Treat the capability bitmask as the single gate for transformer availability; never widen the default beyond Minimum.

## Links

- [[Native Backend Strategy]] - Why bytecode over transpilation, and the phased rollout.
- [[Cross-Backend Conformance Spec]] - The escaping, truthiness, and path rules the VM must satisfy.
- [[Native AST Compilation Pipeline]] - The shared parser/AST and the sibling quoted-Elixir backend.
- [[Helper Capability Groups]] - The allowlist the capability header encodes.
## Links

