---
id: 20260526224729
aliases: []
tags: ['playground', 'tooling', 'inspector', 'native']
---

Clicking an output segment in the playground's Plain Text view re-executes the program against the data and snapshots the active render context at every instruction whose source span matches the clicked segment.

Each snapshot surfaces `@this` / `@parent` / `@root`, the locals, and the `@index` / `@index1` / `@key` / `@first` / `@last` iteration vars. A loop body yields one snapshot per iteration, so the panel is steppable. It shows as a tab in the Sources data sub-pane.

Backed by the engine export **`inspect_at(program, data, groups, target)`** — implemented in Rust (`inspect_program`, walking instructions and snapshotting the `Ctx` whose `src` equals the target `{file, start, end}`) and mirrored in Elixir (`Stem.Bytecode.VM.inspect_at/3`). It is **re-execute-on-demand**, not continuous tracing, to avoid memory bloat; the snapshot needs a program compiled with spans.

## Links

- [[Playground Inspector Suite]] — the umbrella effort.
- [[Rust Host API for Native Backend]] — the wasm export surface.
- [[Each Index Variables and Block Params]] — the iteration vars it reveals.
## Links

