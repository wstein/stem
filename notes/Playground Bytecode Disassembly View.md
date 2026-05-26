---
id: 20260526224737
aliases: []
tags: ['playground', 'tooling', 'bytecode']
---

The playground's Output pane has a **Bytecode** view that renders the compiled `stem-bc/v1` wire program as a `disasm`-style text walk (`EMIT_TEXT`, `EMIT`, `IF`/`THEN`/`ELSE`, `EACH`/`DO`, `SCOPE`, value ops `LIT`/`GET`/`CALL`…), mirroring `Stem.Bytecode.disasm/1`.

It needs no extra engine call — the wasm `compile()` already returns the wire program; the disassembly is a pure-frontend walk (`disassemble` in `native/web/playground_utils.mjs`). The view is syntax-highlighted with a small CodeMirror `StreamLanguage` (uppercase opcodes as keywords, quoted literals, numbers, the version comment). It is one of the Output view tabs (Plain Text · HTML · Markdown · Render Data · Bytecode).

## Links

- [[Playground Inspector Suite]] — the umbrella effort.
- [[Portable Stem Bytecode]] — the `stem-bc/v1` program this disassembles.
## Links

