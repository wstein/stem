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
//     same local/`this`/assign scope resolution the BEAM uses.
//
// Not yet ported (raise a spanned `CompileError`, so the playground shows "not
// yet supported" rather than miscompiling): transformers and pipelines,
// literals, partials, regions/yields, comments, and whitespace-control markers.

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
}

fn parse_expr(raw: &str, span: Span) -> Result<Expr, CompileError> {
    let t = raw.trim();
    match t {
        "@index" => Ok(Expr::Index0),
        "@index1" => Ok(Expr::Index1),
        "@key" => Ok(Expr::Key),
        "this" => Ok(Expr::This),
        _ if t.starts_with("../") => {
            let name = t.trim_start_matches("../");
            if is_identifier(name) {
                Ok(Expr::Parent(name.to_string()))
            } else {
                Err(not_supported(t, span))
            }
        }
        _ if is_path(t) => Ok(parse_path(t)),
        _ if is_identifier(t) => Ok(Expr::Identifier(t.to_string())),
        // Literals, transformers, pipelines, and arbitrary expressions: valid on
        // the BEAM but not yet ported here.
        _ => Err(not_supported(t, span)),
    }
}

fn parse_path(t: &str) -> Expr {
    if let Some(rest) = t.strip_prefix("this.") {
        Expr::PathThis(rest.split('.').map(String::from).collect())
    } else {
        Expr::PathImplicit(t.split('.').map(String::from).collect())
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
    }
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
    fn unported_constructs_report_a_span() {
        for src in [
            "{{name |> upcase}}",
            "{{default x y}}",
            "{{> nav}}",
            "{{!c}}",
            r#"{{"lit"}}"#,
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
