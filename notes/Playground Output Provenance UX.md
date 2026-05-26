---
id: 20260526143004
title: "Playground Output Provenance UX"
aliases: []
tags: ['playground', 'ux', 'editor', 'provenance']
---

The playground's output pane is not just a preview surface; it is a provenance browser that lets rendered bytes and template spans point at each other without breaking the iframe and editor trust boundaries.

## What

Plain Text and View Model share one read-only CodeMirror editor rather than a custom `<pre>`. Its language auto-switches: YAML for View Model, and for Plain Text the example's output format. A searchable highlight picker can override that autoswitch with any supported CodeMirror language, lazily loading grammars from `@codemirror/language-data` and caching them after first use. Reusing CodeMirror keeps syntax coloring theme-aware and avoids rendering raw output through `innerHTML`.

The compiler can emit per-instruction `src` spans and the renderer a segment map (see [[Native AST Compilation Pipeline]]). In the read-only output editor those runs become CodeMirror mark decorations carrying a segment index. Output to source is interactive: hovering a run shows a tooltip naming its file or tag and highlights the originating span in the template editor, while clicking or pressing Enter jumps the caret there. Source to output is the reverse: moving the template caret highlights the output runs it produced.

## How

The hover link-highlight is a CodeMirror `StateField` decoration rather than a selection, so hover never steals the caret. It is dirty-checked per run and suppressed while a render is pending, preventing stale mappings from flashing.

Building Plain Text provenance maps the renderer's byte-offset segments to output character ranges in a single forward pass over the UTF-8 output. That monotonic cursor avoids rescanning the full output for every segment and keeps large examples responsive.

## Links

- [[Native Playground IDE UX]] - The surrounding playground UX note.
- [[Native AST Compilation Pipeline]] - The source-map data this UX consumes.
- [[Playground Inspector Suite]] - The next diagnostic and inspection layer built on this provenance work.
