// SPDX-License-Identifier: Apache-2.0
//
// Node WASI runner for the Stem native PoC. Reads a JSON request on stdin,
// pipes it to the wasm module's stdin, and forwards the module's stdout.
//
//   node native/run.mjs <module.wasm> < request.json
//
// The wasm is compiled from native/stem_native for wasm32-wasip1.

import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";

const wasmPath = process.argv[2];
if (!wasmPath) {
  process.stderr.write("usage: node native/run.mjs <module.wasm>\n");
  process.exit(2);
}

const wasi = new WASI({ version: "preview1", returnOnExit: true });
const bytes = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, wasi.getImportObject());
process.exit(wasi.start(instance));
