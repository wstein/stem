// SPDX-License-Identifier: Apache-2.0
//
// Native parser+compiler (Phase B, in progress): lowers Stem template source to
// the same `stem-bc/v1` wire bytecode the BEAM emits via
// `Stem.Bytecode.to_wire/1`, so the browser playground can compile templates
// with no backend. Hand-written recursive descent mirroring `Stem.Parser`
// (a NimbleParsec tokenizer + recursive-descent block assembly on the BEAM) and
// `Stem.Bytecode.compile/2`'s scope-aware lowering.
//
// Coverage grows construct-by-construct, each increment gated by the
// BEAM-vs-Rust bytecode differential harness (`mix stem.native.compile_diff`) —
// the BEAM compiler is the spec oracle. Currently ported:
//
//   * literal text;
//   * `{{ expr }}` (HTML-escaped) and `{{{ expr }}}` (unescaped);
//   * block helpers `{{#if}}` / `{{#unless}}` / `{{#each}}` / `{{#with}}` with
//     `{{else}}` and `as |..|` block params;
//   * expressions: identifiers, dotted paths, `this`/`this.x`,
//     `@index`/`@index1`/`@key`, and parent (`../name`) references, with the
//     same local/`this`/assign scope resolution the BEAM uses;
//   * transformer calls and `|>` pipelines, with positional and `key=value` /
//     `key: value` keyword args and parenthesised sub-expressions;
//   * literals: integers, `true`/`false`, `null`/`nil`, and simple
//     double-quoted strings.
//
// Not yet ported (raise a spanned `CompileError`, so the playground shows "not
// yet supported" rather than miscompiling): single-quoted charlists and
// escaped/interpolated strings, partials, regions/yields, comments, and
// whitespace-control markers.

use serde_json::{json, Value};
use std::collections::HashSet;

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
    let tokens = tokenize(source)?;
    let nodes = assemble(tokens)?;
    let instructions = lower_nodes(&nodes, &Scope::root())?;
    Ok(json!({ "version": VERSION, "instructions": instructions }))
}

// ── Tokenizer ────────────────────────────────────────────────────────────────

type Span = (usize, usize);

#[derive(Debug, Clone, Copy, PartialEq)]
enum Block {
    If,
    Unless,
    Each,
    With,
}

impl Block {
    fn parse(word: &str) -> Option<Self> {
        match word {
            "if" => Some(Block::If),
            "unless" => Some(Block::Unless),
            "each" => Some(Block::Each),
            "with" => Some(Block::With),
            _ => None,
        }
    }

    fn tag(self) -> &'static str {
        match self {
            Block::If => "if",
            Block::Unless => "unless",
            Block::Each => "each",
            Block::With => "with",
        }
    }
}

enum Token {
    Text(String),
    Expr {
        raw: String,
        escape: &'static str,
        span: Span,
    },
    Open {
        kind: Block,
        args: String,
        span: Span,
    },
    Else(Span),
    Close {
        kind: Block,
        span: Span,
    },
}

