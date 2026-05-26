---
id: 20260523235200
title: "Native Playground IDE UX"
aliases: []
tags: ['native', 'playground', 'ux', 'editor']
---

The browser playground in `native/web/` now uses CodeMirror 6 and a split-pane layout to behave like a lightweight IDE while preserving the compile-and-render safety model.

## What

- The old overlay textarea/highlighter was replaced by CodeMirror editors: a tabbed template/partials editor (`html()` mode) and a data editor whose own tab bar switches between the YAML data and an optional JSONata transform.
- Example data ships on disk as `data.yaml`; the editor loads it verbatim and the run loop parses it with js-yaml. The parser is vendored once at `native/web/vendor/js-yaml.mjs` and shared by both the browser page and the Node validator, so they parse identically with no install or network.
- An example may add a `transform` (a JSONata expression in `examples/<id>/transform.jsonata`) that maps raw YAML stats into the view-model the template renders. JSONata is chosen because it is sandboxed (no JS, DOM, or network), so it stays safe to run from editable and shared content; it is vendored at `native/web/vendor/jsonata.mjs`. The same step runs in the validator, so browser and Node agree on the view-model. The data pane shows the transform in its own "transform · JSONata" tab; the YAML tab keeps highlighting while the transform tab drops it. The two tab sources are tracked separately (`yamlSrc`/`transformSrc`) and both ride along in the shareable URL hash.
- Compile errors from the WASM compiler (`{message,start,end}` byte spans) map to inline diagnostics in the template editor and a status line with line/column coordinates.
- The output pane offers four views: "Plain Text", "HTML Preview", "Markdown Preview", and "View Model". The iframe sandbox (no scripts; CSP `default-src 'none'`) is the trust boundary for the preview modes.
- The Plain Text and View Model views share one read-only CodeMirror editor rather than a hand-built `<pre>`, keeping output highlighting and rendering inside the same trust boundary as the source editors.
- The output view selector and the highlight picker are compact `<select>` dropdowns (the four views no longer occupy a segmented button row).
- The run loop is debounced; `Cmd/Ctrl+Enter` forces an immediate render. Switching template tabs only changes which source is displayed and never recompiles.
- A command palette (`Cmd/Ctrl+Shift+P`) exposes common quick actions.

The output-language picker and bidirectional source-map behavior are tracked in [[Playground Output Provenance UX]].

## Why

- The playground is the most visible proof of native parity, so editor ergonomics matter for adoption and debugging.
- Source-map highlighting makes partial-heavy output legible: you can trace any rendered byte back to the exact template/partial that produced it.
- Sharing one vendored YAML parser keeps the browser and the validator honest about what the examples mean, offline.

## How

- Shared helpers live in `native/web/playground_utils.mjs` (debounce, UTF-8 byte-span mapping, hash state encode/decode); browserless coverage in `native/web/playground_utils.test.mjs`.
- Programmatic editor doc swaps (tab switch, example load, hash restore) are tagged with a CodeMirror annotation the update listeners ignore, so only genuine edits and source-set changes recompile.
- Native render + source-map parity remains validated by `native/web/validate.mjs` and `mix stem.native.verify`.

## Links

- [[Native Backend Strategy]] - Native architecture and safety boundaries.
- [[Portable Stem Bytecode]] - Bytecode compilation model used by the playground compiler.
- [[Native Backend Phase 2 Gate]] - Production gate criteria remain unchanged by this UX work.
- [[Playground Output Provenance UX]] - Output highlighting and source-map interaction details.
