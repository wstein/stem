---
id: 20260526224745
aliases: []
tags: ['playground', 'tooling', 'diagnostics', 'ux']
---

The playground has a persistent, resizable bottom **dock** that lists problems instead of letting errors vanish into a one-line status lane.

It collects compile errors (the accumulated set — see [[Recoverable Parse Error Accumulation]]), YAML/JSONata data errors, and render-time capability-group violations (the `stem_native error:` sentinel, which names the missing group). Rows are clickable to jump to the offending file:line; capability violations are badged distinctly from compile/render errors. It auto-opens on the first error of a run.

Problems is its only view, so the dock has no title bar — just a floating close button — and the problem-count badge rides on the status-bar **Diagnostics** toggle (visible even when the dock is closed). The dock's open/closed state and height persist across reloads.

## Links

- [[Playground Inspector Suite]] — the umbrella effort.
- [[Recoverable Parse Error Accumulation]] — the multi-error source it renders.
- [[Transformer Capability Group Operations]] — the capability violations it badges.
## Links

