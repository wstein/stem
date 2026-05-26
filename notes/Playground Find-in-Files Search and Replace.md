---
id: 20260526224712
aliases: []
tags: ['playground', 'search', 'tooling', 'ux']
---

The playground has a global **find-in-files** panel (⌘⇧F or the toolbar Search button) that searches every source at once — `main`, all partials, `data.yaml`, and the JSONata `transform`. The rendered output is excluded because it is generated, not a source.

- **Options:** case-sensitive, whole-word, and regex toggles (VSCode-style icons; invalid regex is reported).
- **Results** group by file with `line:col` and a highlighted line preview; clicking a hit opens that tab/editor and selects the matched range.
- **Replace:** a Replace field with **Replace All** (across every source — `$1` backrefs honoured in regex mode, `$` escaped literally otherwise) and a **per-occurrence** Replace revealed on row hover. Edits write back to the right source, sync the visible editor, mark the state custom, and re-render.

It is a floating, draggable/resizable panel whose position/size persist with the other panels. Small files make whole-codebase find-all more useful than per-editor find.

## Links

- [[Native Playground IDE UX]] — the editor shell this lives in.
## Links

