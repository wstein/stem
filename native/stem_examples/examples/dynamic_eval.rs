// SPDX-License-Identifier: Apache-2.0
//
// Dynamic evaluation: the template and data are only known at runtime.
//
// Nothing here is baked into the binary by a macro — the template is assembled
// (or read from argv) at runtime, compiled to portable bytecode once, then
// evaluated against each data record. Built-in transformers (gated by the loaded
// capability groups) and custom transformers (the host hook) resolve the same
// way as in the compile-time example.
//
//   cargo run --example dynamic_eval                          # built-in template + records
//   cargo run --example dynamic_eval -- '{{ title |> slugify }}'
//   cargo run --example dynamic_eval -- '{{ title |> upcase }}' records.json
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

/// Assembled from parts at runtime to underline that the source is dynamic. It
/// mixes built-in (`upcase`, `sort`, `join`) and custom (`slugify`)
/// transformers.
fn default_template() -> String {
    [
        "{{ title |> upcase }}",
        " — ",
        "{{ title |> slugify }}",
        " [{{ tags |> sort |> join(\", \") }}]",
    ]
    .concat()
}

fn sample_records() -> Vec<Value> {
    [
        ("Hello Brave World", json!(["wasm", "beam", "rust"])),
        ("Portable Bytecode Everywhere", json!(["edge", "browser"])),
        ("Rust Meets the BEAM", json!(["parity", "wasm"])),
    ]
    .into_iter()
    .map(|(title, tags)| json!({ "title": title, "tags": tags }))
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
