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
// playground uses this to map a caret on the tag to that partial's output.
export function partialNameAt(source, charIndex) {
  const re = /\{\{~?\s*>\s*([^\s}]+)[^}]*\}\}/g;
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
