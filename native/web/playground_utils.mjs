// SPDX-License-Identifier: Apache-2.0

const encoder = new TextEncoder();

export function debounce(fn, waitMs = 160) {
  let handle = null;
  return (...args) => {
    if (handle !== null) clearTimeout(handle);
    handle = setTimeout(() => {
      handle = null;
      fn(...args);
    }, waitMs);
  };
}

// Rust spans are UTF-8 byte offsets; map them into JS string indices.
export function byteToChar(source, byteOffset) {
  if (byteOffset <= 0) return 0;

  let bytes = 0;
  for (let i = 0; i < source.length; ) {
    if (bytes >= byteOffset) return i;

    const codePoint = source.codePointAt(i);
    const char = String.fromCodePoint(codePoint);
    const charBytes = encoder.encode(char).length;
    if (bytes + charBytes > byteOffset) return i;

    bytes += charBytes;
    i += codePoint > 0xffff ? 2 : 1;
  }

  return source.length;
}

// Inverse of byteToChar: the UTF-8 byte offset of a JS string index, so a
// CodeMirror caret position can be compared against Rust byte spans.
export function charToByte(source, charIndex) {
  const index = Math.max(0, Math.min(charIndex, source.length));
  return encoder.encode(source.slice(0, index)).length;
}

export function byteRangeToCharRange(source, startByte, endByte) {
  const from = byteToChar(source, startByte);
  const to = byteToChar(source, endByte);
  return [from, Math.max(from + 1, to)];
}

// The partial name if `charIndex` sits inside a `{{> name ...}}` tag, else null.
// A partial tag expands inline and produces no output run of its own, so the
// playground uses this to map a caret on the tag to that partial's output. The
// name capture excludes `~` so a trailing whitespace-control marker (`{{> x~}}`)
// isn't taken as part of the name (the compiler strips it, yielding file "x").
export function partialNameAt(source, charIndex) {
  const re = /\{\{~?\s*>\s*([^\s}~]+)[^}]*\}\}/g;
  let m;
  while ((m = re.exec(source)) !== null) {
    if (charIndex >= m.index && charIndex < m.index + m[0].length) return m[1];
  }
  return null;
}

export function charToLineColumn(source, charIndex) {
  const index = Math.max(0, Math.min(charIndex, source.length));
  const upToIndex = source.slice(0, index);
  const lines = upToIndex.split("\n");
  return { line: lines.length, column: lines[lines.length - 1].length + 1 };
}

// Disassemble a `stem-bc/v1` wire program (the object `compile` returns) to the
// human-readable text `Stem.Bytecode.disasm/1` emits on the BEAM, so the
// playground's Bytecode view matches the reference disassembler. Any `src`
// provenance on a mapped program is ignored.
export function disassemble(program) {
  const version = (program && program.version) || "stem-bc/v1";
  const instructions = (program && program.instructions) || [];
  const lines = ["; " + version];
  for (const instr of instructions) lines.push(...disasmInstruction(instr, 0));
  return lines.join("\n") + "\n";
}

function indent(depth) {
  return "  ".repeat(depth);
}

function disasmBranch(label, instructions, depth) {
  if (!instructions || instructions.length === 0) return [];
  const lines = [indent(depth + 1) + label];
  for (const instr of instructions) lines.push(...disasmInstruction(instr, depth + 2));
  return lines;
}

function disasmInstruction(instr, depth) {
  const ind = indent(depth);
  switch (instr.t) {
    case "text":
      return [ind + "EMIT_TEXT " + inspectLiteral(instr.text)];
    case "emit":
      return [ind + "EMIT " + disasmValue(instr.value) + " ESCAPE=" + instr.escape];
    case "if":
      return [
        ind + "IF " + disasmValue(instr.cond),
        ...disasmBranch("THEN", instr.then, depth),
        ...disasmBranch("ELSE", instr.else, depth),
      ];
    case "each":
    case "with": {
      const params =
        instr.params && instr.params.length ? " AS |" + instr.params.join(" ") + "|" : "";
      const head = ind + instr.t.toUpperCase() + " " + disasmValue(instr.subject) + params;
      return [
        head,
        ...disasmBranch("DO", instr.body, depth),
        ...disasmBranch("ELSE", instr.else, depth),
      ];
    }
    case "scope": {
      const entries = Object.entries(instr.hash || {});
      const hash = entries.length
        ? " {" + entries.map(([k, v]) => k + "=" + disasmValue(v)).join(", ") + "}"
        : "";
      return [ind + "SCOPE " + disasmValue(instr.base) + hash, ...disasmBranch("DO", instr.body, depth)];
    }
    default:
      return [ind + String(instr.t).toUpperCase()];
  }
}

