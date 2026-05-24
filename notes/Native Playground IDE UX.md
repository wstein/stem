---
id: 20260523235200
aliases: []
tags: ['native', 'playground', 'ux', 'editor']
---

The browser playground in `native/web/` now uses CodeMirror 6 and a split-pane layout to behave like a lightweight IDE while preserving the compile-and-render safety model.

## What

- The old overlay textarea/highlighter was replaced by CodeMirror editors: a tabbed template/partials editor (`html()` mode) and a data editor (`yaml()` mode).
- Example data ships on disk as `data.yaml`; the editor loads it verbatim and the run loop parses it with js-yaml. The parser is vendored once at `native/web/vendor/js-yaml.mjs` and shared by both the browser page and the Node validator, so they parse identically with no install or network.
- Compile errors from the WASM compiler (`{message,start,end}` byte spans) map to inline diagnostics in the template editor and a status line with line/column coordinates.
- The output pane offers two views: "Rendered" (the output as text, segment-mapped to its source) and "Preview" (the same output in a locked-down iframe).
- Source-map provenance: the compiler can emit per-instruction `src` spans and the renderer a segment map (see [[Native AST Compilation Pipeline]]). The link is bidirectional. Output→source: hovering a run shows a tooltip naming its file/tag and highlights the originating span in the template editor (or tints its tab when that file is not shown); clicking jumps the caret there, hovering never moves it. Source→output: moving the template caret highlights the output run(s) it produced.
- The run loop is debounced; `Cmd/Ctrl+Enter` forces an immediate render. Switching template tabs only changes which source is displayed and never recompiles.
- A command palette (`Cmd/Ctrl+Shift+P`) exposes common quick actions.

## Why

- The playground is the most visible proof of native parity, so editor ergonomics matter for adoption and debugging.
- Source-map highlighting makes partial-heavy output legible: you can trace any rendered byte back to the exact template/partial that produced it.
- Sharing one vendored YAML parser keeps the browser and the validator honest about what the examples mean, offline.

## How

- Shared helpers live in `native/web/playground_utils.mjs` (debounce, UTF-8 byte-span mapping, hash state encode/decode); browserless coverage in `native/web/playground_utils.test.mjs`.
- Programmatic editor doc swaps (tab switch, example load, hash restore) are tagged with a CodeMirror annotation the update listeners ignore, so only genuine edits and source-set changes recompile.
- The hover link-highlight is a CodeMirror `StateField` decoration (not a selection), dirty-checked per run and suppressed while a render is pending so it never points at stale offsets.
- Native render + source-map parity remains validated by `native/web/validate.mjs` and `mix stem.native.verify`.

## Links

- [[Native Backend Strategy]] - Native architecture and safety boundaries.
- [[Portable Stem Bytecode]] - Bytecode compilation model used by the playground compiler.
- [[Native Backend Phase 2 Gate]] - Production gate criteria remain unchanged by this UX work.
