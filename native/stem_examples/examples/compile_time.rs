// SPDX-License-Identifier: Apache-2.0
//
// Compile-time templates via the `stem_macros::stem!` proc-macro.
//
// `stem!` runs the Stem compiler at Rust *build* time: the template literal is
// lowered to bytecode during compilation (a template syntax error becomes a Rust
// compile error), and the bytecode is embedded in the binary. At runtime only
// the cheap wire deserialize happens — no Stem-syntax parsing. The macro expands
// to a `stem_native::Program`, rendered here with the example's capability groups
// and custom transformers.
//
//   cargo run --example compile_time

use serde_json::json;
use stem_macros::stem;

fn main() {
    // Compiled at build time. Try introducing a syntax error (e.g. `{{ title`)
    // and `cargo build` will fail pointing at this literal.
    let program = stem!(
        "# {{ title |> upcase }}\n\n\
         - slug: `{{ title |> slugify }}`\n\
         - tags: {{ tags |> sort |> join(\", \") }}\n\
         - {{ body |> reading_time }}\n\
         - teaser: {{ body |> truncate(24, \"…\") }}\n"
    );

    let data = json!({
        "title": "Hello Brave World",
        "tags": ["wasm", "beam", "rust"],
        "body": "Stem compiles a template down to portable bytecode that a tiny \
                 Rust engine renders byte for byte like the BEAM reference does. \
                 The same engine also runs in the browser as WebAssembly."
    });

    match stem_examples::render(&program, &data) {
        Ok(rendered) => print!("{rendered}"),
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    }
}
