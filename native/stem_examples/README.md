# Stem Native — embedder examples

Two ways to drive the [`stem_native`](../stem_native) engine from Rust, both
adding **custom transformers**.

```sh
cargo run --example compile_time     # template baked in at compile time
cargo run --example dynamic_eval     # template + data supplied at runtime
cargo test                           # unit tests for the shared glue
```

## The two examples

- [`examples/compile_time.rs`](examples/compile_time.rs) — a `macro_rules!`
  macro (`stem!`) takes the template as a string *literal*, so it is baked into
  the binary and checked at Rust compile time. The Stem source is lowered to
  portable bytecode on first render (the engine is an interpreter, not a proc
  macro).
- [`examples/dynamic_eval.rs`](examples/dynamic_eval.rs) — the template is
  assembled (or read from `argv`) at runtime, compiled to bytecode once, then
  evaluated against each data record. Optionally takes a template string and a
  JSON-array data file as arguments.

## About "custom transformers"

The engine's built-in transformer stdlib (`upcase`, `join`, `truncate`, ...) is
a **closed set** — an unknown name in a `{{ x | name }}` pipe is *refused*, not
dispatched to host code. The one host-extension point the engine exposes is the
getter hook: a data field whose value is the sentinel `{"$getter": "<name>"}`
is computed by a host `fn(name, parent) -> Value` at render time, with `parent`
as its "self".

So in these examples a custom transformer is a custom getter —
[`custom_transformers`](src/lib.rs) in the shared lib defines `shout`, `slug`,
`word_count`, and `reading_time`, each deriving a value from its sibling fields.
See [`../README.md`](../README.md#per-host-computed-getters) for the hook's
design.
