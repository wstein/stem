---
id: 20260526134311
aliases: []
tags: ['playground', 'partials', 'tooling', 'design', 'stringtemplate']
---

The playground gains a visual DAG of partial inclusions and an on-demand per-file AST viewer, the navigation half of the ST4-Inspector-style introspection effort (see [[Playground Inspector Suite]]).

## What

- **Dependency Graph (primary navigation)** — instead of flattening the whole compilation unit into one giant AST, render a DAG whose nodes are `main` plus each partial tab and whose edges are `{{> name}}` inclusions. Because Stem forbids partial recursion, any cyclic inclusion is drawn as a **red cyclic edge** with a tooltip quoting the compiler's `partial recursion detected for 'X'` message — explaining the compile-time error visually without crashing the UI.
- **File-Based AST Viewer (on-demand, Phase 2)** — clicking a graph node opens the AST tree for that file. Clicking an AST node highlights the exact source span in the editor via the existing byte-span path (`byteRangeToCharRange`, `setLinkHighlight`).
- **Scope-boundary visualization** — the AST explicitly shows scope nodes where a partial receives hash arguments (`{{> name key=value}}`), making the `partial_scope` rebinding visible.

## Why

Stem expands partials inline at compile time and guards recursion with a call-stack check, so the flattened wire bytecode loses file boundaries — it cannot show "which file included which." A source-level DAG restores that structure, and turns the otherwise-cryptic recursion `SyntaxError` into an obvious red loop. Per-file AST (rather than one monolithic tree) keeps the view legible for multi-partial projects.

## How

The graph edges and the per-file AST both need the **pre-expansion** structure, which the wire bytecode does not retain. So the engine adds a `parse_ast(...)` export — **Rust, mirrored in the Elixir reference** — that stops before partial inlining: `{{> name}}` stays a `partial` node, and every node carries its `src` span. Elixir already produces `{:partial, name, args, meta}` pre-expansion in the parser; the Rust assembler gains a mode that emits a `Partial` node instead of calling `expand_partial`. The cyclic-edge detection runs client-side over the parsed partial references and cross-checks the compiler's recursion message. The scope-boundary nodes correspond to the Rust `{"t":"scope",...}` / Elixir `:partial_scope` constructs.

## Links

- [[Playground Inspector Suite]] - The panes (diagnostics, bytecode, context) half of the same effort.
- [[Helper and Partial Resolution]] - How partials expand inline and how `partial_scope` rebinds hash args.
- [[Native AST Compilation Pipeline]] - Where partial expansion happens; `parse_ast` taps the stage just before it.
## Links

