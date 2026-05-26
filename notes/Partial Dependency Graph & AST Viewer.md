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

The graph edges and the per-file AST both need the **pre-expansion** structure, which the wire bytecode does not retain. So both backends expose a `parse_ast` entry that stops before partial inlining: `{{> name}}` stays a `partial` node, every node carries its `src`, and expressions keep their written syntactic form.

- **Rust**: `parse_ast_to_wire` / the `parse_ast` wasm-bindgen export (`stem_compile`/`stem_native`), an `Asm.expand` flag, and a `Node::Partial` variant.
- **Elixir**: `Stem.Parser.parse_ast/2` (a `:no_expand` sentinel threaded through the existing `collect/4`) plus `Stem.AST.to_wire/1`. Literals resolve through the shared `Stem.Bytecode.literal_value/1` so the two backends agree on literal values.

## stem-ast/v1 conceptual contract

The two backends agree on the **node and expression kinds** (conceptual parity), not byte-for-byte output. `src` is backend-native provenance: **byte spans** (`{start, end}`) in Rust, **line/column** in Elixir.

- Nodes: `text`, `emit` (`expr` + `escape`), `if`, `unless`, `each`/`with` (`subject`, `params`, `body`, `else`), `region`, `yield`, `partial` (`name`, `context`, `hash`), `partial_scope`.
- Expressions: `identifier`, `path` (`segments`), `context` (`kind` ∈ this/parent/root, `path`), `index`/`index1`/`key`/`first`/`last`, `lit` (`value`), `call` (`name`, `args`), `pipeline` (`lhs`, `stages`); args are `{kind: positional|keyword, ...}`.

**Known Rust↔Elixir differences (pending the Rust parser rewrite, see [[Native: Rust first-class]]):** Rust currently collapses `{{#unless}}` into a swapped `if` node and pre-resolves the default `{{ }}` escape to `"html"`, whereas the Elixir reference keeps a distinct `unless` node and the `"default"` escape atom. Elixir is the canonical model; the `nimble_parsec_rs`-based Rust parser rewrite is what brings Rust fully in line.


## Links

- [[Playground Inspector Suite]] - The panes (diagnostics, bytecode, context) half of the same effort.
- [[Helper and Partial Resolution]] - How partials expand inline and how `partial_scope` rebinds hash args.
- [[Native AST Compilation Pipeline]] - Where partial expansion happens; `parse_ast` taps the stage just before it.
