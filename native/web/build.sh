#!/usr/bin/env sh
# SPDX-License-Identifier: Apache-2.0
#
# Build the browser engine and generate its JS bindings into native/web/wasm/.
# Requires the wasm target and a matching wasm-bindgen CLI:
#
#   rustup target add wasm32-unknown-unknown
#   cargo install wasm-bindgen-cli --version 0.2.122   # match the wasm-bindgen crate
#
# Then serve native/web/ over HTTP and open index.html.
set -eu

here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

cargo build --release --target wasm32-unknown-unknown --lib \
  --manifest-path "$here/../stem_native/Cargo.toml"

wasm-bindgen --target web --no-typescript \
  --out-dir "$here/wasm" \
  "$here/../stem_native/target/wasm32-unknown-unknown/release/stem_native.wasm"

echo "wrote $here/wasm/{stem_native.js, stem_native_bg.wasm}"
