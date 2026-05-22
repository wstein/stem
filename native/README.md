# Stem Native (Rust/WASM) — Proof of Concept

This directory holds a proof of concept for the "Stem Native" idea: a
from-scratch renderer, written in Rust and compiled to WebAssembly, that
consumes Stem's **portable bytecode** and produces output **byte-for-byte
identical** to the Elixir (BEAM) reference.

It proves the architecture described in
[`notes/Native Backend Strategy.md`](../notes/Native%20Backend%20Strategy.md):
the host compiles a template to a portable program
([`Stem.Bytecode.to_wire/1`](../lib/stem/bytecode.ex)), and a single small engine
renders it off the BEAM — no parser re-implementation, no per-node callback into
the host, escaping done natively.

## What it is (and isn't)

- **Is:** a working `wasm32-wasip1` module that renders the whole structured Stem
  language (text, expressions, paths, `if`/`unless`/`each`/`with`, regions/yields
  via inlining, `@index`/`@index1`/`@key`/`this`, block params) plus the
  transformer subset the conformance corpus uses, validated against every vector
  in [`conformance/vectors.json`](../conformance/vectors.json).
- **Isn't:** production-ready. The transformer stdlib is a subset; the data model
  uses `serde_json::Value`; there is no wire-format versioning negotiation. It
  exists to de-risk and demonstrate, not to ship.

## Layout

- `stem_native/` — the Rust crate (`src/main.rs`): reads a JSON request
  `{"program": …, "data": …}` on stdin, writes the rendered string to stdout.
- `run.mjs` — a Node WASI runner that loads the wasm module and forwards stdio.

## Build

Requires the Rust toolchain with the wasm target, and Node (for WASI):

```sh
rustup target add wasm32-wasip1            # one-time
cd native/stem_native
cargo build --release --target wasm32-wasip1
# host binary (optional): cargo build --release
```

## Verify (byte-parity against the BEAM)

From the repository root:

```sh
mix stem.native.verify
# or against the host binary:
mix stem.native.verify --engine "native/stem_native/target/release/stem_native"
```

The task compiles each conformance vector to bytecode, feeds it to the engine,
and asserts the output matches `Stem.compile_string/2`. Expected result:

```
Conformance: 27/27 vectors match the BEAM reference byte-for-byte.
```

## Try it directly

```sh
echo '{"program":{"version":"stem-bc/v1","instructions":[
  {"t":"emit","escape":"html","value":{"t":"assign","name":"name"}}]},
  "data":{"name":"<Nina>"}}' \
| node native/run.mjs native/stem_native/target/wasm32-wasip1/release/stem_native.wasm
# => &lt;Nina&gt;
```
