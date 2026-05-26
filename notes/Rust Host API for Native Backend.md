---
id: 20260526143003
title: "Rust Host API for Native Backend"
aliases: []
tags: ['native', 'rust', 'api', 'architecture']
---

Rust is a first-class Stem host: a typed in-process API layered over the same native core that still serves the Elixir conformance seam.

## What

The original native plan framed Rust and WASM as portability-only outputs behind a bytes-in / bytes-out boundary. That gate is lifted for trusted in-process Rust embedding: the JSON boundary remains the Elixir oracle seam (`handle`, `handle_with_host`, the `stem_native error:` sentinel), while Rust callers use typed APIs — `compile() -> Result<Program, CompileError>` and `Program::render(&Value, &RenderOptions) -> Result<String, RenderError>`. Capabilities move through typed `Group` values; host extensions through `RenderOptions::with_host`.

## Browser surface (wasm-bindgen)

The hand-rolled `stem_alloc`/`stem_render` linear-memory marshalling is gone; the browser surface is **wasm-bindgen + serde-wasm-bindgen** (JS objects cross directly). The exports the playground consumes:

- `compile(source, partials, map)` → wire program, or throws `{ errors: [{message, file, start, end}] }` — every recoverable error (see [[Recoverable Parse Error Accumulation]]).
- `render(program, data, groups, map)` → output (+ source-map segments with `map`).
- `parse_ast(source)` → pre-expansion `stem-ast/v1` tree (the dependency graph + [[Partial Dependency Graph & AST Viewer]]).
- `inspect_at(program, data, groups, target)` → render-context snapshots ([[Playground Context Inspector]]).
- `version()` → the build version ([[Centralized Project Version]]).

Compile-time macros (`stem!`) also shipped, so Rust compiles templates to bytecode at build time.

## Why

Trusted Rust embedding has different ergonomics from the untrusted browser/FFI path: a typed API suits the rlib, while the byte boundary stays the security and conformance seam. Custom transformers already enter as host function pointers, acceptable for trusted embedding.


## Links

- [[Native Backend Strategy]] — the strategy note this refines.
- [[Native Backend Phase 2 Gate]] — the production gate for the native path.
- [[Portable Stem Bytecode]] — the program model shared by the typed and JSON surfaces.
- [[Playground Inspector Suite]] — the consumer of the `parse_ast`/`inspect_at` exports.