fn tokenize(src: &str) -> Result<Vec<Token>, CompileError> {
    let bytes = src.as_bytes();
    let mut tokens = Vec::new();
    let mut i = 0;
    let mut text_start = 0;

    while i < bytes.len() {
        if bytes[i] == b'{' && bytes.get(i + 1) == Some(&b'{') {
            if i > text_start {
                tokens.push(Token::Text(src[text_start..i].to_string()));
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

            tokens.push(classify(inner, triple, (i, tag_end))?);
            i = tag_end;
            text_start = i;
        } else {
            i += 1;
        }
    }

    if bytes.len() > text_start {
        tokens.push(Token::Text(src[text_start..].to_string()));
    }
    Ok(tokens)
}

fn classify(inner: &str, triple: bool, span: Span) -> Result<Token, CompileError> {
    let trimmed = inner.trim();
    if trimmed.is_empty() {
        return Err(unsupported("empty expression", span));
    }

    // A triple stash is always an expression (it never opens a block); whether
    // the expression itself is ported is decided later in `parse_expr`.
    if triple {
        return Ok(Token::Expr {
            raw: inner.to_string(),
            escape: "none",
            span,
        });
    }

    if trimmed.starts_with('~') || trimmed.ends_with('~') {
        return Err(unsupported(
            "whitespace-control markers are not yet supported by the native compiler",
            span,
        ));
    }

    match trimmed.chars().next().unwrap() {
        '#' => {
            let (word, args) = split_first_word(trimmed[1..].trim_start());
            let kind = Block::parse(word).ok_or_else(|| {
                unsupported(
                    format!("block `{{#{word}}}` is not yet supported by the native compiler"),
                    span,
                )
            })?;
            Ok(Token::Open {
                kind,
                args: args.to_string(),
                span,
            })
        }
        '/' => {
            let word = trimmed[1..].trim();
            let kind = Block::parse(word)
                .ok_or_else(|| unsupported(format!("unknown closing tag `{{/{word}}}`"), span))?;
            Ok(Token::Close { kind, span })
        }
        '>' | '!' | '&' => Err(unsupported(
            "partials, comments, and `{{&}}` tags are not yet supported by the native compiler",
            span,
        )),
        _ if trimmed == "else" => Ok(Token::Else(span)),
        _ => Ok(Token::Expr {
            raw: inner.to_string(),
            escape: "html",
            span,
        }),
    }
}

// ── Recursive-descent assembly ───────────────────────────────────────────────

enum Stop {
    Eof,
    Else(Span),
    Close(Block, Span),
}

enum Node {
    Text(String),
    Emit {
        expr: Expr,
        escape: &'static str,
        span: Span,
    },
    If {
        cond: Expr,
        then: Vec<Node>,
        otherwise: Vec<Node>,
        span: Span,
    },
    Each {
        subject: Expr,
        params: Vec<String>,
        body: Vec<Node>,
        otherwise: Vec<Node>,
        span: Span,
    },
    With {
        subject: Expr,
        params: Vec<String>,
        body: Vec<Node>,
        otherwise: Vec<Node>,
        span: Span,
    },
}

fn assemble(tokens: Vec<Token>) -> Result<Vec<Node>, CompileError> {
    let mut it = tokens.into_iter();
    let (nodes, stop) = collect(&mut it)?;
    match stop {
        Stop::Eof => Ok(nodes),
        Stop::Else(span) => Err(unsupported(
            "unexpected `{{else}}` outside of a block",
            span,
        )),
        Stop::Close(kind, span) => Err(unsupported(
            format!("unexpected closing tag `{{/{}}}`", kind.tag()),
            span,
        )),
    }
}

fn collect(it: &mut std::vec::IntoIter<Token>) -> Result<(Vec<Node>, Stop), CompileError> {
    let mut nodes = Vec::new();
    loop {
        match it.next() {
            None => return Ok((nodes, Stop::Eof)),
            Some(Token::Text(text)) => nodes.push(Node::Text(text)),
            Some(Token::Expr { raw, escape, span }) => {
                nodes.push(Node::Emit {
                    expr: parse_expr(&raw, span)?,
                    escape,
                    span,
                });
            }
            Some(Token::Else(span)) => return Ok((nodes, Stop::Else(span))),
            Some(Token::Close { kind, span }) => return Ok((nodes, Stop::Close(kind, span))),
            Some(Token::Open { kind, args, span }) => {
                nodes.push(parse_block(it, kind, &args, span)?);
            }
        }
    }
}

fn parse_block(
    it: &mut std::vec::IntoIter<Token>,
    kind: Block,
    args: &str,
    span: Span,
) -> Result<Node, CompileError> {
    let (subject, params) = parse_block_head(kind, args, span)?;
    let (body, stop) = collect(it)?;

    let (body, otherwise) = match stop {
        Stop::Else(_) => {
            let (otherwise, after) = collect(it)?;
            match after {
                Stop::Close(k, _) if k == kind => (body, otherwise),
                Stop::Close(other, csp) => return Err(mismatched(kind, other, csp)),
                Stop::Else(esp) => {
                    return Err(unsupported(
                        format!("unexpected second `{{else}}` inside `{{#{}}}`", kind.tag()),
                        esp,
                    ))
                }
                Stop::Eof => return Err(unclosed(kind, span)),
            }
        }
        Stop::Close(k, _) if k == kind => (body, Vec::new()),
        Stop::Close(other, csp) => return Err(mismatched(kind, other, csp)),
        Stop::Eof => return Err(unclosed(kind, span)),
    };

    Ok(match kind {
        Block::If => Node::If {
            cond: subject,
            then: body,
            otherwise,
            span,
        },
        // `unless` is `if` with the branches swapped — the same lowering the BEAM uses.
        Block::Unless => Node::If {
            cond: subject,
            then: otherwise,
            otherwise: body,
            span,
        },
        Block::Each => Node::Each {
            subject,
            params,
            body,
            otherwise,
            span,
        },
        Block::With => Node::With {
            subject,
            params,
            body,
            otherwise,
            span,
        },
    })
}

fn parse_block_head(
    kind: Block,
    args: &str,
    span: Span,
) -> Result<(Expr, Vec<String>), CompileError> {
    match kind {
        Block::If | Block::Unless => Ok((parse_expr(args, span)?, Vec::new())),
        Block::Each | Block::With => {
            let (expr_src, params) = split_block_params(args);
            validate_params(kind, &params, span)?;
            Ok((parse_expr(&expr_src, span)?, params))
        }
    }
}

// Mirror `Stem.Parser.split_block_params/1`: an optional ` as |a b c|` suffix
// carries the block params; everything before it is the subject expression.
fn split_block_params(args: &str) -> (String, Vec<String>) {
    let trimmed = args.trim_end();
    if let Some(open_to_params) = trimmed.strip_suffix('|') {
        if let Some(bar) = open_to_params.rfind('|') {
            let params_src = &open_to_params[bar + 1..];
            let before = open_to_params[..bar].trim_end();
            if let Some(expr) = before.strip_suffix("as") {
                if expr.is_empty() || expr.ends_with(char::is_whitespace) {
                    let params = params_src.split_whitespace().map(String::from).collect();
                    return (expr.trim().to_string(), params);
                }
            }
        }
    }
    (args.trim().to_string(), Vec::new())
}

fn validate_params(kind: Block, params: &[String], span: Span) -> Result<(), CompileError> {
    match kind {
        Block::With if params.len() > 1 => Err(unsupported(
            "`{{#with}}` accepts at most one block parameter",
            span,
        )),
        Block::Each if params.len() > 3 => Err(unsupported(
            "`{{#each}}` accepts at most three block parameters",
            span,
        )),
        _ if params.iter().any(|p| !is_identifier(p)) => Err(unsupported(
            "block parameters must be simple identifiers",
            span,
        )),
        _ if has_duplicates(params) => Err(unsupported("block parameters must be unique", span)),
        _ => Ok(()),
    }
}

// ── Expression parsing ───────────────────────────────────────────────────────

enum Expr {
    Identifier(String),
    // A dotted path. `Implicit` carries `[root, rest..]`; `This` carries the
    // segments after `this.`.
    PathImplicit(Vec<String>),
    PathThis(Vec<String>),
    Index0,
    Index1,
    Key,
    This,
    Parent(String),
    Lit(Value),
    Transformer { name: String, args: Vec<Arg> },
    Pipeline { lhs: Box<Expr>, stages: Vec<Stage> },
}

// A transformer/pipeline-stage argument: positional or `key=value`.
enum Arg {
    Positional(Expr),
    Keyword(String, Expr),
}

struct Stage {
    name: String,
    args: Vec<Arg>,
}

fn parse_expr(raw: &str, span: Span) -> Result<Expr, CompileError> {
    let t = raw.trim();
    let segments = split_pipes(&scan_top_level(t));
    if segments.len() > 1 {
        let lhs = parse_expr(&segments[0], span)?;
        let stages = segments[1..]
            .iter()
            .map(|stage| parse_stage(stage, span))
            .collect::<Result<Vec<_>, _>>()?;
        return Ok(Expr::Pipeline {
            lhs: Box::new(lhs),
            stages,
        });
    }
    parse_structured(t, span)
}

// A single (non-pipeline) expression. Mirrors `Stem.Expression.structured_expression/1`:
// literal, special, parent, path, identifier, then a `name args..` transformer.
fn parse_structured(t: &str, span: Span) -> Result<Expr, CompileError> {
    if let Some(literal) = literal_kind(t) {
        return literal.into_expr(t, span);
    }
    match t {
        "@index" => Ok(Expr::Index0),
        "@index1" => Ok(Expr::Index1),
        "@key" => Ok(Expr::Key),
        "this" => Ok(Expr::This),
        _ if t.starts_with("../") => parse_parent(t, span),
        _ if is_path(t) => Ok(parse_path(t)),
        _ if is_identifier(t) => Ok(Expr::Identifier(t.to_string())),
        _ => parse_transformer(t, span),
    }
}

fn parse_parent(t: &str, span: Span) -> Result<Expr, CompileError> {
    let name = t.trim_start_matches("../");
    if is_identifier(name) {
        Ok(Expr::Parent(name.to_string()))
    } else {
        Err(not_supported(t, span))
    }
}

fn parse_path(t: &str) -> Expr {
    if let Some(rest) = t.strip_prefix("this.") {
        Expr::PathThis(rest.split('.').map(String::from).collect())
    } else {
        Expr::PathImplicit(t.split('.').map(String::from).collect())
    }
}

// `name arg arg..` with at least one argument and a helper-name head.
fn parse_transformer(t: &str, span: Span) -> Result<Expr, CompileError> {
    let parts = split_whitespace(&scan_top_level(t));
    match parts.split_first() {
        Some((name, args)) if !args.is_empty() && is_identifier(name) => {
            let args = args
                .iter()
                .map(|arg| parse_transformer_arg(arg, span))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Expr::Transformer {
                name: name.clone(),
                args,
            })
        }
        _ => Err(not_supported(t, span)),
    }
}

