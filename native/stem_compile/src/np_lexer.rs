// SPDX-License-Identifier: Apache-2.0
//
// Combinator lexer — a `nimble_parsec_rs` port of `Stem.Parser`'s `do_lex`
// grammar (the Elixir reference). It recognizes the raw lexical units of a
// template (text runs, block/inline comments, `{{{{#raw}}}}` blocks, `{{{ }}}`
// and `{{ }}` tags); trim markers, backslash escapes, and tag classification
// run as a separate assembly pass, mirroring Elixir's split between the
// NimbleParsec `do_lex` and the hand-written `assemble_tokens`.
//
// This is phase one of replacing the hand-written `tokenize`: it produces the
// raw token stream, validated against the reference grammar (see the tests).
// Phase two adds per-token spans and the trim/escape/classify assembler, then
// swaps the production path and removes this allow once `raw_lex` is wired in.
#![allow(dead_code)]

use nimble_parsec_rs::{
    ascii_string, choice, ignore, lookahead_not, post_traverse, repeat, string, utf8_char,
    AsciiPredicate, Parser, Value,
};

use crate::CompileError;

// A raw lexical token from `do_lex`, before trim/escape/classification. Mirrors
// the tagged tokens Elixir's `do_lex` emits (`:text_chunk`, `:block_comment`, …).
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Lexeme {
    // A run of text not starting a `{{` tag.
    Text(String),
    // `{{!-- … --}}` and `{{! … }}`; content is dropped during assembly.
    BlockComment,
    InlineComment,
    // `{{{{#name}}}}…{{{{/name}}}}`; carries the verbatim content (names matched).
    RawBlock(String),
    // The inner text of a `{{{ … }}}` raw tag.
    RawTag(String),
    // The inner text of a `{{ … }}` standard tag.
    StandardTag(String),
}

// A `[a-zA-Z0-9_-]+` identifier, as the raw-block open/close name.
fn name_predicates() -> Vec<AsciiPredicate> {
    vec![
        AsciiPredicate::Range(b'a'..=b'z'),
        AsciiPredicate::Range(b'A'..=b'Z'),
        AsciiPredicate::Range(b'0'..=b'9'),
        AsciiPredicate::Char(b'_'),
        AsciiPredicate::Char(b'-'),
    ]
}

// Collapse a run of `utf8_char` codepoint integers into a single string value,
// the role Elixir fills with `reduce({List, :to_string, []})`.
fn codepoints_to_string(tokens: Vec<Value>) -> Value {
    let text: String = tokens
        .iter()
        .filter_map(|value| match value {
            Value::Int(int) => int.to_string().parse::<u32>().ok().and_then(char::from_u32),
            _ => None,
        })
        .collect();
    Value::Str(text)
}

// `repeat(utf8_char)` stopping before `stop`, reduced to a string.
fn chars_until(stop: &'static str) -> Parser {
    repeat(lookahead_not(string(stop)).then(utf8_char(vec![])), 0, None)
        .reduce(codepoints_to_string)
}

fn text_chunk() -> Parser {
    // At least one char that does not start a `{{` tag.
    repeat(lookahead_not(string("{{")).then(utf8_char(vec![])), 1, None)
        .reduce(codepoints_to_string)
        .tagged("text")
}

fn block_comment() -> Parser {
    ignore(string("{{!--"))
        .then(ignore(chars_until("--}}")))
        .then(ignore(string("--}}")))
        .tagged("block_comment")
}

fn inline_comment() -> Parser {
    ignore(string("{{!"))
        .then(ignore(chars_until("}}")))
        .then(ignore(string("}}")))
        .tagged("inline_comment")
}

fn raw_block() -> Parser {
    let parser = ignore(string("{{{{#"))
        .then(ascii_string(name_predicates(), 1, None))
        .then(ignore(string("}}}}")))
        .then(chars_until("{{{{/"))
        .then(ignore(string("{{{{/")))
        .then(ascii_string(name_predicates(), 1, None))
        .then(ignore(string("}}}}")));

    // Validate the open/close names match and keep only the content, mirroring
    // Elixir's `validate_and_reduce_raw_block`.
    post_traverse(parser, |tokens, context, _cursor| match tokens.as_slice() {
        [Value::Str(open), Value::Str(content), Value::Str(close)] => {
            if open == close {
                Ok((vec![Value::Str(content.clone())], context))
            } else {
                Err(format!(
                    "raw block open `{{{{{{{{#{open}}}}}}}}}` is closed by `{{{{{{{{/{close}}}}}}}}}`"
                ))
            }
        }
        _ => Err("malformed raw block".to_string()),
    })
    .tagged("raw_block")
}

