// SPDX-License-Identifier: Apache-2.0
//
// Shared glue for the example binaries, written against `stem_native`'s
// idiomatic Rust API: `compile` returns a typed `Program`, `Program::render`
// returns a `Result`, and capabilities/host extensions are configured through
// `RenderOptions`. No JSON strings cross this boundary — that shape is reserved
// for the Elixir conformance harness.
//
// Two kinds of transformer are shown:
//
//   * Built-in transformers (`upcase`, `sort`, `join`, ...) are loaded by
//     capability group via `RenderOptions`. These examples load Strings,
//     Collections, and Predicates on top of the always-on Minimum.
//   * Custom transformers are supplied through the host hook: a
//     `TransformerResolver` the engine consults before its built-ins. The
//     pipeline value arrives as the first positional argument.

use jsonata_core::{evaluator::Evaluator, parser, value::JValue};
use serde_json::Value;
use stem_native::{
    CompileError, Group, Host, Program, RenderError, RenderOptions, TransformerCall,
};

// The custom transformer names our resolver handles. Declared so the engine's
// pre-check admits them (and still refuses genuinely unknown names).
const CUSTOM_NAMES: &[&str] = &["slugify", "reading_time", "shout"];

/// A failure from any stage of the example pipeline.
#[derive(Debug)]
pub enum StemError {
    /// The template did not compile.
    Compile(CompileError),
    /// The compiled template could not be rendered (e.g. an unloaded group).
    Render(RenderError),
    /// The JSONata preprocessing step failed.
    Jsonata(String),
}

impl std::fmt::Display for StemError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StemError::Compile(err) => write!(f, "compile error: {err}"),
            StemError::Render(err) => write!(f, "render error: {err}"),
            StemError::Jsonata(err) => write!(f, "jsonata error: {err}"),
        }
    }
}

impl std::error::Error for StemError {}

impl From<CompileError> for StemError {
    fn from(err: CompileError) -> Self {
        StemError::Compile(err)
    }
}

impl From<RenderError> for StemError {
    fn from(err: RenderError) -> Self {
        StemError::Render(err)
    }
}

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

/// The render configuration these examples use: the data-transformation
/// capability groups plus the custom transformer host.
pub fn options() -> RenderOptions {
    RenderOptions::new()
        .with_groups([Group::Strings, Group::Collections, Group::Predicates])
        .with_host(Host {
            transform: custom_transformers,
            transformer_names: CUSTOM_NAMES,
            ..Host::default()
        })
}

/// Compile template source to a [`Program`].
pub fn compile(source: &str) -> Result<Program, StemError> {
    Ok(stem_native::compile(source)?)
}

/// Render a compiled program against `data` with the example configuration.
pub fn render(program: &Program, data: &Value) -> Result<String, StemError> {
    Ok(program.render(data, &options())?)
}

/// Compile and render a template in one step.
pub fn render_template(source: &str, data: &Value) -> Result<String, StemError> {
    render(&compile(source)?, data)
}

/// Evaluate a JSONata expression against JSON `data`, returning JSON — the
/// data-preprocessing stage of the `jsonata_pipeline` example. `JValue` is
/// jsonata-core's value type; it is serde-(de)serializable, so it bridges to
/// `serde_json::Value` cleanly.
pub fn jsonata(expr: &str, data: &Value) -> Result<Value, StemError> {
    let ast = parser::parse(expr).map_err(|err| StemError::Jsonata(format!("parse: {err:?}")))?;
    let input: JValue = serde_json::from_value(data.clone())
        .map_err(|err| StemError::Jsonata(format!("input: {err}")))?;
    let output = Evaluator::new()
        .evaluate(&ast, &input)
        .map_err(|err| StemError::Jsonata(format!("eval: {err:?}")))?;
    let encoded = output
        .to_json_string()
        .map_err(|err| StemError::Jsonata(format!("output: {err}")))?;
    serde_json::from_str(&encoded).map_err(|err| StemError::Jsonata(format!("decode: {err}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
            &json!({ "title": "Hello Brave World", "tags": ["rust", "beam", "wasm"] }),
        )
        .unwrap();
        assert_eq!(
            out,
            "HELLO BRAVE WORLD / hello-brave-world / beam, rust, wasm"
        );
    }

    #[test]
    fn compile_error_is_typed() {
        assert!(matches!(
            compile("{{ unterminated"),
            Err(StemError::Compile(_))
        ));
    }

    #[test]
    fn compile_time_macro_yields_a_program() {
        // The template is compiled to bytecode at build time by `stem!`.
        let program = stem_macros::stem!("Hi {{ name |> upcase }}!");
        assert_eq!(
            render(&program, &json!({ "name": "ada" })).unwrap(),
            "Hi ADA!"
        );
    }

    #[test]
    fn unknown_transformer_is_a_render_error() {
        // A name no built-in group provides and the host did not declare is
        // refused as a typed render error rather than smuggled into the output.
        let program = compile("{{ name |> no_such }}").unwrap();
        assert!(matches!(
            render(&program, &json!({ "name": "x" })),
            Err(StemError::Render(_))
        ));
    }

    #[test]
    fn jsonata_preprocesses_into_a_view_model() {
        let data = json!({
            "orders": [
                { "product": "widget", "qty": 3, "price": 10 },
                { "product": "widget", "qty": 2, "price": 10 },
                { "product": "gadget", "qty": 1, "price": 50 }
            ]
        });
        let model = jsonata(
            r#"{ "total": $sum(orders.(qty * price)), "products": $keys(orders{product: $sum(qty)}) }"#,
            &data,
        )
        .unwrap();
        assert_eq!(model["total"], json!(100));
        // Grouping key order is not guaranteed, so compare as a set.
        let mut products = model["products"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|v| v.as_str())
            .collect::<Vec<_>>();
        products.sort_unstable();
        assert_eq!(products, ["gadget", "widget"]);
    }
}
