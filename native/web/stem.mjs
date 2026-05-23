// SPDX-License-Identifier: Apache-2.0
//
// Tiny glue for the wasm32-unknown-unknown `stem_native` module — no WASI, runs
// in the browser and in Node. Pass the wasm bytes; get back a `render(program,
// data)` that returns the rendered string.
//
// Memory contract: write the request JSON into linear memory at stem_alloc(len),
// call stem_render(ptr, len) -> packed (out_ptr << 32 | out_len), read the UTF-8
// output, then free both buffers with stem_dealloc.

export async function createRenderer(wasmBytes) {
  const { instance } = await WebAssembly.instantiate(wasmBytes, {});
  const { memory, stem_alloc, stem_dealloc, stem_render } = instance.exports;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  function render(program, data) {
    const request = encoder.encode(JSON.stringify({ program, data }));
    const inPtr = stem_alloc(request.length);
    new Uint8Array(memory.buffer, inPtr, request.length).set(request);

    const packed = stem_render(inPtr, request.length); // BigInt (wasm i64)
    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);
    // Re-view memory.buffer after the call (it may have grown/detached).
    const output = new Uint8Array(memory.buffer, outPtr, outLen).slice();

    stem_dealloc(inPtr, request.length);
    stem_dealloc(outPtr, outLen);
    return decoder.decode(output);
  }

  return { render };
}
