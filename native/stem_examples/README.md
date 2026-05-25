# Stem Native — embedder examples

Ways to drive the [`stem_native`](../stem_native) engine from Rust through its
**idiomatic typed API** — `compile() -> Result<Program, CompileError>` and
`Program::render(&data, &RenderOptions) -> Result<String, RenderError>`, no JSON
strings — exercising both **built-in** transformers (loaded by capability group)
and **custom** transformers (the host hook).

```sh
cargo run --example compile_time     # template baked in at compile time
cargo run --example dynamic_eval     # template + data supplied at runtime
cargo run --example jsonata_pipeline # JSONata preprocessing -> Stem rendering
cargo test                           # unit tests for the shared glue
```

## The examples

- [`examples/compile_time.rs`](examples/compile_time.rs) — the
  [`stem_macros::stem!`](../stem_macros) proc-macro compiles a template *literal*
  to bytecode at Rust **build time**: a template syntax error becomes a compile
  error, and the bytecode is embedded, so no Stem-syntax parsing happens at
  runtime. The macro expands to a `Program`.
- [`examples/dynamic_eval.rs`](examples/dynamic_eval.rs) — the template is
  assembled (or read from `argv`) at runtime, compiled to bytecode once, then
  evaluated against each data record. Optionally takes a template string and a
  JSON-array data file as arguments.
- [`examples/jsonata_pipeline.rs`](examples/jsonata_pipeline.rs) — a two-stage
  pipeline: [`jsonata-core`](https://crates.io/crates/jsonata-core) preprocesses
  raw orders into a view model (group, sum, rank), then Stem renders a report.
  This keeps the template logic-less — aggregation lives in the declarative
  transform, presentation in capability-gated transformers — mirroring the
  playground's Transform tab. (The `jsonata-core` dependency builds without its
  `simd` default feature for portability.)

## Transformers

The shared glue in [`src/lib.rs`](src/lib.rs) configures both kinds through a
single `RenderOptions`:

- **Built-in** transformers (`upcase`, `truncate`, `sort`, `join`, ...) are
  loaded by capability group: `RenderOptions::new().with_groups([Group::Strings,
  Group::Collections, Group::Predicates])`, on top of the always-on Minimum. A
  template that reaches a transformer from an unloaded group is refused as a
  `RenderError` before any output is produced.
- **Custom** transformers (`slugify`, `reading_time`, `shout`) come from a host
  `TransformerResolver` passed via `.with_host(Host { … })`, consulted before the
  built-ins so it can add or override names. The pipeline value arrives as the
  first positional argument, so `{{ title |> slugify }}` calls the resolver with
  `title`. The host declares its names so the engine admits them and still
  refuses genuinely unknown ones.

Errors are typed: the glue's `StemError` wraps `CompileError`, `RenderError`, and
the JSONata step's failure — no error strings smuggled into output.

See [`../README.md`](../README.md#idiomatic-rust-api) for the typed API,
[`../README.md`](../README.md#capability-groups) for the capability-group model,
and [`../README.md`](../README.md#custom-transformers-host-hook) for the host
hook.