// Transformer arguments take `key=value` keywords; their values are structured
// expressions or parenthesised sub-calls (no bare transformer), matching
// `Stem.Expression.helper_argument_expression/1`.
fn parse_transformer_arg(arg: &str, span: Span) -> Result<Arg, CompileError> {
    if let Some((key, value)) = split_once(&scan_top_level(arg), Sep::Eq) {
        let key = key.trim();
        if !key.is_empty() {
            if !is_identifier(key) {
                return Err(not_supported(arg, span));
            }
            return Ok(Arg::Keyword(
                key.to_string(),
                parse_helper_value(value.trim(), span)?,
            ));
        }
    }
    Ok(Arg::Positional(parse_helper_value(arg.trim(), span)?))
}

fn parse_helper_value(t: &str, span: Span) -> Result<Expr, CompileError> {
    if is_wrapped_paren(t) {
        return parse_subexpression(t, span);
    }
    if let Some(literal) = literal_kind(t) {
        return literal.into_expr(t, span);
    }
    match t {
        "@index" => Ok(Expr::Index0),
        "@index1" => Ok(Expr::Index1),
        "@key" => Ok(Expr::Key),
        "this" => Ok(Expr::This),
        _ if t.starts_with("../") => parse_parent(t, span),
        _ if is_path(t) => Ok(parse_path(t)),
        _ if is_identifier(t) => Ok(Expr::Identifier(t.to_string())),
        _ => Err(not_supported(t, span)),
    }
}

