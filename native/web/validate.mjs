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
  // Each + if + pipeline rendering a card grid (shown via the Rendered view).
  "HTML cards": "<div\n  style=\"\n    display: grid;\n    grid-template-columns: repeat(2, 1fr);\n    gap: 10px;\n    font-family: system-ui;\">\n\n  \n  <div\n    style=\"border:1px solid #e5e7eb;border-radius:10px;padding:10px 12px;background:#faf5ff\">\n\n    <div style=\"font-weight: 600\">\n      1. ADA LOVELACE\n    </div>\n    <div style=\"color: #6b7280; font-size: 13px\">\n      Compiler\n      · <span style=\"color: #7c3aed\">★ lead</span>\n    </div>\n  </div>\n  \n  <div\n    style=\"border:1px solid #e5e7eb;border-radius:10px;padding:10px 12px;background:#eee\">\n\n    <div style=\"font-weight: 600\">\n      2. GRACE HOPPER\n    </div>\n    <div style=\"color: #6b7280; font-size: 13px\">\n      Runtime\n      \n    </div>\n  </div>\n  \n  <div\n    style=\"border:1px solid #e5e7eb;border-radius:10px;padding:10px 12px;background:#eee\">\n\n    <div style=\"font-weight: 600\">\n      3. ALAN TURING\n    </div>\n    <div style=\"color: #6b7280; font-size: 13px\">\n      Parser\n      \n    </div>\n  </div>\n  \n  <div\n    style=\"border:1px solid #e5e7eb;border-radius:10px;padding:10px 12px;background:#faf5ff\">\n\n    <div style=\"font-weight: 600\">\n      4. BARBARA LISKOV\n    </div>\n    <div style=\"color: #6b7280; font-size: 13px\">\n      Type systems\n      · <span style=\"color: #7c3aed\">★ lead</span>\n    </div>\n  </div>\n  \n</div>",
  // Entry template that pulls in two partials via {{> name}}.
  Partials: "<h1>Team</h1>\n<ul>\n  <li>Ada — Compiler</li>\n  <li>Grace — Runtime</li>\n  \n</ul>",
};

const { render, compile } = await createRenderer(await readFile(WASM));
const examples = JSON.parse(await readFile("native/web/examples.json", "utf8"));

let failures = 0;
for (const ex of examples) {
  const want = expected[ex.label];

  // 1. Render the precompiled (BEAM) program.
  const rendered = render(ex.program, ex.data);
  if (rendered !== want) {
    failures++;
    console.error(`  FAIL ${ex.label} (render): got ${JSON.stringify(rendered)}, want ${JSON.stringify(want)}`);
  }

  // 2. Backend-free path: compile the template in-browser, then render it.
  const compiled = compile(ex.template, ex.partials || {});
  if (compiled.error) {
    failures++;
    console.error(`  FAIL ${ex.label} (compile): ${compiled.error.message}`);
  } else {
    const roundTrip = render(compiled.program, ex.data);
    if (roundTrip === want) {
      console.log(`  ok  ${ex.label}: ${JSON.stringify(roundTrip)} (compiled in-browser)`);
    } else {
      failures++;
      console.error(`  FAIL ${ex.label} (compile→render): got ${JSON.stringify(roundTrip)}, want ${JSON.stringify(want)}`);
    }
  }
}

if (failures > 0) {
  console.error(`browser glue: ${failures} check(s) diverged`);
  process.exit(1);
}
console.log(`browser glue: ${examples.length}/${examples.length} examples compile + render correctly`);
