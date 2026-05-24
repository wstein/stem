// SPDX-License-Identifier: Apache-2.0
//
// Shared glue for the two example binaries. The `stem_native` engine is a
// JSON-in / string-out renderer: you compile template source to a portable
// wire program (`stem-bc/v1`), then render that program against some data.
//
// Custom transformers: the engine's built-in transformer stdlib (`upcase`,
// `join`, `truncate`, ...) is a *closed* set — an unknown name in a `{{ x |
// name }}` pipe is refused, not dispatched to host code. The one extension
// point an embedder gets is the getter hook: a data field whose value is the
// sentinel `{"$getter": "<name>"}` is computed by a host `fn(name, parent)`
// at render time, with `parent` as its "self". So in these examples a "custom
// transformer" is a custom getter — host Rust that derives a value from its
// sibling fields.

use serde_json::{json, Value};
use stem_native::handle_with_getters;

/// Custom value transformers, exposed to templates through the getter hook.
///
/// Each arm reads sibling fields from `parent` (the object that carried the
/// `{"$getter": ...}` sentinel) and returns a computed [`Value`]. An unknown
/// name resolves to null, mirroring the engine's default resolver.
pub fn custom_transformers(name: &str, parent: &Value) -> Value {
    let field = |key: &str| parent.get(key).and_then(Value::as_str).unwrap_or("");
    match name {
        // SHOUT the title.
        "shout" => Value::from(format!("{}!", field("title").to_uppercase())),

        // URL slug from the title: lowercased words joined with dashes.
        "slug" => {
            let slug = field("title")
                .to_lowercase()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join("-");
            Value::from(slug)
        }

        // Word count of the body.
        "word_count" => Value::from(field("body").split_whitespace().count()),

        // Rough reading time of the body at 200 wpm, at least one minute.
        "reading_time" => {
            let words = field("body").split_whitespace().count();
            let minutes = ((words as f64) / 200.0).ceil().max(1.0) as i64;
            Value::from(format!("{minutes} min read"))
        }

        _ => Value::Null,
    }
}

/// Compile template source to its portable wire program. Compilation needs no
/// getters, so it goes through the plain `handle` entry; a parse error comes
/// back as a message rather than a panic.
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

/// Render a compiled wire program against `data`, resolving custom transformers
/// at every assign and dotted-path step.
pub fn render(program: &Value, data: Value) -> String {
    let request = json!({ "program": program, "data": data }).to_string();
    handle_with_getters(&request, custom_transformers)
}

/// Compile and render a template in one step.
pub fn render_template(source: &str, data: Value) -> Result<String, String> {
    Ok(render(&compile(source)?, data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn custom_transformer_computes_from_self() {
        let data = json!({ "title": "Hello Brave World", "body": "one two three" });
        assert_eq!(
            custom_transformers("shout", &data),
            json!("HELLO BRAVE WORLD!")
        );
        assert_eq!(
            custom_transformers("slug", &data),
            json!("hello-brave-world")
        );
        assert_eq!(custom_transformers("word_count", &data), json!(3));
        assert_eq!(
            custom_transformers("reading_time", &data),
            json!("1 min read")
        );
        assert_eq!(custom_transformers("nope", &data), Value::Null);
    }

    #[test]
    fn render_template_resolves_custom_transformers() {
        let out = render_template(
            "{{ headline }} / {{ slug }} / {{ words }}",
            json!({
                "title": "Hello Brave World",
                "body": "a b c d",
                "headline": {"$getter": "shout"},
                "slug": {"$getter": "slug"},
                "words": {"$getter": "word_count"}
            }),
        )
        .unwrap();
        assert_eq!(out, "HELLO BRAVE WORLD! / hello-brave-world / 4");
    }

    #[test]
    fn compile_error_is_reported_not_panicked() {
        assert!(compile("{{ unterminated").is_err());
    }
}