fn raw_tag() -> Parser {
    ignore(string("{{{"))
        .then(chars_until("}}}"))
        .then(ignore(string("}}}")))
        .tagged("raw_tag")
}

fn standard_tag() -> Parser {
    ignore(string("{{"))
        .then(chars_until("}}"))
        .then(ignore(string("}}")))
        .tagged("standard_tag")
}

fn do_lex() -> Parser {
    repeat(
        choice(vec![
            block_comment(),
            inline_comment(),
            raw_block(),
            raw_tag(),
            standard_tag(),
            text_chunk(),
        ]),
        0,
        None,
    )
}

// Lex a template source into raw tokens, mirroring `Stem.Parser.do_lex/1`.
// Errors carry a coarse span (the failure offset) until the assembler tracks
// per-token spans in the next phase.
pub(crate) fn raw_lex(source: &str) -> Result<Vec<Lexeme>, CompileError> {
    match do_lex().parse(source) {
        Ok(success) if success.rest.is_empty() => {
            success.tokens.into_iter().map(raw_from_value).collect()
        }
        Ok(success) => Err(CompileError {
            message: "unexpected input while lexing template".to_string(),
            start: success.cursor.byte_offset,
            end: source.len(),
        }),
        Err(failure) => Err(CompileError {
            message: failure.reason,
            start: failure.cursor.byte_offset,
            end: source.len(),
        }),
    }
}

fn raw_from_value(value: Value) -> Result<Lexeme, CompileError> {
    let internal = |message: &str| CompileError {
        message: format!("internal lexer error: {message}"),
        start: 0,
        end: 0,
    };
    let Value::Tagged(name, mut items) = value else {
        return Err(internal("lexer token is not tagged"));
    };
    let text = |items: &mut Vec<Value>| match items.pop() {
        Some(Value::Str(text)) => Ok(text),
        _ => Err(internal("lexer token is missing its string payload")),
    };
    match name.as_str() {
        "text" => Ok(Lexeme::Text(text(&mut items)?)),
        "block_comment" => Ok(Lexeme::BlockComment),
        "inline_comment" => Ok(Lexeme::InlineComment),
        "raw_block" => Ok(Lexeme::RawBlock(text(&mut items)?)),
        "raw_tag" => Ok(Lexeme::RawTag(text(&mut items)?)),
        "standard_tag" => Ok(Lexeme::StandardTag(text(&mut items)?)),
        other => Err(internal(&format!("unknown lexer tag `{other}`"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_and_standard_tags() {
        assert_eq!(
            raw_lex("Hi {{name}}!").unwrap(),
            vec![
                Lexeme::Text("Hi ".to_string()),
                Lexeme::StandardTag("name".to_string()),
                Lexeme::Text("!".to_string()),
            ]
        );
    }

    #[test]
    fn triple_tag_is_a_raw_tag() {
        assert_eq!(
            raw_lex("{{{raw}}}").unwrap(),
            vec![Lexeme::RawTag("raw".to_string())]
        );
    }

    #[test]
    fn comments_are_recognized_before_tags() {
        // `{{!-- --}}` must win over `{{!`/`{{`, and `{{{` over `{{`.
        assert_eq!(
            raw_lex("a{{!-- c --}}b{{! d }}e").unwrap(),
            vec![
                Lexeme::Text("a".to_string()),
                Lexeme::BlockComment,
                Lexeme::Text("b".to_string()),
                Lexeme::InlineComment,
                Lexeme::Text("e".to_string()),
            ]
        );
    }

    #[test]
    fn raw_block_keeps_verbatim_content() {
        assert_eq!(
            raw_lex("{{{{#raw}}}}{{name}}{{{{/raw}}}}").unwrap(),
            vec![Lexeme::RawBlock("{{name}}".to_string())]
        );
    }

    // Mismatched/unclosed raw-block names are rejected by a separate pre-pass
    // (Elixir's `check_raw_blocks`, the hand-written tokenizer's close-by-name
    // search), not by `do_lex` recognition: on a name mismatch the `raw_block`
    // post_traverse rejects and `choice` backtracks, re-lexing the braces as
    // other tokens. That validation lands with the assembler phase; here we only
    // assert that a *matching* raw block is recognized (above).

    #[test]
    fn blocks_and_partials_lex_as_standard_tags() {
        assert_eq!(
            raw_lex("{{#each xs}}{{> p}}{{/each}}").unwrap(),
            vec![
                Lexeme::StandardTag("#each xs".to_string()),
                Lexeme::StandardTag("> p".to_string()),
                Lexeme::StandardTag("/each".to_string()),
            ]
        );
    }
}
