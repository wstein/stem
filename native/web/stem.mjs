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

  // Render a compiled program against data, returning the output string.
  function render(program, data) {
    return call({ program, data });
  }

  // Compile template source to a wire program with no backend. Returns
  // `{ program }` on success, or `{ error: { message, start, end } }` when the
  // source uses a construct the native compiler does not yet support — the
  // span lets the editor underline the offending tag.
  function compile(source) {
    const result = JSON.parse(call({ compile: source }));
    return result && result.error ? { error: result.error } : { program: result };
  }

  return { render, compile };
}
