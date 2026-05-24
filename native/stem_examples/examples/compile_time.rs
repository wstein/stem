// SPDX-License-Identifier: Apache-2.0
//
// Compile-time templates via a `macro_rules!` macro.
//
// The `stem!` macro requires its template argument to be a string *literal*
// (`$source:literal`), so the template is baked into the binary at Rust compile
// time and checked at macro-expansion time — a typo'd `json!` value or a
// non-literal template fails to compile. The Stem source is then lowered to
// portable bytecode on first render (the engine is an interpreter, not a Rust
// proc-macro), and rendered with our custom transformers (host getters).
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
        "# {{ title }}\n\n\
         **{{ headline }}**\n\n\
         - slug: `{{ slug }}`\n\
         - {{ words }} words · {{ reading_time }}\n",
        json!({
            "title": "Hello Brave World",
            "body": "Stem compiles a template down to portable bytecode that a tiny \
                     Rust engine renders byte for byte like the BEAM reference does. \
                     The very same engine also runs in the browser as WebAssembly, \
                     with no server and no Elixir at runtime.",
            // Each field below is computed by a custom transformer (getter),
            // reading its sibling fields above as "self".
            "headline":     {"$getter": "shout"},
            "slug":         {"$getter": "slug"},
            "words":        {"$getter": "word_count"},
            "reading_time": {"$getter": "reading_time"}
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
