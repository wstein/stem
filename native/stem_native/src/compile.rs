// SPDX-License-Identifier: Apache-2.0
//
// Native parser+compiler (Phase B, in progress): lowers Stem template source to
// the same `stem-bc/v1` wire bytecode the BEAM emits via
// `Stem.Bytecode.to_wire/1`, so the browser playground can compile templates
// with no backend. Hand-written recursive descent mirroring `Stem.Parser`
// (a NimbleParsec tokenizer + recursive-descent block assembly on the BEAM).
//
// Coverage grows construct-by-construct, each increment gated by the
// BEAM-vs-Rust bytecode differential harness — the BEAM compiler is the spec
// oracle. Currently ported: literal text, `{{ path }}` (HTML-escaped) and
// `{{{ path }}}` (unescaped), where `path` is an identifier or dotted path at
// top-level scope. Every other construct (blocks, pipelines, transformers,
// `@`-specials, `this`, parent paths, literals, trim markers, partials,
// comments) raises a `CompileError` tagged with its source span until ported,
// so the playground reports "not yet supported" rather than miscompiling.

use serde_json::{json, Value};

const VERSION: &str = "stem-bc/v1";

// A parse/compile failure carrying a byte span into the source, so the editor
// can underline the offending tag (Phase C surfaces this to JS).
#[derive(Debug, PartialEq)]
pub struct CompileError {
    pub message: String,
    pub start: usize,
    pub end: usize,
}

// Compiles template source to the wire program `{"version", "instructions"}`.
pub fn compile_to_wire(source: &str) -> Result<Value, CompileError> {
    let instructions = parse(source)?;
    Ok(json!({ "version": VERSION, "instructions": instructions }))
}

fn parse(src: &str) -> Result<Vec<Value>, CompileError> {
    let bytes = src.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    let mut text_start = 0;

    while i < bytes.len() {
        if bytes[i] == b'{' && bytes.get(i + 1) == Some(&b'{') {
            if i > text_start {
                out.push(text_node(&src[text_start..i]));
            }

            let triple = bytes.get(i + 2) == Some(&b'{');
            let (open, close) = if triple { ("{{{", "}}}") } else { ("{{", "}}") };
            let inner_start = i + open.len();
            let rel = src[inner_start..].find(close).ok_or_else(|| CompileError {
                message: format!("unterminated `{open}` tag"),
                start: i,
                end: src.len(),
            })?;
            let inner = &src[inner_start..inner_start + rel];
            let tag_end = inner_start + rel + close.len();
            let escape = if triple { "none" } else { "html" };

            out.push(compile_tag(inner, escape, i, tag_end)?);
            i = tag_end;
            text_start = i;
        } else {
            i += 1;
        }
    }

    if bytes.len() > text_start {
        out.push(text_node(&src[text_start..]));
    }
    Ok(out)
}

fn text_node(text: &str) -> Value {
    json!({ "t": "text", "text": text })
}

fn compile_tag(inner: &str, escape: &str, start: usize, end: usize) -> Result<Value, CompileError> {
    let expr = inner.trim();

    if expr.is_empty() {
        return Err(unsupported("empty expression", start, end));
    }
    // Reject every construct the bootstrap subset does not yet lower, so an
    // unported template fails loudly instead of silently miscompiling.
    let leading_sigil = expr.starts_with(['#', '/', '>', '!', '~', '@', '&']);
    let has_operator = expr.contains(|c: char| c.is_whitespace()) || expr.contains(['|', '(']);
    let parent_or_this = expr.starts_with("../") || expr == "this" || expr.starts_with("this.");

    if leading_sigil || has_operator || parent_or_this {
        return Err(unsupported(
            format!("expression {expr:?} is not yet supported by the native compiler"),
            start,
            end,
        ));
    }

    Ok(json!({ "t": "emit", "value": lower_path(expr, start, end)?, "escape": escape }))
}

// A top-level path: a bare identifier lowers to `assign`, a dotted path to a
// `get` over the root assign — matching `Stem.Bytecode.compile_value/2` outside
// a block (no locals, not in an each).
fn lower_path(expr: &str, start: usize, end: usize) -> Result<Value, CompileError> {
    let segments: Vec<&str> = expr.split('.').collect();
    if segments.iter().any(|s| !is_identifier(s)) {
        return Err(unsupported(
            format!("expression {expr:?} is not yet supported by the native compiler"),
            start,
            end,
        ));
    }

    let root = segments[0];
    if segments.len() == 1 {
        Ok(json!({ "t": "assign", "name": root }))
    } else {
        Ok(json!({
            "t": "get",
            "base": { "t": "assign", "name": root },
            "segments": segments[1..],
        }))
    }
}

fn is_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {
            chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
        }
        _ => false,
    }
}

fn unsupported(message: impl Into<String>, start: usize, end: usize) -> CompileError {
    CompileError {
        message: message.into(),
        start,
        end,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Authoritative wire from `Stem.Bytecode.to_wire/1` (see commit message);
    // compared as parsed Values so field order is irrelevant.
    fn wire(source: &str) -> Value {
        compile_to_wire(source).expect("should compile")
    }

    #[test]
    fn plain_text() {
        assert_eq!(
            wire("Hello"),
            json!({ "version": "stem-bc/v1", "instructions": [{ "t": "text", "text": "Hello" }] })
        );
    }

    #[test]
    fn bare_identifier_is_an_html_escaped_assign() {
        assert_eq!(
            wire("{{name}}"),
            json!({
                "version": "stem-bc/v1",
                "instructions": [{ "t": "emit", "escape": "html", "value": { "t": "assign", "name": "name" } }]
            })
        );
    }

    #[test]
    fn triple_stash_is_unescaped() {
        assert_eq!(
            wire("{{{raw}}}"),
            json!({
                "version": "stem-bc/v1",
                "instructions": [{ "t": "emit", "escape": "none", "value": { "t": "assign", "name": "raw" } }]
            })
        );
    }

    #[test]
    fn dotted_path_lowers_to_get_over_root_assign() {
        assert_eq!(
            wire("{{a.b.c}}"),
            json!({
                "version": "stem-bc/v1",
                "instructions": [{
                    "t": "emit",
                    "escape": "html",
                    "value": { "t": "get", "base": { "t": "assign", "name": "a" }, "segments": ["b", "c"] }
                }]
            })
        );
    }

    #[test]
    fn text_around_a_tag() {
        assert_eq!(
            wire("Hi {{user.name}}!"),
            json!({
                "version": "stem-bc/v1",
                "instructions": [
                    { "t": "text", "text": "Hi " },
                    { "t": "emit", "escape": "html", "value": { "t": "get", "base": { "t": "assign", "name": "user" }, "segments": ["name"] } },
                    { "t": "text", "text": "!" }
                ]
            })
        );
    }

    #[test]
    fn unterminated_tag_reports_a_span() {
        let err = compile_to_wire("Hi {{name").unwrap_err();
        assert_eq!(err.start, 3);
        assert!(err.message.contains("unterminated"));
    }

    #[test]
    fn unported_constructs_report_a_span() {
        for src in [
            "{{#if x}}y{{/if}}",
            "{{name |> upcase}}",
            "{{@index}}",
            "{{../name}}",
        ] {
            let err = compile_to_wire(src).unwrap_err();
            assert!(err.message.contains("not yet supported"), "for {src:?}");
            assert!(err.end > err.start);
        }
    }
}
