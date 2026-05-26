---
id: 20260526134248
aliases: []
tags: ['playground', 'tooling', 'design', 'stringtemplate', 'wasm']
---

**Shipped (2026-05-26).** The Stem WASM playground gained StringTemplate 4 (ST4) Inspector-style introspection, complementing its CodeMirror 6 source-map provenance with data-state introspection and an explicit error surface.

This is the umbrella note; each pane is now its own single-thought note:

- [[Playground Diagnostics Dock]] — persistent bottom pane listing all problems (compile, data, capability), replacing the transient status lane.
- [[Playground Bytecode Disassembly View]] — an Output-pane view rendering the `stem-bc/v1` wire program as `disasm` text.
- [[Playground Context Inspector]] — click an output segment to snapshot the render context (`@this`/`@parent`/`@root`, locals, iteration vars), one per loop iteration.
- [[Partial Dependency Graph & AST Viewer]] — the partial DAG and per-file pre-expansion AST (the "Syntax Tree" tab).

## Why

The playground was source-accurate but data-opaque: you could see *where* output came from, but not the data state that produced it, and errors vanished into a one-line lane. ST4's Inspector proved AST trees, attribute scopes, and bytecode panes make a template engine debuggable, and Stem already had the wire bytecode and byte-span maps to support most of it cheaply.

## How

Two of the features needed data the WASM layer did not expose, so the engine grew two introspection primitives — implemented in Rust and mirrored in the Elixir reference (parity is a hard requirement):

- **`inspect_at(program, data, groups, {file, start, end})`** — see [[Playground Context Inspector]].
- **`parse_ast(source)`** — pre-expansion AST; see [[Partial Dependency Graph & AST Viewer]].

The Diagnostics Dock and Bytecode View are pure frontend over errors/wire the playground already receives.


## Links

- [[Rust Host API for Native Backend]] — the host that grew these introspection exports at Elixir parity.
- [[Each Index Variables and Block Params]] — the iteration vars the Context Inspector surfaces.
- [[Expanded Contracts]] — another ST4-inspired feature in the same lineage.
