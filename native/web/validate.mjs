// SPDX-License-Identifier: Apache-2.0
//
// Validates the wasm32-unknown-unknown module + browser glue without a browser.
// For each example it loads the same individual files the browser fetches
// (examples/<id>/main.stem, one .stem per partial, and data.yaml), compiles them
// through the glue, renders, and checks against the expected output. Node uses
// the same WebAssembly API as browsers, so a pass here proves the browser path.
// Run from the repo root:
//
//   node native/web/validate.mjs

import { readFile } from "node:fs/promises";
import path from "node:path";
import { createRenderer } from "./stem.mjs";
import { load as loadYaml } from "./vendor/js-yaml.mjs";

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

const EXAMPLES_DIR = "native/web/examples";

const { render, compile } = await createRenderer(await readFile(WASM));
const manifest = JSON.parse(await readFile(`${EXAMPLES_DIR}.json`, "utf8"));

// Load an example's individual files: main.stem, one .stem per partial, and
// data.yaml — the same files the browser fetches at runtime. The data is YAML,
// parsed with the vendored js-yaml so this matches the browser's parser.
async function loadExample(ex) {
  const dir = path.join(EXAMPLES_DIR, ex.id);
  const main = await readFile(path.join(dir, ex.main), "utf8");
  const data = loadYaml(await readFile(path.join(dir, ex.data), "utf8"));
  const partials = {};
  for (const name of ex.partials) {
    partials[name] = await readFile(path.join(dir, `${name}.stem`), "utf8");
  }
  return { main, partials, data };
}

let failures = 0;
for (const ex of manifest) {
  const want = expected[ex.label];
  const { main, partials, data } = await loadExample(ex);

  // Compile the entry (with its partials) through the engine, then render.
  const compiled = compile(main, partials);
  if (compiled.error) {
    failures++;
    console.error(`  FAIL ${ex.label} (compile): ${compiled.error.message}`);
    continue;
  }

  const rendered = render(compiled.program, data);
  if (rendered === want) {
    console.log(`  ok  ${ex.label}: ${JSON.stringify(rendered)}`);
  } else {
    failures++;
    console.error(`  FAIL ${ex.label}: got ${JSON.stringify(rendered)}, want ${JSON.stringify(want)}`);
  }
}

if (failures > 0) {
  console.error(`browser glue: ${failures} check(s) diverged`);
  process.exit(1);
}
console.log(`browser glue: ${manifest.length}/${manifest.length} examples compile + render correctly`);

// Source-map pass: compile + render each example with `map: true` and assert the
// segments tile the output (ordered, contiguous, no gaps/overlaps, covering the
// whole output in bytes) and attribute every run to a known file. This guards
// the provenance the playground's Source view relies on. Mapped rendering must
// reproduce the same output bytes as the plain path.
const enc = new TextEncoder();
let mapFailures = 0;
for (const ex of manifest) {
  const { main, partials, data } = await loadExample(ex);
  const known = new Set(["main", ...Object.keys(partials)]);

  const compiled = compile(main, partials, { map: true });
  if (compiled.error) {
    mapFailures++;
    console.error(`  FAIL ${ex.label} (map compile): ${compiled.error.message}`);
    continue;
  }

  const { output, segments } = render(compiled.program, data, { map: true });
  if (output !== expected[ex.label]) {
    mapFailures++;
    console.error(`  FAIL ${ex.label} (map output): diverged from the plain render`);
    continue;
  }

  const total = enc.encode(output).length;
  let cursor = 0;
  let problem = null;
  for (const s of segments) {
    if (s.out !== cursor) { problem = `gap/overlap at byte ${cursor} (segment starts ${s.out})`; break; }
    if (!(s.len > 0)) { problem = `empty segment at byte ${s.out}`; break; }
    if (!known.has(s.file)) { problem = `unknown file '${s.file}'`; break; }
    cursor += s.len;
  }
  if (!problem && cursor !== total) problem = `segments cover ${cursor}/${total} output bytes`;

  if (problem) {
    mapFailures++;
    console.error(`  FAIL ${ex.label} (source map): ${problem}`);
  } else {
    console.log(`  ok  ${ex.label}: ${segments.length} segment(s) tile ${total} bytes`);
  }
}

if (mapFailures > 0) {
  console.error(`source map: ${mapFailures} check(s) diverged`);
  process.exit(1);
}
console.log(`source map: ${manifest.length}/${manifest.length} examples tile their output with valid provenance`);