// `(..)` sub-expressions must wrap a transformer or pipeline, like the BEAM.
fn parse_subexpression(t: &str, span: Span) -> Result<Expr, CompileError> {
    let inner = t.trim_start_matches('(').trim_end_matches(')');
    match parse_expr(inner.trim(), span)? {
        expr @ (Expr::Transformer { .. } | Expr::Pipeline { .. }) => Ok(expr),
        _ => Err(not_supported(t, span)),
    }
}

// A pipeline stage: a bare helper name, or `name(arg, arg..)`.
fn parse_stage(stage: &str, span: Span) -> Result<Stage, CompileError> {
    let t = stage.trim();
    if is_identifier(t) {
        return Ok(Stage {
            name: t.to_string(),
            args: Vec::new(),
        });
    }
    if let Some((name, args_src)) = stage_call_parts(t) {
        let mut args = Vec::new();
        for arg in split_commas(&scan_top_level(args_src)) {
            let arg = arg.trim();
            if !arg.is_empty() {
                args.push(parse_pipeline_arg(arg, span)?);
            }
        }
        return Ok(Stage { name, args });
    }
    Err(not_supported(t, span))
}

fn stage_call_parts(t: &str) -> Option<(String, &str)> {
    let open = t.find('(')?;
    let name = &t[..open];
    let rest = &t[open..];
    if is_identifier(name) && is_wrapped_paren(rest) {
        Some((name.to_string(), &rest[1..rest.len() - 1]))
    } else {
        None
    }
}

// Pipeline call arguments accept `key=value` or `key: value` keywords; their
// values are strict expressions (transformers/pipelines allowed).
fn parse_pipeline_arg(arg: &str, span: Span) -> Result<Arg, CompileError> {
    let tokens = scan_top_level(arg);
    if let Some((key, value)) =
        split_once(&tokens, Sep::Eq).or_else(|| split_once(&tokens, Sep::Colon))
    {
        let key = key.trim();
        if !key.is_empty() {
            if !is_identifier(key) {
                return Err(not_supported(arg, span));
            }
            return Ok(Arg::Keyword(
                key.to_string(),
                parse_expr(value.trim(), span)?,
            ));
        }
    }
    Ok(Arg::Positional(parse_expr(arg.trim(), span)?))
}

// ── Top-level tokenizer (mirrors Stem.Expression's splitter) ─────────────────
//
// Splits an expression at the top level only: parenthesised groups and quoted
// strings are absorbed into `Text` so the `|>`, whitespace, `,`, `=`, and `:`
// separators inside them never split an argument.

enum Tok {
    Pipe,
    Comma,
    Eq,
    Colon,
    Ws(char),
    Text(String),
}

impl Tok {
    fn value(&self) -> String {
        match self {
            Tok::Pipe => "|>".to_string(),
            Tok::Comma => ",".to_string(),
            Tok::Eq => "=".to_string(),
            Tok::Colon => ":".to_string(),
            Tok::Ws(c) => c.to_string(),
            Tok::Text(s) => s.clone(),
        }
    }
}

#[derive(Clone, Copy)]
enum Sep {
    Eq,
    Colon,
}

fn scan_top_level(s: &str) -> Vec<Tok> {
    let chars: Vec<char> = s.chars().collect();
    let mut out = Vec::new();
    let mut text = String::new();
    let mut k = 0;

    while k < chars.len() {
        let c = chars[k];
        match c {
            '"' | '\'' => consume_quoted(&chars, &mut k, &mut text),
            '(' => consume_parens(&chars, &mut k, &mut text),
            '|' if chars.get(k + 1) == Some(&'>') => {
                flush(&mut text, &mut out);
                out.push(Tok::Pipe);
                k += 2;
            }
            ',' => push_sep(Tok::Comma, &mut text, &mut out, &mut k),
            '=' => push_sep(Tok::Eq, &mut text, &mut out, &mut k),
            ':' => push_sep(Tok::Colon, &mut text, &mut out, &mut k),
            ' ' | '\t' | '\n' | '\r' => push_sep(Tok::Ws(c), &mut text, &mut out, &mut k),
            _ => {
                text.push(c);
                k += 1;
            }
        }
    }
    flush(&mut text, &mut out);
    out
}

fn flush(text: &mut String, out: &mut Vec<Tok>) {
    if !text.is_empty() {
        out.push(Tok::Text(std::mem::take(text)));
    }
}

