// SPDX-License-Identifier: Apache-2.0
//
// Tiny glue for the wasm32-unknown-unknown `stem_native` module — no WASI, runs
// in the browser and in Node. Pass the wasm bytes; get back `compile(source)`
// (template text -> bytecode, fully backend-free) and `render(program, data)`.
//
// Memory contract: write the request JSON into linear memory at stem_alloc(len),
// call stem_render(ptr, len) -> packed (out_ptr << 32 | out_len), read the UTF-8
// output, then free both buffers with stem_dealloc. The single `stem_render`
// export multiplexes on the request shape (`{program, data}` renders,
// `{compile}` compiles), so no separate compile export is needed.

export async function createRenderer(wasmBytes) {
  const { instance } = await WebAssembly.instantiate(wasmBytes, {});
  const { memory, stem_alloc, stem_dealloc, stem_render } = instance.exports;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  // Send a request object through the engine and return its raw output string.
  function call(request) {
    const bytes = encoder.encode(JSON.stringify(request));
    const inPtr = stem_alloc(bytes.length);
    new Uint8Array(memory.buffer, inPtr, bytes.length).set(bytes);

    const packed = stem_render(inPtr, bytes.length); // BigInt (wasm i64)
    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);
    // Re-view memory.buffer after the call (it may have grown/detached).
    const output = new Uint8Array(memory.buffer, outPtr, outLen).slice();

    stem_dealloc(inPtr, bytes.length);
    stem_dealloc(outPtr, outLen);
    return decoder.decode(output);
  }

  // Render a compiled program against data. By default returns the output
  // string. With `{ map: true }` it returns `{ output, segments }`, where each
  // segment ties a byte run of the output back to its source: `{ out, len, file,
  // start?, end? }` (`out`/`len` are output byte offsets; `start`/`end` are the
  // originating tag's byte span in `file`, present for expressions only). The
  // segments tile the output in order, so any output offset maps to a source.
  // Mapped rendering needs a program compiled with `compile(.., { map: true })`;
  // an unmapped program renders correctly but yields an empty segment list.
  function render(program, data, { map = false } = {}) {
    const raw = call({ program, data, map });
    return map ? JSON.parse(raw) : raw;
  }

  // Compile template source to a wire program with no backend. `partials` is an
  // optional `{ name: source }` map expanded inline at `{{> name}}` sites.
  // Returns `{ program }` on success, or `{ error: { message, start, end } }`
  // when the source uses a construct the native compiler does not yet support
  // (or references an unknown/recursive partial) — the span lets the editor
  // underline the offending tag. With `{ map: true }` the program additionally
  // carries `src` provenance so a mapped render can build a source map; this is
  // a superset wire and the default (unmapped) output stays byte-identical to
  // the BEAM reference.
  function compile(source, partials = {}, { map = false } = {}) {
    const result = JSON.parse(call({ compile: source, partials, map }));
    return result && result.error ? { error: result.error } : { program: result };
  }

  return { render, compile };
}
