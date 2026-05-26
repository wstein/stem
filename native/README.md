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
  via inlining, `@index`/`@index1`/`@key`/`this`, block params), the full built-in
  transformer stdlib gated by capability group, and a host hook for custom
  transformers — validated against every vector in
  [`conformance/vectors.json`](../conformance/vectors.json).
- **Isn't:** production-ready. The data model uses `serde_json::Value`; there is
  no wire-format versioning negotiation; a few value-formatting edge cases stay
  out of byte-parity (see [Parity scope](#parity-scope)). It exists to de-risk
  and demonstrate, not to ship.

## Layout

- `stem_compile/` — the Stem template compiler (source → portable bytecode),
  factored into its own crate so the macros can use it without the renderer.
- `stem_native/` — the engine crate. `src/lib.rs` is the renderer: the typed
  Rust API ([`compile`/`Program::render`](#idiomatic-rust-api)), the JSON
  `handle*` Elixir seam, and the wasm-bindgen `compile`/`render`/`parse_ast`
  browser exports; `src/main.rs` is a thin WASI bin reading stdin / writing
  stdout. `parse_ast` returns a template's pre-expansion AST (`stem-ast/v1`) with
  `{{> name}}` kept as `partial` nodes and a byte `src` span on every node, for
  the playground's dependency-graph and AST views.
- `stem_macros/` — the `stem!` compile-time macro: compiles a template literal to
  bytecode at Rust build time (syntax errors become compile errors).
- `stem_examples/` — runnable embedder examples written against the typed API.
- `run.mjs` — a Node WASI runner that loads the wasm module and forwards stdio.
- `web/` — the browser demo: `stem.mjs` (glue), `index.html` (live page),
  `examples.json` (a small manifest indexing the examples), `examples/<id>/`
  (each example as individual files: `main.stem`, one `.stem` per partial, and
  `data.yaml`), `vendor/` (vendored ESM bundles: `js-yaml.mjs`, used by both the
  browser page and the Node validator so they parse YAML identically with no
  install or network, and `marked.mjs` for the Markdown output view),
  `playground_utils.mjs` (shared browser utilities), and `validate.mjs` (a
  browserless check of the no-WASI module + glue that loads those same files). The page is a lightweight IDE-style, multi-tab editor built
  with CodeMirror 6: the first tab is the rendered entry template and the rest
  are partials, pulled in with `{{> name}}` and compiled fully in the browser.
  `compile(source, partials)` sends `{ "compile": source, "partials": {name:
  source} }`; the engine expands partials inline with the same recursion guard
  as `Stem.Parser`.

Playground workflow highlights:

- Split-pane workspace (Templates, Data YAML, Output) with responsive collapse
  on narrow screens.
- Inline compile diagnostics in the template editor gutter, plus a status lane
  with line/column locations.
- A **Problems** dock at the bottom (status-bar "Diagnostics" button) listing
  compile / capability / render errors, badged by severity; it auto-opens when an
  error first appears. Every unknown partial is listed (found via the `parse_ast`
  dependency scan), not just the first the fail-fast compiler reports.
- Two read-only inspectors live in the Sources data sub-pane, alongside the
  `data` / `transform` editors: **Context Inspector** snapshots the render
  context (`@this`/`@parent`/`@root`/iteration vars/locals) at a clicked output
  expression via the engine's `inspect_at` (one card per loop iteration), and
  **Parse Tree** renders the active template's pre-expansion `parse_ast` as an
  indented outline (hover/click a row to highlight its source span).
- A floating, draggable, resizable **Dependencies** popup (toolbar button, like
  Appearance) draws the `{{> name}}` partial graph from `parse_ast` with a
  force-directed (neato-style) layout: cyclic inclusions as red edges (the
  compile-time `partial recursion detected` error), unknown partials as dashed
  amber nodes. Floating-panel layout (open state, position, size) persists.
- A capability-group selector (Strings / Collections / Predicates checkboxes;
  Minimum is always on) in the output header. Unchecking a group makes the
  engine refuse a template that uses one of its transformers, surfacing the
  group-naming message in the status bar — the secure-by-default model, made
  interactive. The selection persists in the shareable URL state.
- Output as "Plain Text" (the output as text, mapped to its source), "HTML
  Preview" (output HTML in a locked-down iframe), "Markdown Preview" (the output
  interpreted as Markdown in the same iframe), "View Model" (the post-transform
  data as YAML), or "Bytecode" (the compiled `stem-bc/v1` program disassembled,
  matching `Stem.Bytecode.disasm/1`). In the Plain Text view the source link is
  bidirectional: hovering a run names its source file/tag and highlights the
  originating span in the editor (or tints its tab), clicking jumps the caret
  there, and moving the editor caret highlights the output run(s) it produced.
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

## Idiomatic Rust API

In-process Rust hosts use the typed, `Result`-returning surface — not the JSON
string protocol, which is reserved for the Elixir conformance harness (`handle*`
and the C ABI) and is a thin wrapper over this same core:

```rust
use serde_json::json;
use stem_native::{compile, Group, RenderOptions};

let program = compile("{{ name | upcase }}")?;            // -> Result<Program, CompileError>
let opts = RenderOptions::new().with_group(Group::Strings); // Minimum is always on
let out = program.render(&json!({ "name": "ada" }), &opts)?; // -> Result<String, RenderError>
assert_eq!(out, "ADA");
```

- `compile` / `compile_with_partials` return a typed [`Program`]; a syntax error
  is a `CompileError` (with a byte span).
- `Program::render(&Value, &RenderOptions)` returns `Result<String, RenderError>`.
  An unloaded group, unknown transformer, or i18n-without-translator is an
  `Err(RenderError)` — never smuggled into the output string.
- `RenderOptions` is a builder: `.with_group(s)` load capability groups,
  `.with_host(Host { … })` supplies custom transformers.
- `Program::from_wire(&str)` reconstructs a program from bytecode (the path a
  compile-time macro or the Elixir bridge uses).

The `stem_examples` crate is written entirely against this API; see
[`stem_examples/`](stem_examples/).

## Capability groups

Transformers are gated by capability group, mirroring the BEAM's
secure-by-default model (see [`Stem.Transformers`](../lib/stem/transformers.ex)
and [notes/Helper Capability Groups.md](../notes/Helper%20Capability%20Groups.md)).
The render request names the loaded groups:

```jsonc
{ "program": { ... }, "data": { ... }, "transformers": ["strings", "collections"] }
```

The **Minimum** group is always on; **Strings**, **Collections**, **Predicates**,
and **I18n** are opt-in, and `"standard"` is the Minimum+Strings bundle. A
template that calls a transformer from an unloaded group is **refused before any
output is produced**, with a message naming the group to enable — the native
analogue of the BEAM raising at an unloaded transformer. The list is absent on
the parity wire and from the C ABI, where it defaults to Minimum-only, so a
browser embed is secure by default until it opts a group in.

## Parity scope

The engine implements the **full** built-in transformer stdlib — Minimum,
Strings, Collections, and Predicates — byte-for-byte against the BEAM, including
`json` and `inspect` (over the JSON value domain) and `log` (which renders to `""`,
its BEAM output; the stderr side effect is left to a host override). Floats render
byte-for-byte too (see [Floats](#floats) below). The `i18n` group's
`t`/`translate` are **host-delegated**: they have no native built-in and resolve
through the custom-transformer hook below, requiring both the `i18n` group and a
host translator (mirroring the BEAM's configured translator).

A few value-formatting cases stay out of byte-parity and are kept out of the
conformance corpus and the differential fuzzer (see
[notes/Cross-Backend Conformance Spec.md](../notes/Cross-Backend%20Conformance%20Spec.md)
for the gap list):

- **G4 — Unicode casing:** `upcase`/`downcase`/`capitalize` match for ASCII; the
  fuzzer restricts inputs accordingly.
- **G5 — map key order:** native always sorts object keys; the BEAM iterates a
  map in its internal order (which varies by key type and size), so `{{#each}}`
  over a multi-key map, `group_by`, and `json` object key order are not
  cross-backend stable. The corpus uses single-key maps to stay deterministic.
- **G6 — heterogeneous `sort`/`sort_by`:** the native term ordering is approximate
  for mixed-type lists.
- **G7 — `inspect` of maps:** native values are always string-keyed, so a map
  prints as `%{"k" => v}`; the conformance harness builds atom-keyed maps from
  JSON, which the BEAM prints as `%{k: v}`. `inspect` is exercised over scalars
  and lists, where the two agree.

## Floats

Floats render byte-for-byte with the BEAM (`String.Chars.to_string/1` →
`:erlang.float_to_binary(f, [:short])`), for a bare emit, `json`, and `inspect`
alike. Two pieces make this exact:

- **Correctly-rounded parsing.** serde_json is built with the `float_roundtrip`
  feature so a JSON float decodes to the same `f64` the BEAM holds (the default
  fast parser can be a ULP off).
- **Ryū digits + Erlang's notation policy.** The shortest digits come from the
  `ryu` crate — the same algorithm the BEAM uses, so the digit choice and
  round-half-to-even tie-breaking match (Rust's std `Display` can break a
  shortest-decimal tie the other way). Those digits are then formatted with
  Erlang's `:short` policy: scientific when the magnitude reaches `2^53` (above
  which not every integer is representable) or when it is strictly shorter than
  the fixed form, decimal otherwise (ties to decimal).

The differential fuzzer exercises floats across a wide range of magnitudes, so
this is verified, not assumed. (This closes the former gap G2.)

## Custom transformers (host hook)

The BEAM lets a caller supply transformers via the `transformers:` binding,
consulted before the built-ins so it can add or override names. The native
engine mirrors this with a host hook on the same precedence: a `Host` carries a
`TransformerResolver` — `fn(&TransformerCall) -> Option<Value>` — consulted
before the built-in stdlib, returning `None` to fall through. The call carries
the (evaluated) positional args, keyword args, the current assigns, and the block
`this`, mirroring the BEAM's `(args, %{assigns, this})` shape.

The host also declares the names it handles, so the pre-check can admit them and
still refuse genuinely unknown names without invoking the resolver — the wire
stays portable, and a browser embed (using `handle`) gets no host transformers. The `i18n`
`t`/`translate` transformers are delivered this way:

```rust
use serde_json::Value;
use stem_native::{handle_with_host, Host, TransformerCall};

fn transformers(call: &TransformerCall) -> Option<Value> {
    match call.name {
        // A fake translator: interpolate the `name` keyword binding.
        "t" | "translate" => {
            let name = call.kwargs.get("name").and_then(Value::as_str).unwrap_or("");
            Some(Value::from(format!("Hello, {name}!")))
        }
        _ => None, // fall through to the built-in stdlib
    }
}

let host = Host {
    transform: transformers,
    transformer_names: &["t", "translate"],
    ..Host::default()
};

// `t` needs the i18n group loaded *and* a host translator; both are present.
let request = r#"{"program":{"version":"stem-bc/v1","instructions":[
  {"t":"emit","escape":"none","value":{"t":"call","name":"t",
    "args":[{"t":"lit","value":"greeting"}],
    "kwargs":{"name":{"t":"assign","name":"user"}}}}]},
  "data":{"user":"Ada"},"transformers":["i18n"]}"#;

assert_eq!(handle_with_host(request, &host), "Hello, Ada!");
```

Custom transformers live in the host, so they carry no
cross-backend parity and stay out of the conformance corpus; `src/lib.rs` covers
the hook (dispatch, built-in override, keyword bindings, and the i18n refusal
paths) with native-only unit tests.

## Browser / edge (no WASI)

The same engine compiles to `wasm32-unknown-unknown` and renders in a browser
via **wasm-bindgen** — no WASI, no server, no Elixir at runtime. JS passes and
receives values (objects/arrays) directly through serde-wasm-bindgen, so there is
no hand-rolled JSON-string marshalling.

```sh
rustup target add wasm32-unknown-unknown            # one-time
cargo install wasm-bindgen-cli --version 0.2.122    # one-time; match the crate

# build the engine and generate web/wasm/{stem_native.js, stem_native_bg.wasm}:
native/web/build.sh

# browserless check of the module + glue (Node uses the same WebAssembly API):
node native/web/validate.mjs
# => browser glue: 11/11 examples compile + render correctly

# utility tests for state encoding and UTF-8 span mapping:
node native/web/playground_utils.test.mjs

# live demo (must be served over HTTP so the module can load the .wasm):
python3 -m http.server   # then open http://localhost:8000/native/web/
```

The generated `web/wasm/` directory is a build artifact (git-ignored);
`build.sh` regenerates it. When deploying the page, serve `.mjs` files with a
JavaScript MIME type (`text/javascript`) — browsers refuse ES modules sent as
`application/octet-stream`.

The browser glue ([web/stem.mjs](web/stem.mjs)) is a thin wrapper over the
wasm-bindgen module's `compile(source, partials, map)` and `render(program,
data, groups, map)` exports.

## Try it directly

```sh
echo '{"program":{"version":"stem-bc/v1","instructions":[
  {"t":"emit","escape":"html","value":{"t":"assign","name":"name"}}]},
  "data":{"name":"<Nina>"}}' \
| node native/run.mjs native/stem_native/target/wasm32-wasip1/release/stem_native.wasm
# => &lt;Nina&gt;
```
