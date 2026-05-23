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
  for (let i = 0; i < source.length; i++) {
    if (bytes >= byteOffset) return i;
    bytes += encoder.encode(source[i]).length;
  }

  return source.length;
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
