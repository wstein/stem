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
  // A team grid composed from several partials (styles, header, card, avatar, lead_badge).
  "HTML cards": "<style>\n  .banner { font-family: system-ui; margin: 0 0 12px; }\n  .banner h2 { margin: 0; font-size: 1.1rem; }\n  .banner p { margin: 2px 0 0; color: #6b7280; font-size: 13px; }\n  .team { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; font-family: system-ui; }\n  .card { border: 1px solid #e5e7eb; border-radius: 12px; padding: 12px 14px; background: #fff; }\n  .card.lead { background: #faf5ff; }\n  .head { display: flex; align-items: center; gap: 10px; }\n  .avatar { width: 34px; height: 34px; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: #ede9fe; font-size: 18px; }\n  .name { font-weight: 600; }\n  .role { color: #6b7280; font-size: 13px; }\n  .badge { color: #7c3aed; }\n</style>\n<header class=\"banner\">\n  <h2>Engineering team</h2>\n  <p>Who builds Stem</p>\n</header>\n<div class=\"team\">\n  <div class=\"card lead\">\n  <div class=\"head\">\n    <div class=\"avatar\">⚙️</div>\n    <div>\n      <div class=\"name\">1. ADA LOVELACE <span class=\"badge\">★ lead</span></div>\n      <div class=\"role\">Compiler</div>\n    </div>\n  </div>\n</div><div class=\"card \">\n  <div class=\"head\">\n    <div class=\"avatar\">🚀</div>\n    <div>\n      <div class=\"name\">2. GRACE HOPPER</div>\n      <div class=\"role\">Runtime</div>\n    </div>\n  </div>\n</div><div class=\"card \">\n  <div class=\"head\">\n    <div class=\"avatar\">🧩</div>\n    <div>\n      <div class=\"name\">3. ALAN TURING</div>\n      <div class=\"role\">Parser</div>\n    </div>\n  </div>\n</div><div class=\"card lead\">\n  <div class=\"head\">\n    <div class=\"avatar\">🔭</div>\n    <div>\n      <div class=\"name\">4. BARBARA LISKOV <span class=\"badge\">★ lead</span></div>\n      <div class=\"role\">Type systems</div>\n    </div>\n  </div>\n</div>\n</div>",
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
