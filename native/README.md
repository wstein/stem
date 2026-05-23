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
  `examples.json` (a small manifest indexing the examples), `examples/<id>/`
  (each example as individual files: `main.stem`, one `.stem` per partial, and
  `data.json`), `playground_utils.mjs` (shared browser utilities), and
  `validate.mjs` (a browserless check of the no-WASI module + glue that loads
  those same files). The page is a lightweight IDE-style, multi-tab editor built
  with CodeMirror 6: the first tab is the rendered entry template and the rest
  are partials, pulled in with `{{> name}}` and compiled fully in the browser.
  `compile(source, partials)` sends `{ "compile": source, "partials": {name:
  source} }`; the engine expands partials inline with the same recursion guard
  as `Stem.Parser`.

Playground workflow highlights:

- Split-pane workspace (Templates, Data JSON, Output) with responsive collapse
  on narrow screens.
- Inline compile diagnostics in the template editor gutter, plus a status lane
  with line/column locations.
- Command palette and shortcuts:
  - `Cmd/Ctrl+Shift+P` opens the palette.
  - `Cmd/Ctrl+Enter` renders immediately.
  - `Cmd/Ctrl+1` / `Cmd/Ctrl+2` focus template/data editor.
  - `Cmd/Ctrl+Alt+N` adds a partial tab.
  - `Cmd/Ctrl+Shift+C` copies the share link.
  - `Cmd/Ctrl+Shift+V` toggles rendered/source output.

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
cross the wire as JSON, so the native engine offers the same capability through
a **host hook**: a field whose data value is the sentinel `{"$getter": "<name>"}`
is computed by a `GetterResolver` — `fn(name, parent) -> Value` — that the
embedder supplies. The resolver receives the getter name and the field's
**parent object** as its "self", mirroring ST4 getter semantics.

The engine ships **no** getters: getter logic is the embedder's business, never
the library's or the wire's. The marker is only data, and it is **inert** under
the default resolver (`no_getters`), which is what `handle` and the C ABI — and
therefore the browser — use. So a `$getter` field renders as null unless a Rust
embedder opts in via `handle_with_getters`:

```rust
use serde_json::Value;
use stem_native::handle_with_getters;

fn getters(name: &str, self_obj: &Value) -> Value {
    let field = |k: &str| self_obj.get(k).and_then(Value::as_str).unwrap_or("");
    match name {
        "full_name" => Value::from(format!("{} {}", field("first"), field("last"))),
        _ => Value::Null, // unknown getter -> null
    }
}

let request = r#"{"program":{"version":"stem-bc/v1","instructions":[
  {"t":"emit","escape":"html","value":{
    "t":"get","base":{"t":"assign","name":"user"},"segments":["full_name"]}}]},
  "data":{"user":{"first":"Ada","last":"Lovelace","full_name":{"$getter":"full_name"}}}}"#;

assert_eq!(handle_with_getters(request, getters), "Ada Lovelace");
```

Resolution happens at every assign and dotted-path step, so a getter works at the
top level (`{{full_name}}`, self = the root) and at a nested leaf
(`{{user.full_name}}`, self = `user`). The result is escaped like any value.

Because the getter logic lives in the host, this has no cross-backend byte-parity
and is deliberately **out of the conformance corpus**; `src/lib.rs` covers the
hook with native-only unit tests (which supply a `full_name`/`initials` resolver)
and asserts the default path leaves the marker inert.

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

# utility tests for state encoding and UTF-8 span mapping:
node native/web/playground_utils.test.mjs

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
