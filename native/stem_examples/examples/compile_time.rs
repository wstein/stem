// SPDX-License-Identifier: Apache-2.0
//
// Compile-time templates via a `macro_rules!` macro.
//
// The `stem!` macro requires its template argument to be a string *literal*
// (`$source:literal`), so the template is baked into the binary at Rust compile
// time and checked at macro-expansion time. The Stem source is lowered to
// portable bytecode on first render (the engine is an interpreter, not a proc
// macro), then rendered with the loaded capability groups and custom
// transformers (see `src/lib.rs`).
//
//   cargo run --example compile_time

use serde_json::json;

/// Expands to a compile + render call. The template must be a literal, so it
/// lives in the binary and cannot be swapped at runtime.
macro_rules! stem {
    ($source:literal, $data:expr $(,)?) => {
        stem_examples::render_template($source, $data)
    };
}

fn main() {
    let result = stem!(
        // `upcase` and `truncate` are built-in (Strings); `sort`/`join` are
        // built-in (Collections/Minimum); `slugify` and `reading_time` are
        // custom transformers supplied by the host.
        "# {{ title |> upcase }}\n\n\
         - slug: `{{ title |> slugify }}`\n\
         - tags: {{ tags |> sort |> join(\", \") }}\n\
         - {{ body |> reading_time }}\n\
         - teaser: {{ body |> truncate(24, \"…\") }}\n",
        json!({
            "title": "Hello Brave World",
            "tags": ["wasm", "beam", "rust"],
            "body": "Stem compiles a template down to portable bytecode that a tiny \
                     Rust engine renders byte for byte like the BEAM reference does. \
                     The same engine also runs in the browser as WebAssembly."
        })
    );

    match result {
        Ok(rendered) => print!("{rendered}"),
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    }
}
