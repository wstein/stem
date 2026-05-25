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

import init, { compile as wasmCompile, render as wasmRender } from "./wasm/stem_native.js";

// The capability groups the playground loads. The playground author is trusted,
// so it enables every group with a native byte-parity implementation (i18n is
// omitted: `t`/`translate` need a host translator the browser has none of).
// Mirrors a BEAM caller passing `transformers:` for these groups.
const PLAYGROUND_GROUPS = ["minimum", "strings", "collections", "predicates"];

export async function createRenderer(wasmInput) {
  await init({ module_or_path: wasmInput });

  // Compile template source to a wire program with no backend. `partials` is an
  // optional `{ name: source }` map expanded inline at `{{> name}}` sites.
  // Returns `{ program }` on success, or `{ error: { message, start, end } }`
  // when the source uses an unsupported construct (or an unknown/recursive
  // partial) — the span lets the editor underline the offending tag. With
  // `{ map: true }` the program carries `src` provenance for a source map; the
  // unmapped wire stays byte-identical to the BEAM reference.
  function compile(source, partials = {}, { map = false } = {}) {
    try {
      return { program: wasmCompile(source, partials, map) };
    } catch (error) {
      // The Rust side throws the `{ message, start, end }` object on a compile
      // error.
      return { error };
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

  return { render, compile };
}
