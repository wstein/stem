---
id: 20260523235200
aliases: []
tags: ['native', 'playground', 'ux', 'editor']
---

The browser playground in `native/web/` now uses CodeMirror 6 and a split-pane layout to behave like a lightweight IDE while preserving the compile-and-render safety model.

## What

- The old overlay textarea/highlighter was replaced by two CodeMirror editors: one for templates (`html()` mode) and one for data (`json()` mode).
- The workspace is split into three panels: templates, JSON data, and output, with a responsive one-column fallback on narrow viewports.
- Compile errors from the WASM compiler (`{message,start,end}` byte spans) now map to inline diagnostics in the template editor and a status line that includes line/column coordinates.
- The run loop is debounced to reduce compile churn while typing; `Cmd/Ctrl+Enter` still forces an immediate render.
- A command palette (`Cmd/Ctrl+Shift+P`) exposes common quick actions (run, focus editor, add partial, copy link, toggle view).

## Why

- The playground acts as the most visible proof of native parity, so editor ergonomics matter for adoption and debugging.
- Inline diagnostics tighten feedback loops when iterating on partial-heavy templates.
- A command palette keeps core actions discoverable while preserving keyboard-first flow.

## How

- Shared helpers live in `native/web/playground_utils.mjs` (debounce, UTF-8 byte-span mapping, hash state encode/decode).
- Browserless utility coverage lives in `native/web/playground_utils.test.mjs`.
- Native behavior parity remains validated by `native/web/validate.mjs` and `mix stem.native.verify`.

## Links

- [[Native Backend Strategy]] - Native architecture and safety boundaries.
- [[Portable Stem Bytecode]] - Bytecode compilation model used by the playground compiler.
- [[Native Backend Phase 2 Gate]] - Production gate criteria remain unchanged by this UX work.
