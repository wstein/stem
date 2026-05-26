// SPDX-License-Identifier: Apache-2.0
//
// Glue for the wasm32-unknown-unknown `stem_native` module — no WASI, runs in
// the browser and in Node. Built on wasm-bindgen: JS values (objects/arrays)
// cross the boundary directly via serde-wasm-bindgen, with no hand-rolled
// JSON-string marshalling through linear memory.
//
// `createRenderer(wasmInput)` initialises the module (pass the
// `stem_native_bg.wasm` bytes, a URL, or a Response) and returns
// `compile(source, partials)` (template text -> bytecode, fully backend-free)
// and `render(program, data)`.

import init, {
  compile as wasmCompile,
  render as wasmRender,
  parse_ast as wasmParseAst,
  inspect_at as wasmInspectAt,
} from "./wasm/stem_native.js";

// The capability groups the playground loads. The playground author is trusted,
// so it enables every group with a native byte-parity implementation (i18n is
// omitted: `t`/`translate` need a host translator the browser has none of).
// Mirrors a BEAM caller passing `transformers:` for these groups.
const PLAYGROUND_GROUPS = ["minimum", "format", "transform"];

export async function createRenderer(wasmInput) {
  await init({ module_or_path: wasmInput });

  // Compile template source to a wire program with no backend. `partials` is an
  // optional `{ name: source }` map expanded inline at `{{> name}}` sites.
  // Returns `{ program }` on success, or `{ errors: [{ message, start, end }] }`
  // listing every recoverable parse error (unsupported constructs, unknown or
  // recursive partials, bad arguments) in source order — the spans let the
  // editor underline each offending tag. With `{ map: true }` the program
  // carries `src` provenance for a source map; the unmapped wire stays
  // byte-identical to the BEAM reference.
  function compile(source, partials = {}, { map = false } = {}) {
    try {
      return { program: wasmCompile(source, partials, map) };
    } catch (thrown) {
      // The Rust side throws `{ errors: [{ message, start, end }, ...] }`.
      const errors = thrown && Array.isArray(thrown.errors) ? thrown.errors : [thrown];
      return { errors };
    }
  }

  // Render a compiled program against data. By default returns the output
  // string. With `{ map: true }` it returns `{ output, segments }`, where each
  // segment ties a byte run of the output back to its source: `{ out, len, file,
  // start?, end? }`. Mapped rendering needs a program compiled with
  // `compile(.., { map: true })`. `transformers` overrides the loaded capability
  // groups.
  function render(program, data, { map = false, transformers = PLAYGROUND_GROUPS } = {}) {
    return wasmRender(program, data, transformers, map);
  }

  // Parse one template's source to its pre-expansion AST (`stem-ast/v1`),
  // `{ version, nodes }`. Unlike `compile`, `{{> name}}` tags stay as `partial`
  // nodes (the dependency-graph edges) and every node carries its byte `src`
  // span. Returns `{ ast }` on success or `{ error: { message, start, end } }`
  // on a parse error. No partials map: each file is parsed on its own.
  function parseAst(source) {
    try {
      return { ast: wasmParseAst(source) };
    } catch (error) {
      return { error };
    }
  }

  // Capture render-context snapshots at a source span, for the Context
  // Inspector. `target` is `{ file, start, end }` (an output segment's source
  // provenance). Returns an array of snapshots — `{ this, parent, root, index,
  // index1, key, first, last, locals }` (the UI renders them `@`-prefixed) — one
  // per execution of the matching instruction (so a loop body yields one per
  // iteration), empty when the span is never reached. Needs a program compiled
  // with `{ map: true }`.
  function inspectAt(program, data, target, { transformers = PLAYGROUND_GROUPS } = {}) {
    return wasmInspectAt(program, data, transformers, target);
  }

  return { render, compile, parseAst, inspectAt };
}
