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
  "HTML cards": "<style>\n  .banner { font-family: system-ui; margin: 0 0 12px; }\n  .banner h2 { margin: 0; font-size: 1.1rem; }\n  .banner p { margin: 2px 0 0; color: #6b7280; font-size: 13px; }\n  .team { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; font-family: system-ui; }\n  .card { position: relative; display: block; border: 1px solid #e5e7eb; border-radius: 12px; padding: 12px 14px; background: #fff; cursor: pointer; transition: transform .12s ease, box-shadow .12s ease, border-color .12s ease; }\n  .card:hover { transform: translateY(-2px); box-shadow: 0 6px 18px rgba(24, 24, 27, 0.08); border-color: #c4b5fd; }\n  .card.lead { background: #faf5ff; }\n  .card:has(.pick:checked) { border-color: #7c3aed; box-shadow: 0 0 0 2px #ddd6fe; }\n  .pick { position: absolute; opacity: 0; pointer-events: none; }\n  .tip { position: absolute; left: 14px; bottom: calc(100% + 6px); max-width: 90%; background: #18181b; color: #fff; font-size: 12px; padding: 4px 8px; border-radius: 6px; opacity: 0; transform: translateY(4px); transition: opacity .12s ease, transform .12s ease; pointer-events: none; }\n  .card:hover .tip { opacity: 1; transform: translateY(0); }\n  .head { display: flex; align-items: center; gap: 10px; }\n  .avatar { width: 34px; height: 34px; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: #ede9fe; font-size: 18px; }\n  .name { font-weight: 600; }\n  .role { color: #6b7280; font-size: 13px; }\n  .badge { color: #7c3aed; }\n</style>\n<header class=\"banner\">\n  <h2>Engineering team</h2>\n  <p>Who builds Stem · hover for a note, click cards to select</p>\n</header>\n<div class=\"team\">\n  \n<label class=\"card lead\">\n  <input class=\"pick\" type=\"checkbox\" />\n  <span class=\"tip\">Lowers templates to portable bytecode</span>\n  <div class=\"head\">\n    <div class=\"avatar\">⚙️</div>\n    \n<div>\n  \n<div class=\"name\">1. ADA LOVELACE <span class=\"badge\">★ lead</span></div>\n  <div class=\"role\">Compiler</div>\n</div>\n  </div>\n</label>\n<label class=\"card \">\n  <input class=\"pick\" type=\"checkbox\" />\n  <span class=\"tip\">Renders bytecode on every host</span>\n  <div class=\"head\">\n    <div class=\"avatar\">🚀</div>\n    \n<div>\n  \n<div class=\"name\">2. GRACE HOPPER</div>\n  <div class=\"role\">Runtime</div>\n</div>\n  </div>\n</label>\n<label class=\"card \">\n  <input class=\"pick\" type=\"checkbox\" />\n  <span class=\"tip\">Turns source into a clean AST</span>\n  <div class=\"head\">\n    <div class=\"avatar\">🧩</div>\n    \n<div>\n  \n<div class=\"name\">3. ALAN TURING</div>\n  <div class=\"role\">Parser</div>\n</div>\n  </div>\n</label>\n<label class=\"card lead\">\n  <input class=\"pick\" type=\"checkbox\" />\n  <span class=\"tip\">Keeps the contracts honest</span>\n  <div class=\"head\">\n    <div class=\"avatar\">🔭</div>\n    \n<div>\n  \n<div class=\"name\">4. BARBARA LISKOV <span class=\"badge\">★ lead</span></div>\n  <div class=\"role\">Type systems</div>\n</div>\n  </div>\n</label>\n</div>",
  // Entry template that pulls in two partials via {{> name}}.
  Partials: "<h2>Our team</h2>\n<ul>\n  <li>Ada — Compiler</li>\n  <li>Grace — Runtime</li>\n  \n</ul>",
  // A partial invoked with a context (`this`) and a hash argument (`badge`).
  "Partial arguments": "<ul><li>Ada — member</li><li>Grace — member</li></ul>",
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
