// SPDX-License-Identifier: Apache-2.0

import test from "node:test";
import assert from "node:assert/strict";
import {
  byteToChar,
  byteRangeToCharRange,
  charToByte,
  charToLineColumn,
  decodeState,
  encodeState
} from "./playground_utils.mjs";

test("byteToChar maps UTF-8 byte offsets to JS character indices", () => {
  const source = "A😀B";

  assert.equal(byteToChar(source, 0), 0);
  assert.equal(byteToChar(source, 1), 1);
  assert.equal(byteToChar(source, 2), 1);
  assert.equal(byteToChar(source, 5), 3);
  assert.equal(byteToChar(source, 6), 4);
});

test("charToByte maps JS character indices to UTF-8 byte offsets", () => {
  const source = "A😀B";

  assert.equal(charToByte(source, 0), 0);
  assert.equal(charToByte(source, 1), 1); // after "A"
  assert.equal(charToByte(source, 3), 5); // after "A😀" (😀 is 4 bytes)
  assert.equal(charToByte(source, 4), 6); // after "A😀B"
  // Inverts byteToChar on character boundaries.
  for (const byte of [0, 1, 5, 6]) {
    assert.equal(charToByte(source, byteToChar(source, byte)), byte);
  }
});

test("byteRangeToCharRange returns a safe non-empty range", () => {
  const source = "line 1\nline 2";

  const [from, to] = byteRangeToCharRange(source, 0, 0);
  assert.equal(from, 0);
  assert.equal(to, 1);

  const [from2, to2] = byteRangeToCharRange(source, 2, 6);
  assert.equal(from2, 2);
  assert.equal(to2, 6);
});

test("charToLineColumn reports 1-based line and column", () => {
  const source = "ab\ncd\nef";

  assert.deepEqual(charToLineColumn(source, 0), { line: 1, column: 1 });
  assert.deepEqual(charToLineColumn(source, 3), { line: 2, column: 1 });
  assert.deepEqual(charToLineColumn(source, 7), { line: 3, column: 2 });
});

test("state encode/decode round-trips", () => {
  const state = {
    tabs: [{ n: "main", s: "Hello {{name}}" }, { n: "card", s: "<div>{{name}}</div>" }],
    d: "{\n  \"name\": \"Ada\"\n}",
    e: "html",
    v: "rendered"
  };

  const encoded = encodeState(state);
  const decoded = decodeState(encoded);

  assert.deepEqual(decoded, state);
});
