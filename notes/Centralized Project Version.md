---
id: 20260526224702
aliases: []
tags: ['build', 'versioning', 'native']
---

A single repo-root `/VERSION` file is the source of truth for the project version, read by both backends so they can never drift.

- Elixir `mix.exs` sets `@version` via `File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()`.
- The native engine bakes it into the wasm at build time with `include_str!("../../../VERSION")`, exposed as the wasm `version()` export and surfaced by `stem.mjs`.
- The playground shows it in the status bar (bottom-right).

The `stem_native` crate's own Cargo `version` is a separate, internal concern and is not what the playground displays. Bumped 0.2.0 → 0.3.0 for the playground inspector suite, recoverable-error accumulation, and the nimble_parsec_rs port.

## Links

- [[Rust Host API for Native Backend]] — the wasm surface the `version()` export joins.
## Links

