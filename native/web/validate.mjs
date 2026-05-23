// SPDX-License-Identifier: Apache-2.0
//
// Validates the wasm32-unknown-unknown module + browser glue without a browser:
// renders the demo examples through the glue and checks them against expected
// outputs. Node uses the same WebAssembly API as browsers, so a pass here proves
// the browser path. Run from the repo root:
//
//   node native/web/validate.mjs

import { readFile } from "node:fs/promises";
import { createRenderer } from "./stem.mjs";

const WASM = "native/stem_native/target/wasm32-unknown-unknown/release/stem_native.wasm";

const expected = {
  Greeting: "Hello &lt;Nina&gt;!",
  Pipeline: "NINA",
  List: "<ul><li>1. a</li><li>2. b</li><li>3. c</li></ul>",
  // Native-only: the {"$getter": "full_name"} sentinel is computed by a
  // host-authored getter, with the user object as its "self".
  Getter: "Ada Lovelace",
};

const { render } = await createRenderer(await readFile(WASM));
const examples = JSON.parse(await readFile("native/web/examples.json", "utf8"));

let failures = 0;
for (const ex of examples) {
  const actual = render(ex.program, ex.data);
  const want = expected[ex.label];
  if (actual === want) {
    console.log(`  ok  ${ex.label}: ${JSON.stringify(actual)}`);
  } else {
    failures++;
    console.error(`  FAIL ${ex.label}: got ${JSON.stringify(actual)}, want ${JSON.stringify(want)}`);
  }
}

if (failures > 0) {
  console.error(`browser glue: ${failures} example(s) diverged`);
  process.exit(1);
}
console.log(`browser glue: ${examples.length}/${examples.length} examples render correctly`);
