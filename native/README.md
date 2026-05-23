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

- `stem_native/` — the Rust crate. `src/lib.rs` is the engine (`handle/1` plus
  the `stem_alloc`/`stem_dealloc`/`stem_render` C ABI); `src/main.rs` is a thin
  WASI bin reading stdin / writing stdout.
- `run.mjs` — a Node WASI runner that loads the wasm module and forwards stdio.
- `web/` — the browser demo: `stem.mjs` (glue), `index.html` (live page),
  `examples.json` (templates precompiled on the BEAM), `validate.mjs` (a
  browserless check of the no-WASI module + glue).

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

```text
Conformance: 28/28 vectors match the BEAM reference byte-for-byte.
```

## Differential fuzz (BEAM = oracle)

```sh
mix stem.native.fuzz                 # 200 random templates, random seed
mix stem.native.fuzz --count 1000
mix stem.native.fuzz --seed 42       # reproduce a run
```

Generates random templates over the matchable grammar, renders each on the BEAM
and the native engine (one batched wasm process), and asserts byte-for-byte
equality. The seed is printed so any failure is reproducible.

## Parity scope

The engine reimplements the built-in transformers that *can* match the BEAM
byte-for-byte: the Strings, Collections, and Predicates groups plus the
Minimum group's `default`/`join`/`lookup`/`escape_html`/`escape_json`. Three are
deliberately **out of scope** (no cross-language byte-parity is achievable, so
they panic loudly and are excluded from the fuzzer):

- `json` / `inspect` — Elixir-specific serialization formatting and map key order;
- `i18n` `t` — delegates to a host translator (a host closure), so the bytecode
  marks it a host transformer the native core cannot run.

Cased transforms (`upcase`/`downcase`/`capitalize`) match for ASCII; the fuzzer
restricts inputs accordingly.

## Per-host computed getters

The BEAM backend lets an assign be a zero-arity function — a **computed getter**
that is invoked lazily when rendered (see the project README). A closure can't
cross the wire as JSON, so the native engine offers the same capability with a
different mechanism: a field whose data value is the sentinel
`{"$getter": "<name>"}` is *computed* by a getter authored in the host language
(here, Rust) and registered with the engine. The getter is invoked with the
field's **parent object** as its "self", mirroring ST4 getter semantics:

```sh
echo '{"program":{"version":"stem-bc/v1","instructions":[
  {"t":"emit","escape":"html","value":{
    "t":"get","base":{"t":"assign","name":"user"},"segments":["full_name"]}}]},
  "data":{"user":{"first":"Ada","last":"Lovelace","full_name":{"$getter":"full_name"}}}}' \
| node run.mjs stem_native/target/wasm32-wasip1/release/stem_native.wasm
# => Ada Lovelace
```

Here the host getter `full_name` reads `first`/`last` off the `user` object that
contains it. Resolution happens at every assign and dotted-path step, so a getter
works at the top level (`{{full_name}}`, self = the root) and at a nested leaf
(`{{user.full_name}}`, self = `user`). The result is escaped like any value, and
an unknown getter resolves to null.

Because the getter body lives in the host, not the data, this has no
cross-backend byte-parity and is deliberately **out of the conformance corpus**;
`src/lib.rs` covers it with native-only unit tests. The PoC ships a small
illustrative registry (`full_name`, `initials`) in `run_getter`; a real embedder
registers its own.

## Browser / edge (no WASI)

The same engine compiles to `wasm32-unknown-unknown` and renders in a browser
with a ~30-line glue module — no WASI, no server, no Elixir at runtime:

```sh
rustup target add wasm32-unknown-unknown          # one-time
cd native/stem_native
cargo build --release --target wasm32-unknown-unknown --lib

# browserless check of the module + glue (Node uses the same WebAssembly API):
node native/web/validate.mjs
# => browser glue: 4/4 examples render correctly

# live demo (must be served over HTTP so fetch() can load the .wasm):
python3 -m http.server   # then open http://localhost:8000/native/web/
```

The host writes the request JSON into wasm memory via `stem_alloc`, calls
`stem_render(ptr, len)` (returns a packed `out_ptr<<32 | out_len`), reads the
UTF-8 output, and frees both buffers with `stem_dealloc`. See `web/stem.mjs`.

## Try it directly

```sh
echo '{"program":{"version":"stem-bc/v1","instructions":[
  {"t":"emit","escape":"html","value":{"t":"assign","name":"name"}}]},
  "data":{"name":"<Nina>"}}' \
| node native/run.mjs native/stem_native/target/wasm32-wasip1/release/stem_native.wasm
# => &lt;Nina&gt;
```
