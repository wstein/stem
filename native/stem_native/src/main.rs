// SPDX-License-Identifier: Apache-2.0
//
// WASI bin: read a JSON request on stdin, render it via the engine library,
// write the output to stdout. Built for the host or for wasm32-wasip1 and
// driven by `mix stem.native.verify` / `mix stem.native.fuzz`.

use std::io::{Read, Write};

fn main() {
    let mut raw = String::new();
    if std::io::stdin().read_to_string(&mut raw).is_err() {
        std::process::exit(1);
    }

    let output = stem_native::handle(&raw);
    let mut stdout = std::io::stdout();
    let _ = stdout.write_all(output.as_bytes());
    let _ = stdout.flush();
}