fn push_sep(sep: Tok, text: &mut String, out: &mut Vec<Tok>, k: &mut usize) {
    flush(text, out);
    out.push(sep);
    *k += 1;
}

fn consume_quoted(chars: &[char], k: &mut usize, text: &mut String) {
    let quote = chars[*k];
    text.push(quote);
    *k += 1;
    while *k < chars.len() {
        let d = chars[*k];
        text.push(d);
        *k += 1;
        if d == '\\' {
            if *k < chars.len() {
                text.push(chars[*k]);
                *k += 1;
            }
        } else if d == quote {
            break;
        }
    }
}

fn consume_parens(chars: &[char], k: &mut usize, text: &mut String) {
    text.push('(');
    *k += 1;
    let mut depth = 1;
    while *k < chars.len() && depth > 0 {
        let d = chars[*k];
        match d {
            '(' => {
                depth += 1;
                text.push(d);
                *k += 1;
            }
            ')' => {
                depth -= 1;
                text.push(d);
                *k += 1;
            }
            '"' | '\'' => consume_quoted(chars, k, text),
            _ => {
                text.push(d);
                *k += 1;
            }
        }
    }
}

fn split_pipes(tokens: &[Tok]) -> Vec<String> {
    split_by(tokens, |t| matches!(t, Tok::Pipe))
}

fn split_commas(tokens: &[Tok]) -> Vec<String> {
    split_by(tokens, |t| matches!(t, Tok::Comma))
}

fn split_by(tokens: &[Tok], is_sep: impl Fn(&Tok) -> bool) -> Vec<String> {
    let mut groups = Vec::new();
    let mut current = String::new();
    for token in tokens {
        if is_sep(token) {
            groups.push(std::mem::take(&mut current));
        } else {
            current.push_str(&token.value());
        }
    }
    groups.push(current);
    groups
}

