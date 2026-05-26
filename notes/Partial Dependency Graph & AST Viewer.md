---
id: 20260526134311
aliases: []
tags: ['playground', 'partials', 'tooling', 'design', 'stringtemplate']
---

**Shipped (2026-05-26).** The playground has a visual DAG of partial inclusions and a per-file pre-expansion AST (the **Syntax Tree** tab) — the navigation half of the ST4-Inspector-style effort (see [[Playground Inspector Suite]]).

## What

- **Dependency Graph** — a floating panel (toolbar **Dependencies**) whose nodes are `main` plus each partial and whose edges are `{{> name}}` inclusions, laid out as a tidy top-down tree. Stem forbids partial recursion, so a cycle is drawn as a **red edge** with a tooltip quoting `partial recursion detected for 'X'`. Clicking a node/edge jumps to that partial's tab.
- **Syntax Tree tab** — the active file's pre-expansion AST as an indented, line-numbered outline (data sub-pane). Clicking a row highlights its source span in the editor via the byte-span path (`byteRangeToCharRange`, `setLinkHighlight`).

## Why

Stem expands partials inline at compile time, so the flattened wire bytecode loses file boundaries — it can't show "which file included which." A source-level DAG restores that structure and turns the cryptic recursion error into an obvious red loop. Per-file AST (not one monolithic tree) keeps multi-partial projects legible.

## How

Both views need the **pre-expansion** structure, which the wire bytecode doesn't retain, so both backends expose a `parse_ast` entry that stops before partial inlining: `{{> name}}` stays a `partial` node, every node carries its `src`, expressions keep their written form.

- **Rust**: `parse_ast_to_wire` / the `parse_ast` wasm export, an `Asm.expand` flag, a `Node::Partial` variant.
- **Elixir**: `Stem.Parser.parse_ast/2` (a `:no_expand` sentinel through `collect`) + `Stem.AST.to_wire/1`; literals via the shared `Stem.Bytecode.literal_value/1`.

## stem-ast/v1 conceptual contract

The backends agree on **node and expression kinds** (conceptual parity), not byte-for-byte output. `src` is backend-native: **byte spans** in Rust, **line/column** in Elixir.

- Nodes: `text`, `emit` (`expr` + `escape`), `if`, `unless`, `each`/`with` (`subject`, `params`, `body`, `else`), `region`, `yield`, `partial` (`name`, `context`, `hash`), `partial_scope`.
- Expressions: `identifier`, `path`, `context` (this/parent/root + path), `index`/`index1`/`key`/`first`/`last`, `lit`, `call`, `pipeline`; args are `{kind: positional|keyword, …}`.

**Remaining Rust↔Elixir differences** (tracked, not silent drift — see [[Native Conformance Parity Gaps]]): the Rust front-end collapses `{{#unless}}` into a swapped `if` and pre-resolves the default `{{ }}` escape to `"html"`, while Elixir keeps a distinct `unless` node and the `"default"` escape atom. Elixir is canonical; the [[Rust nimble_parsec_rs Parser Port]] is the path that converges them.


## Links

- [[Playground Inspector Suite]] — the panes (diagnostics, bytecode, context) half.
- [[Helper and Partial Resolution]] — how partials expand inline and `partial_scope` rebinds hash args.
- [[Native AST Compilation Pipeline]] — where expansion happens; `parse_ast` taps the stage just before it.
