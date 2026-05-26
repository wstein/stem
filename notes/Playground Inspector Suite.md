---
id: 20260526134248
aliases: []
tags: ['playground', 'tooling', 'design', 'stringtemplate', 'wasm']
---

The Stem WASM playground gains StringTemplate 4 (ST4) Inspector-style introspection: a persistent diagnostics pane, a bytecode disassembly view, and an on-demand attribute/context inspector. This complements the existing CodeMirror 6 source-map provenance with data-state introspection and an explicit error surface.

## What

Four playground panes/views, layered on the existing byte-span source-map machinery (`native/web/playground_utils.mjs`, `lastSegViews` in `native/web/index.html`):

- **Diagnostics & Security Pane** — a persistent, resizable bottom pane replacing the transient status lane for error history. Compile errors (`{message, start, end}`) and capability-group violations (the `stem_native error:` sentinel, which already names the missing group) are routed here and badged distinctly. The editor lint gutter stays for inline marks.
- **Bytecode Disassembly View** — a fifth Output-pane dropdown option (after Plain Text, HTML, Markdown, View Model). It renders the `stem-bc/v1` wire program (already returned by the WASM `compile()`) as a `disasm`-style text walk, mirroring `Stem.Bytecode.disasm/1`. No engine call needed for v1.
- **Context Inspector** — clicking an output segment triggers a targeted re-execution that returns the active context (`@this`/`@parent`/`@root`, locals, and the `@index`/`@index1`/`@key`/`@first`/`@last` iteration vars) for the matching instruction. Re-execute-on-demand, not continuous tracing, to avoid memory bloat. The UI relabels the Rust `Ctx` struct fields (`this`/`parent`/`root`/`locals`) to the current `@`-prefixed template names.
- **File-Based AST Viewer** (Phase 2) — see [[Partial Dependency Graph & AST Viewer]].

## Why

The playground was source-accurate but data-opaque: you could see where output came from, but not the data state that produced it, and errors vanished into a one-line status lane. ST4's Inspector proved that AST trees, dynamic attribute scopes, and bytecode panes make a template engine debuggable; Stem already has the wire bytecode and byte-span maps to support most of this cheaply.

## How

Two of the four features need data the WASM layer does not expose today, so the engine grows two introspection primitives — **implemented in Rust and mirrored in the Elixir reference (parity is a hard requirement)**:

- **`inspect_at(program, data, groups, {file, start, end})`** — re-runs the VM and snapshots the `Ctx` every time an instruction whose `src` matches the clicked segment executes. Loops execute the body N times, so it returns a **list** of snapshots the UI can step through. Reuses `scope_context` semantics for partial-scope rebinding.
- **`parse_ast(...)`** — pre-expansion AST; powers the Context Inspector's sibling features and the Phase-2 viewer (see [[Partial Dependency Graph & AST Viewer]]).

The Diagnostics Pane and Bytecode View are pure frontend, built on errors/wire output the playground already receives.

## Links

- [[Partial Dependency Graph & AST Viewer]] - The dependency-graph + per-file AST half of the same effort.
- [[Native Backend Phase 2 Gate]] - The Rust host that now grows full Elixir parity, including these introspection exports.
- [[Each Index Variables and Block Params]] - The iteration vars (`@index`/`@index1`/`@first`/`@last`) the Context Inspector surfaces, themselves modelled on ST4.
- [[Expanded Contracts]] - Another ST4-inspired feature (Group Interfaces) in the same lineage.
## Links