// Whitespace split that collapses runs and drops empties, like the BEAM.
fn split_whitespace(tokens: &[Tok]) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    for token in tokens {
        if matches!(token, Tok::Ws(_)) {
            if !current.is_empty() {
                out.push(std::mem::take(&mut current));
            }
        } else {
            current.push_str(&token.value());
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

fn split_once(tokens: &[Tok], sep: Sep) -> Option<(String, String)> {
    let idx = tokens
        .iter()
        .position(|t| matches!((t, sep), (Tok::Eq, Sep::Eq) | (Tok::Colon, Sep::Colon)))?;
    let left = tokens[..idx].iter().map(Tok::value).collect();
    let right = tokens[idx + 1..].iter().map(Tok::value).collect();
    Some((left, right))
}

// A whole-string balanced `(..)` group (quotes ignored — sub-calls with quoted
// parens are rare and fall back to a "not supported" error).
fn is_wrapped_paren(t: &str) -> bool {
    let chars: Vec<char> = t.chars().collect();
    if chars.first() != Some(&'(') || chars.last() != Some(&')') {
        return false;
    }
    let mut depth = 0i32;
    for (i, &c) in chars.iter().enumerate() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth < 0 || (depth == 0 && i != chars.len() - 1) {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0
}

// ── Literals ─────────────────────────────────────────────────────────────────

enum Literal {
    Value(Value),
    // Looks like a literal the BEAM accepts, but not yet ported (single-quoted
    // charlists, strings with escapes): reported as "not yet supported".
    Pending,
}

impl Literal {
    fn into_expr(self, source: &str, span: Span) -> Result<Expr, CompileError> {
        match self {
            Literal::Value(value) => Ok(Expr::Lit(value)),
            Literal::Pending => Err(not_supported(source, span)),
        }
    }
}

fn literal_kind(t: &str) -> Option<Literal> {
    match t {
        "true" => Some(Literal::Value(Value::Bool(true))),
        "false" => Some(Literal::Value(Value::Bool(false))),
        "nil" | "null" => Some(Literal::Value(Value::Null)),
        _ if t.starts_with('"') => Some(double_quoted_literal(t)),
        _ if t.starts_with('\'') => Some(Literal::Pending),
        _ if is_number(t) => Some(number_literal(t)),
        _ => None,
    }
}

fn double_quoted_literal(t: &str) -> Literal {
    if t.len() >= 2 && t.ends_with('"') {
        let content = &t[1..t.len() - 1];
        if content.contains('\\') || content.contains('"') {
            Literal::Pending
        } else {
            Literal::Value(Value::String(content.to_string()))
        }
    } else {
        Literal::Pending
    }
}

fn number_literal(t: &str) -> Literal {
    if t.contains('.') {
        t.parse::<f64>()
            .ok()
            .and_then(serde_json::Number::from_f64)
            .map(|n| Literal::Value(Value::Number(n)))
            .unwrap_or(Literal::Pending)
    } else {
        match t.parse::<i64>() {
            Ok(i) => Literal::Value(Value::Number(i.into())),
            Err(_) => Literal::Pending,
        }
    }
}

// `^-?\d+(\.\d+)?$`
fn is_number(t: &str) -> bool {
    let body = t.strip_prefix('-').unwrap_or(t);
    let mut parts = body.splitn(2, '.');
    let int = parts.next().unwrap_or("");
    let int_ok = !int.is_empty() && int.bytes().all(|b| b.is_ascii_digit());
    match parts.next() {
        None => int_ok,
        Some(frac) => int_ok && !frac.is_empty() && frac.bytes().all(|b| b.is_ascii_digit()),
    }
}

// ── Lowering (mirrors Stem.Bytecode.compile_value/2 with scope) ──────────────

#[derive(Clone)]
struct Scope {
    in_each: bool,
    has_this: bool,
    locals: HashSet<String>,
}

impl Scope {
    fn root() -> Self {
        Scope {
            in_each: false,
            has_this: false,
            locals: HashSet::new(),
        }
    }

    fn each_body(&self, params: &[String]) -> Self {
        Scope {
            in_each: true,
            has_this: true,
            locals: self.with_locals(params),
        }
    }

    fn with_body(&self, params: &[String]) -> Self {
        Scope {
            in_each: self.in_each,
            has_this: true,
            locals: self.with_locals(params),
        }
    }

    fn each_else(&self) -> Self {
        Scope {
            in_each: false,
            has_this: self.has_this,
            locals: self.locals.clone(),
        }
    }

    fn with_locals(&self, params: &[String]) -> HashSet<String> {
        let mut locals = self.locals.clone();
        locals.extend(params.iter().cloned());
        locals
    }
}

fn lower_nodes(nodes: &[Node], scope: &Scope) -> Result<Vec<Value>, CompileError> {
    nodes.iter().map(|node| lower_node(node, scope)).collect()
}

fn lower_node(node: &Node, scope: &Scope) -> Result<Value, CompileError> {
    match node {
        Node::Text(text) => Ok(json!({ "t": "text", "text": text })),
        Node::Emit { expr, escape, span } => {
            Ok(json!({ "t": "emit", "value": lower_value(expr, scope, *span)?, "escape": escape }))
        }
        Node::If {
            cond,
            then,
            otherwise,
            span,
        } => Ok(json!({
            "t": "if",
            "cond": lower_value(cond, scope, *span)?,
            "then": lower_nodes(then, scope)?,
            "else": lower_nodes(otherwise, scope)?,
        })),
        Node::Each {
            subject,
            params,
            body,
            otherwise,
            span,
        } => Ok(json!({
            "t": "each",
            "subject": lower_value(subject, scope, *span)?,
            "params": params,
            "body": lower_nodes(body, &scope.each_body(params))?,
            "else": lower_nodes(otherwise, &scope.each_else())?,
        })),
        Node::With {
            subject,
            params,
            body,
            otherwise,
            span,
        } => Ok(json!({
            "t": "with",
            "subject": lower_value(subject, scope, *span)?,
            "params": params,
            "body": lower_nodes(body, &scope.with_body(params))?,
            "else": lower_nodes(otherwise, scope)?,
        })),
    }
}

fn lower_value(expr: &Expr, scope: &Scope, span: Span) -> Result<Value, CompileError> {
    match expr {
        Expr::Identifier(name) => Ok(if scope.locals.contains(name) {
            local(name)
        } else if scope.in_each {
            get(this(), std::slice::from_ref(name))
        } else {
            assign(name)
        }),
        Expr::PathImplicit(segments) => {
            let root = &segments[0];
            let rest = &segments[1..];
            Ok(if scope.locals.contains(root) {
                get(local(root), rest)
            } else if scope.in_each {
                get(this(), segments)
            } else {
                get(assign(root), rest)
            })
        }
        Expr::PathThis(segments) => {
            if scope.has_this {
                Ok(get(this(), segments))
            } else {
                Err(unsupported(
                    "`this` paths are only valid inside a block helper",
                    span,
                ))
            }
        }
        Expr::Index0 if scope.in_each => Ok(json!({ "t": "index" })),
        Expr::Index0 => Ok(assign("index0")),
        Expr::Index1 if scope.in_each => Ok(json!({ "t": "index1" })),
        Expr::Index1 => Ok(assign("index1")),
        Expr::Key if scope.in_each => Ok(json!({ "t": "key" })),
        Expr::Key => Ok(assign("key")),
        Expr::This if scope.has_this => Ok(this()),
        Expr::This => Err(unsupported(
            "`this` is only bound inside a block helper",
            span,
        )),
        Expr::Parent(name) => Ok(assign(name)),
        Expr::Lit(value) => Ok(json!({ "t": "lit", "value": value })),
        Expr::Transformer { name, args } => lower_call(name, None, args, scope, span),
        Expr::Pipeline { lhs, stages } => {
            let mut acc = lower_value(lhs, scope, span)?;
            for stage in stages {
                acc = lower_call(&stage.name, Some(acc), &stage.args, scope, span)?;
            }
            Ok(acc)
        }
    }
}

// Lower a transformer/pipeline-stage call to a `call` op. `leading` is the
// piped-in accumulator (the stage's implicit first positional argument).
fn lower_call(
    name: &str,
    leading: Option<Value>,
    args: &[Arg],
    scope: &Scope,
    span: Span,
) -> Result<Value, CompileError> {
    let mut positional: Vec<Value> = leading.into_iter().collect();
    let mut kwargs = serde_json::Map::new();
    for arg in args {
        match arg {
            Arg::Positional(expr) => positional.push(lower_value(expr, scope, span)?),
            Arg::Keyword(key, expr) => {
                kwargs.insert(key.clone(), lower_value(expr, scope, span)?);
            }
        }
    }
    Ok(json!({ "t": "call", "name": name, "args": positional, "kwargs": kwargs }))
}

fn assign(name: &str) -> Value {
    json!({ "t": "assign", "name": name })
}

fn local(name: &str) -> Value {
    json!({ "t": "local", "name": name })
}

fn this() -> Value {
    json!({ "t": "this" })
}

fn get(base: Value, segments: &[String]) -> Value {
    json!({ "t": "get", "base": base, "segments": segments })
}

// ── Small grammar helpers (mirror Stem.Expression's regexes) ─────────────────

// `^[a-z_][a-zA-Z0-9_]*$`
fn is_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_lowercase() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

// A dotted path: `^[a-z_]\w*(\.\w+)+$`, or anything beginning `this.`.
fn is_path(t: &str) -> bool {
    if t.starts_with("this.") {
        return true;
    }
    let mut segments = t.split('.');
    let Some(root) = segments.next() else {
        return false;
    };
    if !is_identifier(root) {
        return false;
    }
    let rest: Vec<&str> = segments.collect();
    !rest.is_empty()
        && rest
            .iter()
            .all(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'))
}

fn split_first_word(s: &str) -> (&str, &str) {
    match s.find(char::is_whitespace) {
        Some(idx) => (&s[..idx], s[idx..].trim_start()),
        None => (s, ""),
    }
}

fn has_duplicates(params: &[String]) -> bool {
    let mut seen = HashSet::new();
    params.iter().any(|p| !seen.insert(p))
}

fn unsupported(message: impl Into<String>, span: Span) -> CompileError {
    CompileError {
        message: message.into(),
        start: span.0,
        end: span.1,
    }
}

fn not_supported(expr: &str, span: Span) -> CompileError {
    unsupported(
        format!("expression {expr:?} is not yet supported by the native compiler"),
        span,
    )
}

fn mismatched(open: Block, close: Block, span: Span) -> CompileError {
    unsupported(
        format!(
            "unexpected closing tag `{{/{}}}`; expected `{{/{}}}`",
            close.tag(),
            open.tag()
        ),
        span,
    )
}

fn unclosed(kind: Block, span: Span) -> CompileError {
    unsupported(format!("missing closing `{{/{}}}` tag", kind.tag()), span)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Compares against authoritative wire from `Stem.Bytecode.to_wire/1`, parsed
    // as Values so field order is irrelevant.
    fn assert_wire(source: &str, expected_json: &str) {
        let got = compile_to_wire(source).expect("should compile");
        let want: Value = serde_json::from_str(expected_json).expect("valid expected JSON");
        assert_eq!(got, want, "for {source:?}");
    }

    #[test]
    fn plain_text_and_paths() {
        assert_wire(
            "Hi {{user.name}}!",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"Hi "},{"escape":"html","t":"emit","value":{"base":{"name":"user","t":"assign"},"segments":["name"],"t":"get"}},{"t":"text","text":"!"}]}"#,
        );
        assert_wire(
            "{{{raw}}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"none","t":"emit","value":{"name":"raw","t":"assign"}}]}"#,
        );
    }

    #[test]
    fn if_else() {
        assert_wire(
            "{{#if active}}on{{else}}off{{/if}}",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"if","cond":{"name":"active","t":"assign"},"then":[{"t":"text","text":"on"}],"else":[{"t":"text","text":"off"}]}]}"#,
        );
    }

    #[test]
    fn unless_swaps_branches() {
        assert_wire(
            "{{#unless active}}off{{/unless}}",
            r#"{"version":"stem-bc/v1","instructions":[{"cond":{"name":"active","t":"assign"},"else":[{"t":"text","text":"off"}],"t":"if","then":[]}]}"#,
        );
    }

    #[test]
    fn each_this_and_else() {
        assert_wire(
            "{{#each items}}{{this}};{{/each}}",
            r#"{"version":"stem-bc/v1","instructions":[{"body":[{"escape":"html","t":"emit","value":{"t":"this"}},{"t":"text","text":";"}],"else":[],"params":[],"subject":{"name":"items","t":"assign"},"t":"each"}]}"#,
        );
        assert_wire(
            "{{#each items}}x{{else}}none{{/each}}",
            r#"{"version":"stem-bc/v1","instructions":[{"body":[{"t":"text","text":"x"}],"else":[{"t":"text","text":"none"}],"params":[],"subject":{"name":"items","t":"assign"},"t":"each"}]}"#,
        );
    }

    #[test]
    fn each_block_params_are_locals() {
        assert_wire(
            "{{#each items as |item idx|}}{{idx}}:{{item}} {{/each}}",
            r#"{"version":"stem-bc/v1","instructions":[{"body":[{"escape":"html","t":"emit","value":{"name":"idx","t":"local"}},{"t":"text","text":":"},{"escape":"html","t":"emit","value":{"name":"item","t":"local"}},{"t":"text","text":" "}],"else":[],"params":["item","idx"],"subject":{"name":"items","t":"assign"},"t":"each"}]}"#,
        );
    }

    #[test]
    fn each_index1_and_this_path() {
        assert_wire(
            "{{#each rows}}{{@index1}}. {{this.name}}{{/each}}",
            r#"{"version":"stem-bc/v1","instructions":[{"body":[{"escape":"html","t":"emit","value":{"t":"index1"}},{"t":"text","text":". "},{"escape":"html","t":"emit","value":{"base":{"t":"this"},"segments":["name"],"t":"get"}}],"else":[],"params":[],"subject":{"name":"rows","t":"assign"},"t":"each"}]}"#,
        );
    }

    #[test]
    fn with_block_param() {
        assert_wire(
            "{{#with user as |u|}}{{u.name}}{{/with}}",
            r#"{"version":"stem-bc/v1","instructions":[{"body":[{"escape":"html","t":"emit","value":{"base":{"name":"u","t":"local"},"segments":["name"],"t":"get"}}],"else":[],"params":["u"],"subject":{"name":"user","t":"assign"},"t":"with"}]}"#,
        );
    }

    #[test]
    fn parent_reference_is_a_top_level_assign() {
        assert_wire(
            "{{#each items}}{{../title}}: {{this}}{{/each}}",
            r#"{"version":"stem-bc/v1","instructions":[{"body":[{"escape":"html","t":"emit","value":{"name":"title","t":"assign"}},{"t":"text","text":": "},{"escape":"html","t":"emit","value":{"t":"this"}}],"else":[],"params":[],"subject":{"name":"items","t":"assign"},"t":"each"}]}"#,
        );
    }

    #[test]
    fn top_level_specials_resolve_to_assigns() {
        assert_wire(
            "{{@index}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"name":"index0","t":"assign"}}]}"#,
        );
    }

    #[test]
    fn pipelines_lower_to_nested_calls() {
        assert_wire(
            "{{name |> upcase}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"name":"name","t":"assign"}],"kwargs":{},"name":"upcase","t":"call"}}]}"#,
        );
        assert_wire(
            "{{name |> upcase |> trim}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"args":[{"name":"name","t":"assign"}],"kwargs":{},"name":"upcase","t":"call"}],"kwargs":{},"name":"trim","t":"call"}}]}"#,
        );
        assert_wire(
            "{{text |> truncate(20)}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"name":"text","t":"assign"},{"t":"lit","value":20}],"kwargs":{},"name":"truncate","t":"call"}}]}"#,
        );
    }

    #[test]
    fn transformers_with_positional_and_keyword_args() {
        assert_wire(
            r#"{{default user.name "anon"}}"#,
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"base":{"name":"user","t":"assign"},"segments":["name"],"t":"get"},{"t":"lit","value":"anon"}],"kwargs":{},"name":"default","t":"call"}}]}"#,
        );
        assert_wire(
            "{{link url text=label}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"name":"url","t":"assign"}],"kwargs":{"text":{"name":"label","t":"assign"}},"name":"link","t":"call"}}]}"#,
        );
    }

    #[test]
    fn parenthesised_subexpression_argument() {
        assert_wire(
            r#"{{default (upcase name) "X"}}"#,
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"args":[{"name":"name","t":"assign"}],"kwargs":{},"name":"upcase","t":"call"},{"t":"lit","value":"X"}],"kwargs":{},"name":"default","t":"call"}}]}"#,
        );
    }

    #[test]
    fn integer_and_string_literals() {
        assert_wire(
            "{{truncate text 20}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"name":"text","t":"assign"},{"t":"lit","value":20}],"kwargs":{},"name":"truncate","t":"call"}}]}"#,
        );
    }

    #[test]
    fn unported_constructs_report_a_span() {
        for src in [
            "{{'single'}}",
            "{{> nav}}",
            "{{!c}}",
            "{{~ x ~}}",
            "{{a + b}}",
        ] {
            let err = compile_to_wire(src).unwrap_err();
            assert!(
                err.message.contains("not yet supported"),
                "for {src:?}: {}",
                err.message
            );
            assert!(err.end > err.start, "for {src:?}");
        }
    }

    #[test]
    fn structural_errors_report_a_span() {
        assert!(compile_to_wire("{{#each x}}y")
            .unwrap_err()
            .message
            .contains("missing closing"));
        assert!(compile_to_wire("{{#if a}}x{{/each}}")
            .unwrap_err()
            .message
            .contains("expected"));
        assert!(compile_to_wire("done{{/if}}")
            .unwrap_err()
            .message
            .contains("unexpected closing"));
        assert_eq!(compile_to_wire("Hi {{name").unwrap_err().start, 3);
    }
}
