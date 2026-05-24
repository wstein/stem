// SPDX-License-Identifier: Apache-2.0
//
// Dynamic evaluation: the template and data are only known at runtime.
//
// Nothing here is baked into the binary by a macro — the template is assembled
// (or read from argv) at runtime, compiled to portable bytecode once, then
// evaluated against each data record. The same custom transformers (host
// getters) resolve as before.
//
//   cargo run --example dynamic_eval                       # built-in template + records
//   cargo run --example dynamic_eval -- '{{ headline }}'   # override the template
//   cargo run --example dynamic_eval -- '{{ slug }}' records.json
//
// `records.json` is a JSON array of data objects.

use serde_json::{json, Value};
use std::fs;

fn main() {
    let mut args = std::env::args().skip(1);

    // Template chosen at runtime. In a real app this would come from a file, a
    // database row, or an HTTP request body — never a compile-time literal.
    let template = args.next().unwrap_or_else(default_template);

    // Compile the runtime template to portable bytecode once...
    let program = match stem_examples::compile(&template) {
        Ok(program) => program,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    };

    // ...then evaluate it against each record (from a JSON-array file argument,
    // else a built-in sample set).
    let records = match args.next() {
        Some(path) => load_records(&path),
        None => sample_records(),
    };

    for data in records {
        println!("{}", stem_examples::render(&program, data));
    }
}

/// Assembled from parts at runtime to underline that the source is dynamic.
fn default_template() -> String {
    [
        "{{ headline }}",
        " — ",
        "{{ slug }}",
        " ({{ reading_time }})",
    ]
    .concat()
}

fn sample_records() -> Vec<Value> {
    [
        "Hello Brave World",
        "Portable Bytecode Everywhere",
        "Rust Meets the BEAM",
    ]
    .into_iter()
    .map(|title| {
        json!({
            "title": title,
            "body": "Stem compiles templates to portable bytecode rendered \
                     natively in Rust and in the browser via WebAssembly, byte \
                     for byte like the BEAM reference engine.",
            "headline":     {"$getter": "shout"},
            "slug":         {"$getter": "slug"},
            "words":        {"$getter": "word_count"},
            "reading_time": {"$getter": "reading_time"}
        })
    })
    .collect()
}

fn load_records(path: &str) -> Vec<Value> {
    let raw = fs::read_to_string(path).unwrap_or_else(|err| {
        eprintln!("cannot read {path}: {err}");
        std::process::exit(1);
    });
    match serde_json::from_str::<Value>(&raw) {
        Ok(Value::Array(items)) => items,
        Ok(other) => vec![other],
        Err(err) => {
            eprintln!("invalid JSON in {path}: {err}");
            std::process::exit(1);
        }
    }
}
