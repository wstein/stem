---
id: 20260526143003
title: "Rust Host API for Native Backend"
aliases: []
tags: ['native', 'rust', 'api', 'architecture']
---

Rust is now treated as a first-class Stem host, with a typed in-process API layered over the same native core that still serves the Elixir conformance seam.

## What

The original native plan framed Rust and WASM as portability-only outputs behind a bytes-in and bytes-out boundary. That gate is now lifted for trusted in-process Rust embedding: the JSON boundary remains the Elixir oracle seam (`handle`, `handle_with_host`, the `stem_native error:` sentinel, and the C ABI), while Rust callers use typed APIs such as `compile() -> Result<Program, CompileError>` and `Program::render(&Value, &RenderOptions) -> Result<String, RenderError>`.

Capabilities move through typed `Group` values, and host extensions are added through `RenderOptions::with_host`. The JSON `handle*` entrypoints are now thin wrappers over this same core, guarded by tests that assert they drift neither in success output nor in structured error shape.

## Why

Trusted Rust embedding has different ergonomics from the untrusted browser and FFI path. A typed API is the right interface for the rlib, while the byte boundary remains the security and conformance seam for WASM, the C ABI, and Elixir integration.

The original "no per-node host callbacks" rule was always only partially true for in-process Rust because custom transformers already enter as host function pointers. That remains acceptable for trusted embedding; the untrusted and browser-facing path still routes through the explicit boundary.

## How

Near-term follow-ons are compile-time macros, so Rust code can compile templates to bytecode at build time, and leaner WASM/JS interop via wasm-bindgen and serde-wasm-bindgen instead of the hand-rolled `stem_alloc` and `stem_render` marshalling layer.

## Links

- [[Native Backend Strategy]] - The strategy note this update refines.
- [[Native Backend Phase 2 Gate]] - The production gate for the native path.
- [[Portable Stem Bytecode]] - The program model shared by the typed and JSON surfaces.
