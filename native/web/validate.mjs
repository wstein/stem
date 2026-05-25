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
import jsonata from "./vendor/jsonata.mjs";

const WASM = "native/web/wasm/stem_native_bg.wasm";

const expected = {
  // A data-driven infographic: a JSONata transform turns raw stats into
  // geometry (donut arcs, % bars, waffle grid, sparkline) for an SVG/HTML view.
  infographic: "<style>\n  .ig { font-family: system-ui, sans-serif; color: #1e293b; max-width: 760px; }\n  .ig-hero h1 { margin: 0 0 4px; font-size: 1.6rem; letter-spacing: -.01em; }\n  .ig-hero p { margin: 0 0 16px; color: #64748b; }\n  .ig-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }\n  .ig-card { border: 1px solid #e5e7eb; border-radius: 14px; padding: 14px 16px; background: #fff; box-shadow: 0 1px 2px rgba(16,24,40,.04); }\n  .ig-card.ig-wide { grid-column: 1 / -1; }\n  .ig-card h2 { margin: 0 0 12px; font-size: .92rem; color: #334155; }\n  .ig-donut { display: flex; align-items: center; gap: 16px; }\n  .ig-donut svg { width: 132px; height: 132px; flex: 0 0 auto; }\n  .ig-legend { list-style: none; margin: 0; padding: 0; font-size: 13px; color: #475569; }\n  .ig-legend li { display: flex; align-items: center; gap: 8px; margin: 5px 0; }\n  .ig-legend .sw { width: 11px; height: 11px; border-radius: 3px; flex: 0 0 auto; }\n  .ig-bars { display: flex; flex-direction: column; gap: 10px; }\n  .ig-bar-row { display: flex; align-items: center; gap: 9px; font-size: 13px; }\n  .ig-bar-label { flex: 0 0 80px; color: #475569; }\n  .ig-bar-track { flex: 1 1 auto; height: 10px; background: #f1f5f9; border-radius: 5px; overflow: hidden; }\n  .ig-bar-fill { display: block; height: 100%; border-radius: 5px; }\n  .ig-bar-val { flex: 0 0 26px; text-align: right; font-weight: 600; color: #334155; }\n  .ig-waffle { display: flex; align-items: center; gap: 16px; }\n  .ig-waffle svg { width: 134px; height: 134px; flex: 0 0 auto; }\n  .ig-dot { fill: #e5e7eb; }\n  .ig-dot.on { fill: #7c4dff; }\n  .ig-waffle-pct { font-size: 2.1rem; font-weight: 700; color: #5a2ea6; }\n  .ig-spark { display: block; width: 100%; height: auto; }\n</style>\n\n<div class=\"ig\">\n  <header class=\"ig-hero\">\n    <h1>Stem by the numbers</h1>\n    <p>One engine, two backends, byte-for-byte the same output.</p>\n  </header>\n  <div class=\"ig-grid\">\n    <section class=\"ig-card\">\n      <h2>Render time by phase</h2>\n      <div class=\"ig-donut\">\n  <svg viewBox=\"0 0 140 140\" role=\"img\" aria-label=\"Render time by phase\">\n    <g transform=\"rotate(-90 70 70)\">\n      <circle cx=\"70\" cy=\"70\" r=\"52\" fill=\"none\" stroke=\"#c4b5fd\" stroke-width=\"22\" stroke-dasharray=\"110.78 326.73\" stroke-dashoffset=\"0\"></circle>\n      <circle cx=\"70\" cy=\"70\" r=\"52\" fill=\"none\" stroke=\"#8b6dff\" stroke-width=\"22\" stroke-dasharray=\"58.89 326.73\" stroke-dashoffset=\"-110.78\"></circle>\n      <circle cx=\"70\" cy=\"70\" r=\"52\" fill=\"none\" stroke=\"#5a2ea6\" stroke-width=\"22\" stroke-dasharray=\"157.05 326.73\" stroke-dashoffset=\"-169.67\"></circle>\n    </g>\n  </svg>\n  <ul class=\"ig-legend\">\n    <li><span class=\"sw\" style=\"background:#c4b5fd\"></span>Compile · 34%</li>\n    <li><span class=\"sw\" style=\"background:#8b6dff\"></span>Parse · 18%</li>\n    <li><span class=\"sw\" style=\"background:#5a2ea6\"></span>Render · 48%</li>\n  </ul>\n</div>\n\n    </section>\n    <section class=\"ig-card\">\n      <h2>Transformer stdlib by group</h2>\n      <div class=\"ig-bars\">\n  <div class=\"ig-bar-row\">\n    <span class=\"ig-bar-label\">Collections</span>\n    <span class=\"ig-bar-track\"><span class=\"ig-bar-fill\" style=\"width:240px;background:#c4b5fd\"></span></span>\n    <span class=\"ig-bar-val\">13</span>\n  </div>\n\n  <div class=\"ig-bar-row\">\n    <span class=\"ig-bar-label\">Strings</span>\n    <span class=\"ig-bar-track\"><span class=\"ig-bar-fill\" style=\"width:240px;background:#a98bff\"></span></span>\n    <span class=\"ig-bar-val\">13</span>\n  </div>\n\n  <div class=\"ig-bar-row\">\n    <span class=\"ig-bar-label\">Minimum</span>\n    <span class=\"ig-bar-track\"><span class=\"ig-bar-fill\" style=\"width:147.7px;background:#8b6dff\"></span></span>\n    <span class=\"ig-bar-val\">8</span>\n  </div>\n\n  <div class=\"ig-bar-row\">\n    <span class=\"ig-bar-label\">Predicates</span>\n    <span class=\"ig-bar-track\"><span class=\"ig-bar-fill\" style=\"width:55.4px;background:#7c4dff\"></span></span>\n    <span class=\"ig-bar-val\">3</span>\n  </div>\n\n  <div class=\"ig-bar-row\">\n    <span class=\"ig-bar-label\">I18n</span>\n    <span class=\"ig-bar-track\"><span class=\"ig-bar-fill\" style=\"width:36.9px;background:#5a2ea6\"></span></span>\n    <span class=\"ig-bar-val\">2</span>\n  </div>\n\n</div>\n\n    </section>\n    <section class=\"ig-card\">\n      <h2>Test coverage</h2>\n      <div class=\"ig-waffle\">\n  <svg viewBox=\"0 0 135 135\" role=\"img\" aria-label=\"Test coverage\">\n    <circle cx=\"5\" cy=\"5\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"18\" cy=\"5\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"31\" cy=\"5\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"44\" cy=\"5\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"57\" cy=\"5\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"70\" cy=\"5\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"83\" cy=\"5\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"96\" cy=\"5\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"109\" cy=\"5\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"122\" cy=\"5\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"5\" cy=\"18\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"18\" cy=\"18\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"31\" cy=\"18\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"44\" cy=\"18\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"57\" cy=\"18\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"70\" cy=\"18\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"83\" cy=\"18\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"96\" cy=\"18\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"109\" cy=\"18\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"122\" cy=\"18\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"5\" cy=\"31\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"18\" cy=\"31\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"31\" cy=\"31\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"44\" cy=\"31\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"57\" cy=\"31\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"70\" cy=\"31\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"83\" cy=\"31\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"96\" cy=\"31\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"109\" cy=\"31\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"122\" cy=\"31\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"5\" cy=\"44\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"18\" cy=\"44\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"31\" cy=\"44\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"44\" cy=\"44\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"57\" cy=\"44\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"70\" cy=\"44\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"83\" cy=\"44\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"96\" cy=\"44\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"109\" cy=\"44\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"122\" cy=\"44\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"5\" cy=\"57\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"18\" cy=\"57\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"31\" cy=\"57\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"44\" cy=\"57\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"57\" cy=\"57\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"70\" cy=\"57\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"83\" cy=\"57\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"96\" cy=\"57\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"109\" cy=\"57\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"122\" cy=\"57\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"5\" cy=\"70\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"18\" cy=\"70\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"31\" cy=\"70\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"44\" cy=\"70\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"57\" cy=\"70\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"70\" cy=\"70\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"83\" cy=\"70\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"96\" cy=\"70\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"109\" cy=\"70\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"122\" cy=\"70\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"5\" cy=\"83\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"18\" cy=\"83\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"31\" cy=\"83\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"44\" cy=\"83\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"57\" cy=\"83\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"70\" cy=\"83\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"83\" cy=\"83\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"96\" cy=\"83\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"109\" cy=\"83\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"122\" cy=\"83\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"5\" cy=\"96\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"18\" cy=\"96\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"31\" cy=\"96\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"44\" cy=\"96\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"57\" cy=\"96\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"70\" cy=\"96\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"83\" cy=\"96\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"96\" cy=\"96\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"109\" cy=\"96\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"122\" cy=\"96\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"5\" cy=\"109\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"18\" cy=\"109\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"31\" cy=\"109\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"44\" cy=\"109\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"57\" cy=\"109\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"70\" cy=\"109\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"83\" cy=\"109\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"96\" cy=\"109\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"109\" cy=\"109\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"122\" cy=\"109\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"5\" cy=\"122\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"18\" cy=\"122\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"31\" cy=\"122\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"44\" cy=\"122\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"57\" cy=\"122\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"70\" cy=\"122\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"83\" cy=\"122\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"96\" cy=\"122\" r=\"4.6\" class=\"ig-dot on\"></circle>\n    <circle cx=\"109\" cy=\"122\" r=\"4.6\" class=\"ig-dot\"></circle>\n    <circle cx=\"122\" cy=\"122\" r=\"4.6\" class=\"ig-dot\"></circle>\n  </svg>\n  <div class=\"ig-waffle-pct\">98%</div>\n</div>\n\n    </section>\n    <section class=\"ig-card ig-wide\">\n      <h2>Throughput · commits / sprint · last 38</h2>\n      <svg class=\"ig-spark\" viewBox=\"-6 -6 262 74\" role=\"img\" aria-label=\"Throughput per sprint\">\n  <polyline points=\"0,40.3 50,31.5 100,34.4 150,18.2 200,12.3 250,2\" fill=\"none\" stroke=\"#7c4dff\" stroke-width=\"2.5\" stroke-linejoin=\"round\" stroke-linecap=\"round\"></polyline>\n  <circle cx=\"0\" cy=\"40.3\" r=\"3.5\" fill=\"#5a2ea6\"></circle>\n  <circle cx=\"50\" cy=\"31.5\" r=\"3.5\" fill=\"#5a2ea6\"></circle>\n  <circle cx=\"100\" cy=\"34.4\" r=\"3.5\" fill=\"#5a2ea6\"></circle>\n  <circle cx=\"150\" cy=\"18.2\" r=\"3.5\" fill=\"#5a2ea6\"></circle>\n  <circle cx=\"200\" cy=\"12.3\" r=\"3.5\" fill=\"#5a2ea6\"></circle>\n  <circle cx=\"250\" cy=\"2\" r=\"3.5\" fill=\"#5a2ea6\"></circle>\n</svg>\n\n    </section>\n  </div>\n</div>\n",
  // A data-driven changelog: a JSONata transform groups the flat commit list
  // by type into ordered sections; the template emits Markdown (table + lists).
  markdown: "# Stem v0.5.0\n\n_Released 2026-05-24 · 6 changes_\n\n| Section | Count |\n| --- | ---: |\n| Features | 3 |\n| Fixes | 2 |\n| Documentation | 1 |\n\n\n## Features\n\n- **playground**: editable JSONata transform tab\n- **parser**: literal segment keys\n- **native**: zero-arity getter hook\n\n\n## Fixes\n\n- **renderer**: trailing-tilde partial sync\n- **playground**: single-pass source view\n\n\n## Documentation\n\n- **notes**: MVC pipeline write-up\n\n\n",
  greeting: "Hello World!",
  pipeline: "NINA",
  list: "<ul><li>1. first</li><li>2. second</li><li>3. third</li></ul>",
  // Looping a list of objects into table rows; {{@index1}} is the 1-based counter.
  table: "<table>\n  <thead>\n    <tr><th>#</th><th>Language</th><th>Paradigm</th><th>First release</th></tr>\n  </thead>\n  <tbody>\n    <tr><td>1</td><td>Elixir</td><td>Functional</td><td>2011</td></tr>\n    <tr><td>2</td><td>Rust</td><td>Systems</td><td>2010</td></tr>\n    <tr><td>3</td><td>Python</td><td>Scripting</td><td>1991</td></tr>\n  </tbody>\n</table>\n",
  // Interpolation + a loop straight into Markdown (no transform).
  "markdown-basic": "# Stem\n\n> A tiny, logic-less template engine.\n\n## Features\n\n- Compiles templates to portable bytecode\n- Runs on Elixir and Rust / WebAssembly\n- Escapes output by default\n\nBuilt with **Stem**. Pick an example from the dropdown to keep exploring.\n",
  // Branching with {{#if}}/{{else}}, value-presence {{#if}}, and empty-state {{#unless}}.
  conditionals: "<ul class=\"tasks\">\n  <li>\n    [x] Write the parser\n    <span class=\"pri\">priority: high</span>\n  </li>\n  <li>\n    [ ] Add more tests\n    <span class=\"pri\">priority: high</span>\n  </li>\n  <li>\n    [ ] Polish the docs\n    \n  </li>\n</ul>\n\n",
  // A team grid composed from several partials (styles, header, card, avatar, lead_badge).
  "html-cards": "<style>\n  .banner { font-family: system-ui; margin: 0 0 12px; }\n  .banner h2 { margin: 0; font-size: 1.1rem; }\n  .banner p { margin: 2px 0 0; color: #6b7280; font-size: 13px; }\n  .team { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; font-family: system-ui; }\n  .card { position: relative; display: block; border: 1px solid #e5e7eb; border-radius: 12px; padding: 12px 14px; background: #fff; cursor: pointer; transition: transform .12s ease, box-shadow .12s ease, border-color .12s ease; }\n  .card:hover { transform: translateY(-2px); box-shadow: 0 6px 18px rgba(24, 24, 27, 0.08); border-color: #c4b5fd; }\n  .card.lead { background: #faf5ff; }\n  .card:has(.pick:checked) { border-color: #7c3aed; box-shadow: 0 0 0 2px #ddd6fe; }\n  .pick { position: absolute; opacity: 0; pointer-events: none; }\n  .tip { position: absolute; left: 14px; bottom: calc(100% + 6px); max-width: 90%; background: #18181b; color: #fff; font-size: 12px; padding: 4px 8px; border-radius: 6px; opacity: 0; transform: translateY(4px); transition: opacity .12s ease, transform .12s ease; pointer-events: none; }\n  .card:hover .tip { opacity: 1; transform: translateY(0); }\n  .head { display: flex; align-items: center; gap: 10px; }\n  .avatar { width: 34px; height: 34px; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: #ede9fe; font-size: 18px; }\n  .name { font-weight: 600; }\n  .role { color: #6b7280; font-size: 13px; }\n  .badge { color: #7c3aed; }\n</style>\n<header class=\"banner\">\n  <h2>Engineering team</h2>\n  <p>Who builds Stem · hover for a note, click cards to select</p>\n</header>\n<div class=\"team\">\n  \n<label class=\"card lead\">\n  <input class=\"pick\" type=\"checkbox\" />\n  <span class=\"tip\">Lowers templates to portable bytecode</span>\n  <div class=\"head\">\n    <div class=\"avatar\">⚙️</div>\n    \n<div>\n  \n<div class=\"name\">1. ADA LOVELACE <span class=\"badge\">★ lead</span></div>\n  <div class=\"role\">Compiler</div>\n</div>\n  </div>\n</label>\n<label class=\"card \">\n  <input class=\"pick\" type=\"checkbox\" />\n  <span class=\"tip\">Renders bytecode on every host</span>\n  <div class=\"head\">\n    <div class=\"avatar\">🚀</div>\n    \n<div>\n  \n<div class=\"name\">2. GRACE HOPPER</div>\n  <div class=\"role\">Runtime</div>\n</div>\n  </div>\n</label>\n<label class=\"card \">\n  <input class=\"pick\" type=\"checkbox\" />\n  <span class=\"tip\">Turns source into a clean AST</span>\n  <div class=\"head\">\n    <div class=\"avatar\">🧩</div>\n    \n<div>\n  \n<div class=\"name\">3. ALAN TURING</div>\n  <div class=\"role\">Parser</div>\n</div>\n  </div>\n</label>\n<label class=\"card lead\">\n  <input class=\"pick\" type=\"checkbox\" />\n  <span class=\"tip\">Keeps the contracts honest</span>\n  <div class=\"head\">\n    <div class=\"avatar\">🔭</div>\n    \n<div>\n  \n<div class=\"name\">4. BARBARA LISKOV <span class=\"badge\">★ lead</span></div>\n  <div class=\"role\">Type systems</div>\n</div>\n  </div>\n</label>\n</div>",
  // Entry template that pulls in two partials via {{> name}}.
  partials: "<h2>Our team</h2>\n<ul>\n  <li>Ada — Compiler</li>\n  <li>Grace — Runtime</li>\n  \n</ul>",
  // A partial invoked with a context (`this`) and a hash argument (`badge`).
  "partial-arguments": "<ul><li>Ada — member</li><li>Grace — member</li></ul>",
  // All built-in transformers demonstrated live, organised by capability group.
  "cheat-sheet": "<style>\n*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }\nbody {\n  font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif;\n  font-size: 13px;\n  background: #f8f9fa;\n  color: #1a1a2e;\n  padding: 24px;\n}\nh1 {\n  font-size: 17px;\n  font-weight: 700;\n  letter-spacing: .04em;\n  text-transform: uppercase;\n  color: #1a1a2e;\n  margin-bottom: 20px;\n}\nh1 span { font-weight: 400; opacity: .45; font-size: 12px; letter-spacing: .06em; margin-left: 8px; }\n.sheet { display: grid; gap: 16px; }\n.group { background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px #0001; }\n.group-head {\n  display: flex; align-items: center; gap: 8px;\n  padding: 8px 14px;\n  border-bottom: 1px solid #eee;\n}\n.group-head h2 { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: .08em; }\n.dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }\n.badge {\n  font-size: 9px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em;\n  padding: 1px 5px; border-radius: 3px; opacity: .7; margin-left: 2px;\n}\n.group table { width: 100%; border-collapse: collapse; }\n.group tr { border-bottom: 1px solid #f0f0f0; }\n.group tr:last-child { border-bottom: none; }\n.group tr:hover { background: #fafafa; }\ntd { padding: 6px 14px; vertical-align: top; line-height: 1.6; }\n.col-name { width: 120px; }\n.col-expr { width: 46%; }\n.col-result { }\ncode {\n  font-family: \"JetBrains Mono\", \"Fira Code\", ui-monospace, monospace;\n  font-size: 11.5px;\n}\n.name code { font-weight: 600; }\n.expr code { color: #5c6bc0; }\n.result code { color: #333; }\n.result em { font-style: normal; opacity: .4; font-size: 11px; }\n</style>\n\n<h1>Stem Transformers <span>reference · all results rendered live</span></h1>\n<div class=\"sheet\">\n\n  <!-- ── DEFAULT ─────────────────────────────── -->\n  <div class=\"group\">\n    <div class=\"group-head\" style=\"border-left: 3px solid #6b7280\">\n      <span class=\"dot\" style=\"background:#6b7280\"></span>\n      <h2>default</h2>\n      <span class=\"badge\" style=\"background:#6b72201a;color:#6b7280\">always on</span>\n    </div>\n    <table>\n        <td class=\"col-expr expr\"><code>&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt; |> escape_html</code></td>\n        <td class=\"expr\"><code>say &quot;hello&quot; to everyone |> escape_json</code></td>\n        <td class=\"expr\"><code>fruits |> take(3) |> json</code></td>\n        <td class=\"expr\"><code>fruits |> take(3) |> inspect</code></td>\n        <td class=\"expr\"><code>missing |> default(\"N/A\")</code></td>\n        <td class=\"expr\"><code>fruits |> take(3) |> join(\", \")</code></td>\n        <td class=\"expr\"><code>title |> log</code></td>\n        <td class=\"expr\"><code>fruits |> first</code></td>\n        <td class=\"expr\"><code>fruits |> last</code></td>\n        <td class=\"expr\"><code>fruits |> len</code></td>\n        <td class=\"expr\"><code>config |> lookup(\"host\")</code></td>\n        <td class=\"expr\"><code>fruits |> lookup(2)</code></td>\n        <td class=\"expr\"><code>fruits |> contains(\"apple\")</code></td>\n        <td class=\"expr\"><code>title |> starts_with(\"the\")</code></td>\n        <td class=\"expr\"><code>title |> ends_with(\"fox\")</code></td>\n        <td class=\"expr\"><code>missing |> empty?</code></td>\n        <td class=\"expr\"><code>present |> present?</code></td>\n      table>\n  </div>\n\n  <!-- ── FORMAT ──────────────────────────────── -->\n  <div class=\"group\">\n    <div class=\"group-head\" style=\"border-left: 3px solid #22c55e\">\n      <span class=\"dot\" style=\"background:#22c55e\"></span>\n      <h2>format</h2>\n      <span class=\"badge\" style=\"background:#22c55e1a;color:#15803d\">low risk · atomic value transforms</span>\n    </div>\n    <table>\n        <td class=\"col-expr expr\"><code>title |> upcase</code></td>\n        <td class=\"expr\"><code>blurb |> downcase</code></td>\n        <td class=\"expr\"><code>title |> capitalize</code></td>\n        <td class=\"expr\"><code>str |> trim</code></td>\n        <td class=\"expr\"><code>blurb |> truncate(20, \"…\")</code></td>\n        <td class=\"expr\"><code>title |> replace(\"quick\", \"lazy\")</code></td>\n      table>\n  </div>\n\n  <!-- ── TRANSFORM ───────────────────────────── -->\n  <div class=\"group\">\n    <div class=\"group-head\" style=\"border-left: 3px solid #f59e0b\">\n      <span class=\"dot\" style=\"background:#f59e0b\"></span>\n      <h2>transform</h2>\n      <span class=\"badge\" style=\"background:#f59e0b1a;color:#92400e\">medium risk · structural · may iterate</span>\n    </div>\n    <table>\n        <td class=\"col-expr expr\"><code>fruits |> take(3) |> join(\", \")</code></td>\n        <td class=\"expr\"><code>fruits |> drop(3) |> join(\", \")</code></td>\n        <td class=\"expr\"><code>fruits |> slice(1, 3) |> join(\", \")</code></td>\n        <td class=\"expr\"><code>fruits |> take(4) |> reverse |> join(\", \")</code></td>\n        <td class=\"expr\"><code>fruits |> sort |> join(\", \")</code></td>\n        <td class=\"expr\"><code>people |> sort_by(\"age\") |> map(\"name\") |> join(\", \")</code></td>\n        <td class=\"expr\"><code>people |> map(\"name\") |> join(\", \")</code></td>\n        <td class=\"expr\"><code>people |> filter(\"lead\") |> map(\"name\") |> join(\", \")</code></td>\n        <td class=\"expr\"><code>sparse |> compact |> join(\", \")</code></td>\n        <td class=\"expr\"><code>fruits |> uniq |> sort |> join(\", \")</code></td>\n        <td class=\"expr\"><code>nested |> flatten |> join(\", \")</code></td>\n        <td class=\"expr\"><code>people |> group_by(\"dept\") |> json</code></td>\n      table>\n  </div>\n\n</div>\n",
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
  let data = loadYaml(await readFile(path.join(dir, ex.data), "utf8"));
  // An optional JSONata transform (the Controller) turns raw stats into the
  // drawable view-model the template renders — same step the playground runs.
  if (ex.transform) {
    const expr = await readFile(path.join(dir, ex.transform), "utf8");
    data = jsonata(expr).evaluate(data);
  }
  const partials = {};
  for (const name of ex.partials) {
    partials[name] = await readFile(path.join(dir, `${name}.stem`), "utf8");
  }
  return { main, partials, data };
}

let failures = 0;
for (const ex of manifest) {
  const want = expected[ex.id];
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
  if (output !== expected[ex.id]) {
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
