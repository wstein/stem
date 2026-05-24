// SPDX-License-Identifier: Apache-2.0
//
// Shared glue for the example binaries. The `stem_native` engine is a JSON-in /
// string-out renderer: you compile template source to a portable wire program
// (`stem-bc/v1`), then render that program against some data.
//
// Two kinds of transformer are shown:
//
//   * Built-in transformers (`upcase`, `sort`, `join`, ...) are gated by
//     capability group. The render request names the loaded groups; Minimum is
//     always on. These examples load Strings, Collections, and Predicates.
//   * Custom transformers are supplied through the host hook: a
//     `TransformerResolver` the engine consults before its built-ins, so an
//     embedder can add (or override) names. The pipeline value arrives as the
//     first positional argument, mirroring the BEAM `transformers:` binding.

use serde_json::{json, Value};
use stem_native::{handle_with_host, Host, TransformerCall};

// Capability groups these examples load. The example author is trusted, so it
// opts into the data-transformation groups on top of the always-on Minimum.
const GROUPS: &[&str] = &["strings", "collections", "predicates"];

// The custom transformer names our resolver handles. Declared so the engine's
// pre-check admits them (and still refuses genuinely unknown names).
const CUSTOM_NAMES: &[&str] = &["slugify", "reading_time", "shout"];

/// Custom transformers, supplied to the engine through the host hook. Each
/// receives the pipeline value as its first positional argument (the engine
/// prepends it), so `{{ title |> slugify }}` calls `slugify(title)`. Returning
/// `None` falls through to the built-in stdlib.
pub fn custom_transformers(call: &TransformerCall) -> Option<Value> {
    let subject = call.args.first().and_then(Value::as_str).unwrap_or("");
    match call.name {
        // SHOUT the subject.
        "shout" => Some(Value::from(format!("{}!", subject.to_uppercase()))),

        // A URL slug: lowercased words joined with dashes.
        "slugify" => Some(Value::from(
            subject
                .to_lowercase()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join("-"),
        )),

        // Rough reading time at 200 wpm, at least one minute.
        "reading_time" => {
            let words = subject.split_whitespace().count();
            let minutes = ((words as f64) / 200.0).ceil().max(1.0) as i64;
            Some(Value::from(format!("{minutes} min read")))
        }

        _ => None,
    }
}

fn host() -> Host {
    Host {
        transform: custom_transformers,
        transformer_names: CUSTOM_NAMES,
        ..Host::default()
    }
}

/// Compile template source to its portable wire program. Compilation needs no
/// host, so it goes through the plain `handle` entry; a parse error comes back
/// as a message rather than a panic.
pub fn compile(source: &str) -> Result<Value, String> {
    let request = json!({ "compile": source }).to_string();
    let value: Value = serde_json::from_str(&stem_native::handle(&request))
        .map_err(|err| format!("compile returned invalid JSON: {err}"))?;
    if let Some(error) = value.get("error") {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return Err(format!("template compile error: {message}"));
    }
    Ok(value)
}

/// Render a compiled wire program against `data`, loading the example capability
/// groups and resolving custom transformers through the host hook.
pub fn render(program: &Value, data: Value) -> String {
    let request = json!({ "program": program, "data": data, "transformers": GROUPS }).to_string();
    handle_with_host(&request, &host())
}

/// Compile and render a template in one step.
pub fn render_template(source: &str, data: Value) -> Result<String, String> {
    Ok(render(&compile(source)?, data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn custom_transformer_receives_the_pipeline_value() {
        let call = |name: &str, value: &str| {
            let args = [Value::from(value)];
            let kwargs = serde_json::Map::new();
            let assigns = Value::Null;
            let this = Value::Null;
            custom_transformers(&TransformerCall {
                name,
                args: &args,
                kwargs: &kwargs,
                assigns: &assigns,
                this: &this,
            })
        };
        assert_eq!(call("shout", "hi"), Some(Value::from("HI!")));
        assert_eq!(
            call("slugify", "Hello Brave World"),
            Some(Value::from("hello-brave-world"))
        );
        assert_eq!(
            call("reading_time", "one two three"),
            Some(Value::from("1 min read"))
        );
        assert_eq!(call("nope", "x"), None);
    }

    #[test]
    fn builtin_and_custom_transformers_render_together() {
        let out = render_template(
            "{{ title |> upcase }} / {{ title |> slugify }} / {{ tags |> sort |> join(\", \") }}",
            json!({ "title": "Hello Brave World", "tags": ["rust", "beam", "wasm"] }),
        )
        .unwrap();
        assert_eq!(
            out,
            "HELLO BRAVE WORLD / hello-brave-world / beam, rust, wasm"
        );
    }

    #[test]
    fn compile_error_is_reported_not_panicked() {
        assert!(compile("{{ unterminated").is_err());
    }
}
