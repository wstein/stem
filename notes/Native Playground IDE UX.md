---
id: 20260523235200
aliases: []
tags: ['native', 'playground', 'ux', 'editor']
---

The browser playground in `native/web/` now uses CodeMirror 6 and a split-pane layout to behave like a lightweight IDE while preserving the compile-and-render safety model.

## What

- The old overlay textarea/highlighter was replaced by CodeMirror editors: a tabbed template/partials editor (`html()` mode) and a data editor whose own tab bar switches between the YAML data and an optional JSONata transform.
- Example data ships on disk as `data.yaml`; the editor loads it verbatim and the run loop parses it with js-yaml. The parser is vendored once at `native/web/vendor/js-yaml.mjs` and shared by both the browser page and the Node validator, so they parse identically with no install or network.
- An example may add a `transform` (a JSONata expression in `examples/<id>/transform.jsonata`) that maps the raw YAML stats into the drawable view-model the template renders — a Model→Controller→View split. JSONata is chosen because it is a sandboxed expression language (no JS, DOM, or network), so it stays safe to run from editable and shared content; it is vendored at `native/web/vendor/jsonata.mjs`. The same step runs in the validator, so browser and Node agree on the view-model. The data pane shows the transform in its own "transform · JSONata" tab; the YAML tab keeps highlighting while the transform tab drops it (language swapped live via a CodeMirror compartment). The two tab sources are tracked separately (`yamlSrc`/`transformSrc`) and both ride along in the shareable URL hash.
- Compile errors from the WASM compiler (`{message,start,end}` byte spans) map to inline diagnostics in the template editor and a status line with line/column coordinates.
- The output pane offers three views: "Plain Text" (the output as text, segment-mapped to its source), "HTML Preview" (the output HTML in a locked-down iframe), and "Markdown Preview" (the output interpreted as Markdown in the same iframe via a vendored `marked`). The iframe sandbox (no scripts; CSP `default-src 'none'`) is the trust boundary for both preview views.
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
- The Plain Text source view maps the renderer's byte-offset segments to character indices in a single forward pass (a monotonic cursor over the output computing UTF-8 byte widths arithmetically), instead of rescanning the whole output per segment. That turned the infographic's ~860-segment render from multi-second to instant.
- Native render + source-map parity remains validated by `native/web/validate.mjs` and `mix stem.native.verify`.

## Links

- [[Native Backend Strategy]] - Native architecture and safety boundaries.
- [[Portable Stem Bytecode]] - Bytecode compilation model used by the playground compiler.
- [[Native Backend Phase 2 Gate]] - Production gate criteria remain unchanged by this UX work.