function disasmValue(op) {
  switch (op.t) {
    case "lit":
      return "LIT " + inspectLiteral(op.value);
    case "assign":
      return "ASSIGN " + op.name;
    case "assigns":
      return "ASSIGNS";
    case "local":
      return "LOCAL " + op.name;
    case "this":
      return "THIS";
    case "parent":
      return "PARENT";
    case "root":
      return "ROOT";
    case "index":
      return "INDEX0";
    case "index1":
      return "INDEX1";
    case "key":
      return "KEY";
    case "first":
      return "FIRST";
    case "last":
      return "LAST";
    case "get":
      return "GET " + disasmValue(op.base) + " " + op.segments.join(".");
    case "call": {
      const positional = op.args.map(disasmValue).join(", ");
      const keyword = Object.entries(op.kwargs || {})
        .map(([k, v]) => ", " + k + "=" + disasmValue(v))
        .join("");
      return "CALL " + op.name + "(" + positional + keyword + ")";
    }
    default:
      return String(op.t).toUpperCase();
  }
}

// Mirror Elixir's `inspect/1` for the scalar literals the wire carries: strings
// are double-quoted, `null` prints as `nil`, and numbers/booleans print bare.
function inspectLiteral(value) {
  if (value === null) return "nil";
  if (typeof value === "string") return JSON.stringify(value);
  return String(value);
}

export function encodeState(state) {
  const json = JSON.stringify(state);

  if (typeof btoa === "function") {
    return btoa(unescape(encodeURIComponent(json)));
  }

  return Buffer.from(json, "utf8").toString("base64");
}

export function decodeState(encoded) {
  if (typeof atob === "function") {
    return JSON.parse(decodeURIComponent(escape(atob(encoded))));
  }

  return JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
}

// Build the partial dependency graph for the Dependencies inspector view.
// `asts` maps each file name ("main" plus each partial) to its pre-expansion
// `stem-ast/v1` node list (from the engine's `parse_ast`, which keeps `{{> name}}`
// as `partial` nodes). Returns `{ nodes, edges, cycles }`:
//   - nodes: `{ id, isMain, missing }` (missing = referenced but not defined)
//   - edges: `{ from, to, missing }` inclusion edges
//   - cycles: arrays of node ids forming a cycle (Stem forbids partial recursion,
//     so these are the compile-time `partial recursion detected` errors, drawn red)
export function buildDependencyGraph(asts) {
  const known = new Set(Object.keys(asts));
  const nodes = Object.keys(asts).map((id) => ({ id, isMain: id === "main", missing: false }));
  const edges = [];

  const childLists = (node) => [node.then, node.else, node.body].filter(Array.isArray);
  const collect = (nodeList, from) => {
    for (const node of nodeList || []) {
      if (node.t === "partial") {
        edges.push({ from, to: node.name, missing: !known.has(node.name) });
      }
      for (const list of childLists(node)) collect(list, from);
    }
  };
  for (const [id, ast] of Object.entries(asts)) collect(ast, id);

  // Surface referenced-but-undefined partials as their own (missing) nodes.
  for (const edge of edges) {
    if (!known.has(edge.to) && !nodes.some((n) => n.id === edge.to)) {
      nodes.push({ id: edge.to, isMain: false, missing: true });
    }
  }

  return { nodes, edges, cycles: findCycles(nodes, edges) };
}

// Depth-first back-edge search over the (non-missing) inclusion edges.
function findCycles(nodes, edges) {
  const adjacency = new Map();
  for (const edge of edges) {
    if (edge.missing) continue;
    if (!adjacency.has(edge.from)) adjacency.set(edge.from, []);
    adjacency.get(edge.from).push(edge.to);
  }

  const cycles = [];
  const path = [];
  const inPath = new Set();
  const seen = new Set();

  const visit = (id) => {
    if (inPath.has(id)) {
      cycles.push(path.slice(path.indexOf(id)).concat(id));
      return;
    }
    if (seen.has(id)) return;
    seen.add(id);
    path.push(id);
    inPath.add(id);
    for (const next of adjacency.get(id) || []) visit(next);
    path.pop();
    inPath.delete(id);
  };

  for (const node of nodes) visit(node.id);
  return cycles;
}
