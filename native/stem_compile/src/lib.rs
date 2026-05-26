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
//   * `{{#region}}` definitions with `{{yield}}` inlining (recursion-guarded);
//   * expressions: identifiers, dotted paths (with numeric `[n]` list indices),
//     the contextual references `@this`/`@parent`/`@root` (with paths), and the
//     iteration variables `@index`/`@index1`/`@key`/`@first`/`@last`, with the
//     same local/context/assign scope resolution the BEAM uses;
//   * literal variable keys: bracketed segments (`[first-name]`, `[a.b]`) and
//     uppercase block params (`as |Item|`), so keys/params that are not valid
//     identifiers resolve by name, mirroring `Stem.Expression`;
//   * transformer calls and `|` pipelines, with positional and `key=value` /
//     `key: value` keyword args and parenthesised sub-expressions;
//   * literals: integers, `true`/`false`, `null`/`nil`, and simple double- and
//     single-quoted strings;
//   * `{{! .. }}` / `{{!-- .. --}}` comments and `{{~ .. ~}}` trim markers.
//   * `{{> name}}` partials, expanded inline from a caller-supplied
//     name->source map with the same recursion guard as `Stem.Parser`;
//     partial arguments `{{> name ctx key=value}}` lower to a `scope`
//     instruction that rebinds the assigns to the context (or inherited data
//     context) merged with the hash, mirroring `Stem.Bytecode`.
//
// Not yet ported (raise a spanned `CompileError`, so the playground shows "not
// yet supported" rather than miscompiling): escaped/interpolated strings, and
// `{{& .. }}` tags.

use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

// Combinator lexer (nimble_parsec_rs port of `Stem.Parser.do_lex`), phase one of
// migrating the hand-written `tokenize` onto shared combinators with the BEAM.
mod np_lexer;

const VERSION: &str = "stem-bc/v1";

// The pre-expansion AST wire shape emitted by `parse_ast_to_wire` (distinct from
// the lowered `stem-bc/v1` bytecode). It keeps source structure — `{{> name}}`
// stays a `partial` node, every node carries its byte `src` span — so the
// playground can draw the partial dependency graph and the per-file AST viewer.
const AST_VERSION: &str = "stem-ast/v1";

// A partial-source map (name -> template source), mirroring the `:partials`
// option on `Stem.Parser`. Partials are expanded inline at parse time.
pub type Partials = HashMap<String, String>;

// Carries the partial map and the recursion guard (the stack of partial names
// currently being expanded) through recursive assembly.
struct Asm<'a> {
    partials: &'a Partials,
    stack: Vec<String>,
    // When false (the `parse_ast` path), `{{> name}}` tags are kept as `Partial`
    // nodes instead of being expanded inline, so a single file's pre-expansion
    // structure (and its partial dependency edges) stays visible.
    expand: bool,
}

// A parse/compile failure carrying a byte span into the source, so the editor
// can underline the offending tag (Phase C surfaces this to JS).
#[derive(Debug, PartialEq)]
pub struct CompileError {
    pub message: String,
    pub start: usize,
    pub end: usize,
}

impl std::fmt::Display for CompileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} (bytes {}..{})", self.message, self.start, self.end)
    }
}

impl std::error::Error for CompileError {}

// Compiles template source to the wire program `{"version", "instructions"}`,
// expanding any `{{> name}}` partials from the given map.
pub fn compile_to_wire(source: &str, partials: &Partials) -> Result<Value, CompileError> {
    compile_inner(source, partials, false)
}

/// Compiles template source to its wire bytecode as a JSON string — the
/// build-time entry a compile-time macro embeds, later reconstructed by the
/// engine's `Program::from_wire`.
pub fn compile_to_wire_string(source: &str) -> Result<String, CompileError> {
    let wire = compile_to_wire(source, &Partials::new())?;
    Ok(serde_json::to_string(&wire).expect("wire program serializes"))
}

/// Parses one template's source to its pre-expansion AST (`stem-ast/v1`),
/// `{"version", "nodes"}`. Unlike `compile_to_wire`, `{{> name}}` tags are kept
/// as `partial` nodes rather than inlined, so a file's own structure and its
/// partial dependency edges stay visible; every node carries its byte `src`
/// span for bidirectional editor highlighting. Mirrors `Stem.parse_ast/1`.
pub fn parse_ast_to_wire(source: &str) -> Result<Value, CompileError> {
    let tokens = tokenize(source)?;
    let empty = Partials::new();
    let mut asm = Asm {
        partials: &empty,
        stack: Vec::new(),
        expand: false,
    };
    let nodes = assemble(tokens, &mut asm)?;
    Ok(json!({ "version": AST_VERSION, "nodes": ast_nodes_to_json(&nodes) }))
}

// Same as `compile_to_wire`, but annotates each `text`/`emit` instruction with
// a `src` provenance object (`{file, start, end}`) so a render-time segment map
// can attribute output back to the originating template/partial. This produces a
// superset wire program; the plain `compile_to_wire` output stays byte-identical
// to the BEAM reference (the cross-backend parity gate uses that path).
pub fn compile_to_wire_with_spans(
    source: &str,
    partials: &Partials,
) -> Result<Value, CompileError> {
    compile_inner(source, partials, true)
}

fn compile_inner(
    source: &str,
    partials: &Partials,
    with_spans: bool,
) -> Result<Value, CompileError> {
    let tokens = tokenize(source)?;
    let mut asm = Asm {
        partials,
        stack: Vec::new(),
        expand: true,
    };
    let nodes = assemble(tokens, &mut asm)?;
    let instructions = lower_nodes(&nodes, &Scope::root(), &Regions::new(), &[], with_spans)?;
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
    Region,
}

impl Block {
    fn parse(word: &str) -> Option<Self> {
        match word {
            "if" => Some(Block::If),
            "unless" => Some(Block::Unless),
            "each" => Some(Block::Each),
            "with" => Some(Block::With),
            "region" => Some(Block::Region),
            _ => None,
        }
    }

    fn tag(self) -> &'static str {
        match self {
            Block::If => "if",
            Block::Unless => "unless",
            Block::Each => "each",
            Block::With => "with",
            Block::Region => "region",
        }
    }
}

enum Token {
    Text {
        text: String,
        // Byte span of the raw text run in the source being tokenized (relative
        // to the current file). Used only for the span-annotated source map.
        span: Span,
    },
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
    Yield {
        name: String,
        span: Span,
    },
    Partial {
        name: String,
        args: String,
        span: Span,
    },
}

fn tokenize(src: &str) -> Result<Vec<Token>, CompileError> {
    let mut tokens = Vec::new();
    let mut text = String::new();
    let mut text_start = 0; // byte offset where the pending text run began
    let mut trim_next = false;
    let mut i = 0;

    while i < src.len() {
        let Some(rel) = src[i..].find("{{") else {
            if text.is_empty() {
                text_start = i;
            }
            text.push_str(&src[i..]);
            break;
        };
        if text.is_empty() {
            text_start = i;
        }
        text.push_str(&src[i..i + rel]);
        let start = i + rel;

        // Backslash escaping: N trailing backslashes before {{.
        // Consume exactly one: N=1 → escape (literal {{inner}}); N≥2 → emit N-1 and evaluate.
        let n = text
            .as_bytes()
            .iter()
            .rev()
            .take_while(|&&b| b == b'\\')
            .count();
        if n > 0 {
            text.truncate(text.len() - 1);
            if n == 1 {
                text.push_str("{{");
                i = start + 2;
                continue;
            }
            // N≥2: one backslash consumed, N-1 remain; fall through to evaluate.
        }

        // 4-brace raw block: {{{{#name}}}}...{{{{/name}}}} — content emitted verbatim.
        if src[start..].starts_with("{{{{#") {
            let name_start = start + 5; // skip "{{{{#"
            let close_brace = src[name_start..].find("}}}}").ok_or_else(|| CompileError {
                message: "unterminated raw block open tag".to_string(),
                start,
                end: src.len(),
            })?;
            let name = &src[name_start..name_start + close_brace];
            if name.is_empty() {
                return Err(CompileError {
                    message: "raw block name is required in `{{{{#}}}}`".to_string(),
                    start,
                    end: name_start + close_brace + 4,
                });
            }
            let content_start = name_start + close_brace + 4; // skip "}}}}"
            let mut close_tag = String::from("{{{{/");
            close_tag.push_str(name);
            close_tag.push_str("}}}}");
            let content_len = src[content_start..]
                .find(close_tag.as_str())
                .ok_or_else(|| CompileError {
                    message: format!(
                        "unclosed raw block `{{{{{{{{#{name}}}}}}}}}` — missing `{close_tag}`"
                    ),
                    start,
                    end: src.len(),
                })?;
            let raw_text = &src[content_start..content_start + content_len];
            text.push_str(raw_text);
            i = content_start + content_len + close_tag.len();
            continue;
        }
        if src[start..].starts_with("{{{{") {
            return Err(CompileError {
                message: "raw blocks use `{{{{#name}}}}` syntax".to_string(),
                start,
                end: src[start..]
                    .find("}}}}")
                    .map_or(src.len(), |r| start + r + 4),
            });
        }

        // Comments (`{{! .. }}`, `{{!-- .. --}}`) are dropped without flushing
        // the text buffer, so surrounding text merges and a pending trim marker
        // carries across them, exactly like the BEAM tokenizer.
        if let Some(end) = comment_end(src, start) {
            i = end;
            continue;
        }

        let triple = src[start..].starts_with("{{{");
        let (open, close) = if triple { ("{{{", "}}}") } else { ("{{", "}}") };
        let inner_start = start + open.len();
        let rel2 = src[inner_start..].find(close).ok_or_else(|| CompileError {
            message: format!("unterminated `{open}` tag"),
            start,
            end: src.len(),
        })?;
        let inner = &src[inner_start..inner_start + rel2];
        let tag_end = inner_start + rel2 + close.len();
        let (inner2, trim_left, trim_right) = extract_trim(inner);

        flush_text(&mut tokens, &mut text, &mut trim_next, (text_start, start));
        if trim_left {
            trim_trailing_text(&mut tokens);
        }
        if let Some(token) = classify(&inner2, triple, (start, tag_end))? {
            tokens.push(token);
        }
        trim_next = trim_right;
        i = tag_end;
    }

    flush_text(
        &mut tokens,
        &mut text,
        &mut trim_next,
        (text_start, src.len()),
    );
    Ok(tokens)
}

// The byte offset just past a comment starting at `start`, or `None` if no
// comment opens there.
fn comment_end(src: &str, start: usize) -> Option<usize> {
    if let Some(rest) = src[start..].strip_prefix("{{!--") {
        rest.find("--}}").map(|rel| start + 5 + rel + 4)
    } else if let Some(rest) = src[start..].strip_prefix("{{!") {
        rest.find("}}").map(|rel| start + 3 + rel + 2)
    } else {
        None
    }
}

// Strip surrounding `~` whitespace-control markers, returning the normalised
// inner text and whether each side requested a trim.
fn extract_trim(inner: &str) -> (String, bool, bool) {
    let trimmed = inner.trim();
    let trim_left = trimmed.starts_with('~');
    let trim_right = trimmed.ends_with('~');
    let mut s = trimmed;
    if trim_left && !s.is_empty() {
        s = &s[1..];
    }
    if trim_right && !s.is_empty() {
        s = &s[..s.len() - 1];
    }
    (s.trim().to_string(), trim_left, trim_right)
}

// Flush the pending text buffer as a `Text` token. A pending right-trim strips
// the buffer's leading whitespace first. The span covers the raw source run
// (whitespace control may shorten the content but not the recorded span).
fn flush_text(tokens: &mut Vec<Token>, text: &mut String, trim_next: &mut bool, span: Span) {
    let mut content = std::mem::take(text);
    if *trim_next {
        content = content.trim_start().to_string();
        *trim_next = false;
    }
    if !content.is_empty() {
        tokens.push(Token::Text {
            text: content,
            span,
        });
    }
}

// A left-trim marker strips trailing whitespace from the immediately preceding
// text token, dropping it if it becomes empty.
fn trim_trailing_text(tokens: &mut Vec<Token>) {
    if let Some(Token::Text { text, .. }) = tokens.last_mut() {
        let trimmed = text.trim_end().to_string();
        if trimmed.is_empty() {
            tokens.pop();
        } else {
            *text = trimmed;
        }
    }
}

// Classify a tag's normalised inner text into a token, or `None` to skip an
// empty tag (`{{}}`).
fn classify(inner2: &str, triple: bool, span: Span) -> Result<Option<Token>, CompileError> {
    if inner2.is_empty() {
        return Ok(None);
    }
    if inner2.contains('{') || inner2.contains('}') {
        return Err(unsupported(
            "nested braces are not supported in Stem expressions",
            span,
        ));
    }
    if triple {
        return Ok(Some(Token::Expr {
            raw: inner2.to_string(),
            escape: "none",
            span,
        }));
    }
    if inner2 == "else" {
        return Ok(Some(Token::Else(span)));
    }
    if first_word(inner2) == "yield" {
        let (_, name) = split_first_word(inner2);
        return Ok(Some(Token::Yield {
            name: name.trim().to_string(),
            span,
        }));
    }

    match inner2.chars().next().unwrap() {
        '#' => {
            let (word, args) = split_first_word(inner2[1..].trim_start());
            let kind = Block::parse(word).ok_or_else(|| {
                unsupported(
                    format!("block `{{#{word}}}` is not yet supported by the native compiler"),
                    span,
                )
            })?;
            Ok(Some(Token::Open {
                kind,
                args: args.to_string(),
                span,
            }))
        }
        '/' => {
            let word = inner2[1..].trim();
            let kind = Block::parse(word)
                .ok_or_else(|| unsupported(format!("unknown closing tag `{{/{word}}}`"), span))?;
            Ok(Some(Token::Close { kind, span }))
        }
        '>' => {
            let rest = inner2[1..].trim();
            let (name, args) = match rest.split_once(char::is_whitespace) {
                Some((name, args)) => (name.to_string(), args.trim().to_string()),
                None => (rest.to_string(), String::new()),
            };
            Ok(Some(Token::Partial { name, args, span }))
        }
        '&' => Err(unsupported(
            "`{{&}}` tags are not yet supported by the native compiler",
            span,
        )),
        _ => Ok(Some(Token::Expr {
            raw: inner2.to_string(),
            escape: "html",
            span,
        })),
    }
}

fn first_word(s: &str) -> &str {
    s.split_whitespace().next().unwrap_or("")
}

// ── Recursive-descent assembly ───────────────────────────────────────────────

enum Stop {
    Eof,
    Else(Span),
    Close(Block, Span),
}

enum Node {
    Text {
        text: String,
        // The template/partial the text came from ("main" for the entry) and the
        // raw byte span in that file, used only for span-annotated programs.
        file: String,
        span: Span,
    },
    Emit {
        expr: Expr,
        escape: &'static str,
        span: Span,
        // The template/partial the expression came from ("main" for the entry).
        file: String,
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
    // A named region definition; extracted during lowering (produces no output)
    // and inlined at matching `Yield` sites.
    Region {
        name: String,
        body: Vec<Node>,
    },
    Yield {
        name: String,
        span: Span,
    },
    // A partial invoked with arguments. The body is the expanded partial; the
    // context/hash establish a fresh scope at render time. Partials without
    // arguments expand inline and never produce this node.
    PartialScope {
        context: Option<Expr>,
        hash: Vec<(String, Expr)>,
        body: Vec<Node>,
        span: Span,
    },
    // An unexpanded `{{> name args}}` reference, produced only on the
    // `parse_ast` path (`Asm::expand == false`). Never reaches lowering.
    Partial {
        name: String,
        context: Option<Expr>,
        hash: Vec<(String, Expr)>,
        span: Span,
    },
}

fn assemble(tokens: Vec<Token>, asm: &mut Asm) -> Result<Vec<Node>, CompileError> {
    let mut it = tokens.into_iter();
    let (nodes, stop) = collect(&mut it, asm)?;
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

// The file currently being assembled: the entry is "main"; while a partial is
// expanded its name sits on top of the recursion-guard stack.
fn current_file(asm: &Asm) -> String {
    asm.stack
        .last()
        .cloned()
        .unwrap_or_else(|| "main".to_string())
}

fn collect(
    it: &mut std::vec::IntoIter<Token>,
    asm: &mut Asm,
) -> Result<(Vec<Node>, Stop), CompileError> {
    let mut nodes = Vec::new();
    loop {
        match it.next() {
            None => return Ok((nodes, Stop::Eof)),
            Some(Token::Text { text, span }) => nodes.push(Node::Text {
                text,
                file: current_file(asm),
                span,
            }),
            Some(Token::Expr { raw, escape, span }) => {
                nodes.push(Node::Emit {
                    expr: parse_expr(&raw, span)?,
                    escape,
                    span,
                    file: current_file(asm),
                });
            }
            Some(Token::Else(span)) => return Ok((nodes, Stop::Else(span))),
            Some(Token::Close { kind, span }) => return Ok((nodes, Stop::Close(kind, span))),
            Some(Token::Open { kind, args, span }) => {
                nodes.push(parse_block(it, kind, &args, span, asm)?);
            }
            Some(Token::Yield { name, span }) => nodes.push(Node::Yield { name, span }),
            Some(Token::Partial { name, args, span }) => {
                if asm.expand {
                    expand_partial(&name, &args, span, asm, &mut nodes)?
                } else {
                    let (context, hash) = parse_partial_args(&args, span)?;
                    nodes.push(Node::Partial {
                        name: name.trim().to_string(),
                        context,
                        hash,
                        span,
                    });
                }
            }
        }
    }
}

// Expand `{{> name args}}` inline by parsing the partial's source and splicing
// its nodes, mirroring `Stem.Parser.expand_partial/5` including the recursion
// guard. Without arguments the nodes splice directly (inheriting the caller's
// scope); with arguments they are wrapped in a `PartialScope` node so the
// context/hash establish a fresh scope at render time.
fn expand_partial(
    name: &str,
    args: &str,
    span: Span,
    asm: &mut Asm,
    out: &mut Vec<Node>,
) -> Result<(), CompileError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(unsupported("partial name is required in `{{> ...}}`", span));
    }
    if asm.stack.iter().any(|n| n == name) {
        return Err(unsupported(
            format!("partial recursion detected for '{name}'"),
            span,
        ));
    }
    match asm.partials.get(name).cloned() {
        Some(source) => {
            let (context, hash) = parse_partial_args(args, span)?;
            let tokens = tokenize(&source)?;
            asm.stack.push(name.to_string());
            let nodes = assemble(tokens, asm)?;
            asm.stack.pop();

            if context.is_none() && hash.is_empty() {
                out.extend(nodes);
            } else {
                out.push(Node::PartialScope {
                    context,
                    hash,
                    body: nodes,
                    span,
                });
            }
            Ok(())
        }
        None => Err(unsupported(format!("unknown partial '{name}'"), span)),
    }
}

// Parse a partial's argument string into an optional context expression and the
// ordered `key=value` hash pairs, mirroring `Stem.Expression.parse_partial_args/1`.
// The first positional token is the context; a second positional is an error.
fn parse_partial_args(args: &str, span: Span) -> Result<PartialArgs, CompileError> {
    let trimmed = args.trim();
    if trimmed.is_empty() {
        return Ok((None, Vec::new()));
    }

    let mut context: Option<Expr> = None;
    let mut hash: Vec<(String, Expr)> = Vec::new();

    for token in split_whitespace(&scan_top_level(trimmed)) {
        match parse_transformer_arg(&token, span)? {
            Arg::Keyword(key, value) => hash.push((key, value)),
            Arg::Positional(expr) if context.is_none() => context = Some(expr),
            Arg::Positional(_) => {
                return Err(unsupported(
                    "partials accept at most one context argument before key=value pairs",
                    span,
                ))
            }
        }
    }

    Ok((context, hash))
}

fn parse_block(
    it: &mut std::vec::IntoIter<Token>,
    kind: Block,
    args: &str,
    span: Span,
    asm: &mut Asm,
) -> Result<Node, CompileError> {
    if kind == Block::Region {
        return parse_region(it, args, span, asm);
    }

    let (subject, params) = parse_block_head(kind, args, span)?;
    let (body, stop) = collect(it, asm)?;

    let (body, otherwise) = match stop {
        Stop::Else(_) => {
            let (otherwise, after) = collect(it, asm)?;
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
        Block::Region => unreachable!("region handled above"),
    })
}

// `{{#region name}}..{{/region}}` defines a named, inlinable fragment. It takes
// a bare name (no expression, no params) and cannot have an `{{else}}`.
fn parse_region(
    it: &mut std::vec::IntoIter<Token>,
    args: &str,
    span: Span,
    asm: &mut Asm,
) -> Result<Node, CompileError> {
    let name = args.trim();
    if name.is_empty() || name.split_whitespace().count() != 1 {
        return Err(unsupported("`{{#region}}` requires a single name", span));
    }

    let (body, stop) = collect(it, asm)?;
    match stop {
        Stop::Close(Block::Region, _) => Ok(Node::Region {
            name: name.to_string(),
            body,
        }),
        Stop::Else(esp) => Err(unsupported(
            "`{{else}}` is not valid inside `{{#region}}`",
            esp,
        )),
        Stop::Close(other, csp) => Err(mismatched(Block::Region, other, csp)),
        Stop::Eof => Err(unclosed(Block::Region, span)),
    }
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
        Block::Region => unreachable!("region handled in parse_block"),
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
        _ if params.iter().any(|p| !is_binding_name(p)) => Err(unsupported(
            "block parameters must be simple identifiers",
            span,
        )),
        _ if has_duplicates(&named_params(params)) => {
            Err(unsupported("block parameters must be unique", span))
        }
        _ => Ok(()),
    }
}

// `_` is the anonymous/wildcard param: it may repeat to skip a positional slot,
// so it is excluded from the uniqueness check.
fn named_params(params: &[String]) -> Vec<String> {
    params
        .iter()
        .filter(|p| p.as_str() != "_")
        .cloned()
        .collect()
}

// ── Expression parsing ───────────────────────────────────────────────────────

enum Expr {
    Identifier(String),
    // A dotted implicit path: `[root, rest..]`.
    PathImplicit(Vec<String>),
    // A contextual reference (`@this`/`@parent`/`@root`) plus an optional path.
    Context(CtxKind, Vec<String>),
    Index0,
    Index1,
    Key,
    First,
    Last,
    Lit(Value),
    Transformer { name: String, args: Vec<Arg> },
    Pipeline { lhs: Box<Expr>, stages: Vec<Stage> },
}

#[derive(Clone, Copy)]
enum CtxKind {
    This,
    Parent,
    Root,
}

// A transformer/pipeline-stage argument: positional or `key=value`.
enum Arg {
    Positional(Expr),
    Keyword(String, Expr),
}

// A partial's parsed arguments: an optional context expression and the ordered
// `key=value` hash pairs.
type PartialArgs = (Option<Expr>, Vec<(String, Expr)>);

struct Stage {
    name: String,
    args: Vec<Arg>,
}

fn parse_expr(raw: &str, span: Span) -> Result<Expr, CompileError> {
    let t = raw.trim();
    let tokens = scan_top_level(t);
    if let Some(op) = reserved_op(&tokens) {
        return Err(unsupported(
            format!("the '{op}' operator is not supported"),
            span,
        ));
    }
    let segments = split_pipes(&tokens);
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
    if let Some(special) = iteration_special(t) {
        return Ok(special);
    }
    match context_path(t) {
        Some(Ok(expr)) => return Ok(expr),
        Some(Err(())) => return Err(not_supported(t, span)),
        None => {}
    }
    match parse_reference(t) {
        Some(expr) => Ok(expr),
        None => parse_transformer(t, span),
    }
}

// The iteration-only data variables; `None` otherwise. Their use outside an
// `#each` is rejected during lowering, not parsing.
fn iteration_special(t: &str) -> Option<Expr> {
    match t {
        "@index" => Some(Expr::Index0),
        "@index1" => Some(Expr::Index1),
        "@key" => Some(Expr::Key),
        "@first" => Some(Expr::First),
        "@last" => Some(Expr::Last),
        _ => None,
    }
}

// `@this`/`@parent`/`@root` plus an optional dotted path. `Some(Ok(..))` on a
// context reference, `Some(Err(()))` when the context word is followed by a
// malformed path, `None` when not a context reference at all.
fn context_path(t: &str) -> Option<Result<Expr, ()>> {
    let (kind, rest) = if let Some(rest) = t.strip_prefix("@this") {
        (CtxKind::This, rest)
    } else if let Some(rest) = t.strip_prefix("@parent") {
        (CtxKind::Parent, rest)
    } else if let Some(rest) = t.strip_prefix("@root") {
        (CtxKind::Root, rest)
    } else {
        return None;
    };

    if rest.is_empty() {
        return Some(Ok(Expr::Context(kind, Vec::new())));
    }

    // `@thisx` is not a context reference; a path must follow a dot.
    let path = rest.strip_prefix('.')?;

    match reference_segments(path) {
        Some(segments) => Some(Ok(Expr::Context(
            kind,
            segments.into_iter().map(|(key, _)| key).collect(),
        ))),
        None => Some(Err(())),
    }
}

// Mirror `Stem.Expression.reference_expression/1`: a dotted chain of segments,
// each a bare identifier (`name`, `Item1`) or a bracketed literal key
// (`[first-name]`, `[a.b]`). Bracket segments escape characters a bare
// identifier cannot carry. Returns `None` for anything that is not a clean
// dotted reference, so the caller falls back to transformer parsing.
fn parse_reference(t: &str) -> Option<Expr> {
    let keys: Vec<String> = reference_segments(t)?
        .into_iter()
        .map(|(key, _)| key)
        .collect();

    match keys.len() {
        1 => Some(Expr::Identifier(keys.into_iter().next().unwrap())),
        _ => Some(Expr::PathImplicit(keys)),
    }
}

// Split a reference into `(key, bracketed?)` segments, stripping brackets.
// Returns `None` unless the whole input is exactly dotted segments — bare runs
// of `[A-Za-z_][A-Za-z0-9_]*` or bracketed `[..]` keys separated by single dots.
fn reference_segments(t: &str) -> Option<Vec<(String, bool)>> {
    let bytes = t.as_bytes();
    let n = bytes.len();
    let mut segments: Vec<(String, bool)> = Vec::new();
    let mut i = 0;

    while i < n {
        if !segments.is_empty() {
            if bytes[i] != b'.' {
                return None;
            }
            i += 1;
            if i >= n {
                return None;
            }
        }

        if bytes[i] == b'[' {
            i += 1;
            let start = i;
            while i < n && bytes[i] != b']' {
                i += 1;
            }
            if i >= n || i == start {
                return None;
            }
            segments.push((t[start..i].to_string(), true));
            i += 1;
        } else {
            let start = i;
            let first = bytes[i] as char;
            if !(first.is_ascii_alphabetic() || first == '_') {
                return None;
            }
            i += 1;
            while i < n {
                let c = bytes[i] as char;
                if c.is_ascii_alphanumeric() || c == '_' {
                    i += 1;
                } else {
                    break;
                }
            }
            segments.push((t[start..i].to_string(), false));
        }
    }

    if segments.is_empty() {
        None
    } else {
        Some(segments)
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
    if let Some((key, value)) = split_once(&scan_top_level(arg)) {
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
    if let Some(special) = iteration_special(t) {
        return Ok(special);
    }
    match context_path(t) {
        Some(Ok(expr)) => return Ok(expr),
        Some(Err(())) => return Err(not_supported(t, span)),
        None => {}
    }
    match parse_reference(t) {
        Some(expr) => Ok(expr),
        None => Err(not_supported(t, span)),
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

// A pipeline stage: a bare helper name, or `name arg arg..` (prefix-style,
// space-separated args — the same call form as a standalone transformer). The
// piped value is prepended as the implicit first positional argument during
// lowering.
fn parse_stage(stage: &str, span: Span) -> Result<Stage, CompileError> {
    let t = stage.trim();
    if t.is_empty() {
        return Err(unsupported(
            "pipeline stages cannot be empty".to_string(),
            span,
        ));
    }
    let parts = split_whitespace(&scan_top_level(t));
    match parts.split_first() {
        Some((name, args)) if is_identifier(name) => {
            let args = args
                .iter()
                .map(|arg| parse_transformer_arg(arg, span))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Stage {
                name: name.clone(),
                args,
            })
        }
        _ => Err(not_supported(t, span)),
    }
}

// ── Top-level tokenizer (mirrors Stem.Expression's splitter) ─────────────────
//
// Splits an expression at the top level only: parenthesised groups and quoted
// strings are absorbed into `Text` so the `|>`, whitespace, `,`, `=`, and `:`
// separators inside them never split an argument.

enum Tok {
    Pipe,
    // A boolean operator (`||`, `&&`) reserved for future use. Lexed by maximal
    // munch so it never splits into pipe stages; the parser rejects it.
    Reserved(&'static str),
    Comma,
    Eq,
    Colon,
    Ws(char),
    Text(String),
}

impl Tok {
    fn value(&self) -> String {
        match self {
            Tok::Pipe => "|".to_string(),
            Tok::Reserved(s) => s.to_string(),
            Tok::Comma => ",".to_string(),
            Tok::Eq => "=".to_string(),
            Tok::Colon => ":".to_string(),
            Tok::Ws(c) => c.to_string(),
            Tok::Text(s) => s.clone(),
        }
    }
}

// The first reserved boolean operator in a token stream, if any.
fn reserved_op(tokens: &[Tok]) -> Option<&'static str> {
    tokens.iter().find_map(|t| match t {
        Tok::Reserved(s) => Some(*s),
        _ => None,
    })
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
            '[' => consume_bracket(&chars, &mut k, &mut text),
            // Reserved boolean operators: maximal munch so `||` is never two
            // pipe stages and `&&` never leaks through as text.
            '|' if chars.get(k + 1) == Some(&'|') => {
                flush(&mut text, &mut out);
                out.push(Tok::Reserved("||"));
                k += 2;
            }
            '&' if chars.get(k + 1) == Some(&'&') => {
                flush(&mut text, &mut out);
                out.push(Tok::Reserved("&&"));
                k += 2;
            }
            // Pipe separator: `value | transformer arg`.
            '|' => {
                flush(&mut text, &mut out);
                out.push(Tok::Pipe);
                k += 1;
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
            '[' => consume_bracket(chars, k, text),
            _ => {
                text.push(d);
                *k += 1;
            }
        }
    }
}

// A bracketed literal key (`[my name]`) is atomic, like a quoted chunk: its
// content runs to the first `]` with no nesting or escapes, so spaces, commas,
// `=`, and `:` inside it are part of the key, not token separators.
fn consume_bracket(chars: &[char], k: &mut usize, text: &mut String) {
    text.push('[');
    *k += 1;
    while *k < chars.len() {
        let d = chars[*k];
        text.push(d);
        *k += 1;
        if d == ']' {
            break;
        }
    }
}

fn split_pipes(tokens: &[Tok]) -> Vec<String> {
    split_by(tokens, |t| matches!(t, Tok::Pipe))
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

fn split_once(tokens: &[Tok]) -> Option<(String, String)> {
    let idx = tokens.iter().position(|t| matches!(t, Tok::Eq))?;
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
    // Looks like a literal the BEAM accepts, but not yet ported (strings with
    // escape sequences): reported as "not yet supported".
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
        _ if t.starts_with('\'') => Some(single_quoted_literal(t)),
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

// A single-quoted literal denotes the same string value as its double-quoted
// form. Embedded double quotes need no escaping here, so only escape sequences
// (which the BEAM resolves and this port does not yet replicate) fall back to
// pending.
fn single_quoted_literal(t: &str) -> Literal {
    if t.len() >= 2 && t.ends_with('\'') {
        let content = &t[1..t.len() - 1];
        if content.contains('\\') {
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
    has_parent: bool,
    locals: HashSet<String>,
}

impl Scope {
    fn root() -> Self {
        Scope {
            in_each: false,
            has_parent: false,
            locals: HashSet::new(),
        }
    }

    fn each_body(&self, params: &[String]) -> Self {
        Scope {
            in_each: true,
            has_parent: true,
            locals: self.with_locals(params),
        }
    }

    fn with_body(&self, params: &[String]) -> Self {
        Scope {
            in_each: self.in_each,
            has_parent: true,
            locals: self.with_locals(params),
        }
    }

    fn each_else(&self) -> Self {
        Scope {
            in_each: false,
            has_parent: self.has_parent,
            locals: self.locals.clone(),
        }
    }

    fn with_locals(&self, params: &[String]) -> HashSet<String> {
        let mut locals = self.locals.clone();
        locals.extend(params.iter().cloned());
        locals
    }
}

// Region definitions visible while lowering a node list, keyed by name. Values
// borrow region bodies from the node tree.
type Regions<'a> = std::collections::HashMap<String, &'a [Node]>;

fn lower_nodes<'a>(
    nodes: &'a [Node],
    scope: &Scope,
    regions: &Regions<'a>,
    stack: &[String],
    with_spans: bool,
) -> Result<Vec<Value>, CompileError> {
    // Collect every region defined in this list first (a yield may reference one
    // defined later), merged over the regions inherited from enclosing lists.
    let mut merged = regions.clone();
    for node in nodes {
        if let Node::Region { name, body } = node {
            merged.insert(name.clone(), body.as_slice());
        }
    }

    let mut out = Vec::new();
    for node in nodes {
        out.extend(lower_node(node, scope, &merged, stack, with_spans)?);
    }
    Ok(out)
}

fn lower_node<'a>(
    node: &'a Node,
    scope: &Scope,
    regions: &Regions<'a>,
    stack: &[String],
    with_spans: bool,
) -> Result<Vec<Value>, CompileError> {
    let single = |value| Ok(vec![value]);
    match node {
        // Region definitions are inlined at yield sites, never emitted in place.
        Node::Region { .. } => Ok(Vec::new()),
        Node::Text { text, file, span } => {
            let mut instr = json!({ "t": "text", "text": text });
            if with_spans {
                instr["src"] = json!({ "file": file, "start": span.0, "end": span.1 });
            }
            single(instr)
        }
        Node::Emit {
            expr,
            escape,
            span,
            file,
        } => {
            let mut instr = json!({
                "t": "emit",
                "value": lower_value(expr, scope, *span)?,
                "escape": escape,
            });
            if with_spans {
                instr["src"] = json!({ "file": file, "start": span.0, "end": span.1 });
            }
            single(instr)
        }
        Node::If {
            cond,
            then,
            otherwise,
            span,
        } => single(json!({
            "t": "if",
            "cond": lower_value(cond, scope, *span)?,
            "then": lower_nodes(then, scope, regions, stack, with_spans)?,
            "else": lower_nodes(otherwise, scope, regions, stack, with_spans)?,
        })),
        Node::Each {
            subject,
            params,
            body,
            otherwise,
            span,
        } => single(json!({
            "t": "each",
            "subject": lower_value(subject, scope, *span)?,
            "params": params,
            "body": lower_nodes(body, &scope.each_body(params), regions, stack, with_spans)?,
            "else": lower_nodes(otherwise, &scope.each_else(), regions, stack, with_spans)?,
        })),
        Node::With {
            subject,
            params,
            body,
            otherwise,
            span,
        } => single(json!({
            "t": "with",
            "subject": lower_value(subject, scope, *span)?,
            "params": params,
            "body": lower_nodes(body, &scope.with_body(params), regions, stack, with_spans)?,
            "else": lower_nodes(otherwise, scope, regions, stack, with_spans)?,
        })),
        // A yield inlines the named region's instructions, with a recursion
        // guard. An undefined region yields nothing, matching the BEAM.
        Node::Yield { name, span } => {
            if stack.iter().any(|active| active == name) {
                return Err(unsupported(
                    format!("recursive region yield detected for `{name}`"),
                    *span,
                ));
            }
            match regions.get(name.as_str()) {
                Some(body) => {
                    let mut nested = stack.to_vec();
                    nested.push(name.clone());
                    lower_nodes(body, scope, regions, &nested, with_spans)
                }
                None => Ok(Vec::new()),
            }
        }
        // A partial scope rebinds the assigns to the context (or, when absent,
        // the caller's current data context) merged with the hash, and lowers
        // its body under a fresh root scope — mirroring `Stem.Bytecode`'s
        // `:scope` instruction.
        Node::PartialScope {
            context,
            hash,
            body,
            span,
        } => {
            let base = match context {
                Some(expr) => lower_value(expr, scope, *span)?,
                None if scope.in_each => this(),
                None => assigns(),
            };

            let mut hash_map = serde_json::Map::new();
            for (key, value) in hash {
                hash_map.insert(key.clone(), lower_value(value, scope, *span)?);
            }

            single(json!({
                "t": "scope",
                "base": base,
                "hash": hash_map,
                "body": lower_nodes(body, &Scope::root(), regions, stack, with_spans)?,
            }))
        }
        // `Partial` nodes exist only on the `parse_ast` path; compilation always
        // expands partials inline, so one reaching lowering is a bug.
        Node::Partial { span, .. } => Err(unsupported(
            "internal error: unexpanded partial reached lowering",
            *span,
        )),
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
        Expr::Context(CtxKind::This, segments) => Ok(get_chain(this(), segments)),
        Expr::Context(CtxKind::Root, segments) => Ok(get_chain(root(), segments)),
        Expr::Context(CtxKind::Parent, segments) => {
            if scope.has_parent {
                Ok(get_chain(parent(), segments))
            } else {
                Err(unsupported(
                    "@parent is only available inside a block (#each / #with)",
                    span,
                ))
            }
        }
        Expr::Index0 if scope.in_each => Ok(json!({ "t": "index" })),
        Expr::Index1 if scope.in_each => Ok(json!({ "t": "index1" })),
        Expr::Key if scope.in_each => Ok(json!({ "t": "key" })),
        Expr::First if scope.in_each => Ok(json!({ "t": "first" })),
        Expr::Last if scope.in_each => Ok(json!({ "t": "last" })),
        Expr::Index0 | Expr::Index1 | Expr::Key | Expr::First | Expr::Last => Err(unsupported(
            "@index/@index1/@key/@first/@last are only available inside an #each",
            span,
        )),
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

fn assigns() -> Value {
    json!({ "t": "assigns" })
}

fn local(name: &str) -> Value {
    json!({ "t": "local", "name": name })
}

fn this() -> Value {
    json!({ "t": "this" })
}

fn parent() -> Value {
    json!({ "t": "parent" })
}

fn root() -> Value {
    json!({ "t": "root" })
}

// A bare contextual reference is the context op itself; a path wraps it in a get.
fn get_chain(base: Value, segments: &[String]) -> Value {
    if segments.is_empty() {
        base
    } else {
        get(base, segments)
    }
}

fn get(base: Value, segments: &[String]) -> Value {
    json!({ "t": "get", "base": base, "segments": wire_segments(segments) })
}

// A numeric segment crosses the boundary as a number (list index); a named
// segment as a string (map key), keeping the list-vs-map distinction.
fn wire_segments(segments: &[String]) -> Vec<Value> {
    segments
        .iter()
        .map(|segment| match segment.parse::<i64>() {
            Ok(index) => json!(index),
            Err(_) => json!(segment),
        })
        .collect()
}

// ── Pre-expansion AST serialization (`stem-ast/v1`) ──────────────────────────
//
// A syntactic rendering of the assembled `Node`/`Expr` tree, distinct from the
// scope-aware bytecode lowering above. It preserves source structure (partials
// stay references; expressions keep their written form) and tags every node
// with its byte `src` span, so the playground can map AST nodes back to the
// editor and build the partial dependency graph. Mirrored by `Stem.AST.to_wire/1`.

fn ast_nodes_to_json(nodes: &[Node]) -> Vec<Value> {
    nodes.iter().map(ast_node_to_json).collect()
}

fn src(span: Span) -> Value {
    json!({ "start": span.0, "end": span.1 })
}

fn ast_node_to_json(node: &Node) -> Value {
    match node {
        Node::Text { text, span, .. } => {
            json!({ "t": "text", "text": text, "src": src(*span) })
        }
        Node::Emit {
            expr, escape, span, ..
        } => json!({
            "t": "emit",
            "expr": expr_to_ast_json(expr),
            "escape": escape,
            "src": src(*span),
        }),
        Node::If {
            cond,
            then,
            otherwise,
            span,
        } => json!({
            "t": "if",
            "cond": expr_to_ast_json(cond),
            "then": ast_nodes_to_json(then),
            "else": ast_nodes_to_json(otherwise),
            "src": src(*span),
        }),
        Node::Each {
            subject,
            params,
            body,
            otherwise,
            span,
        } => json!({
            "t": "each",
            "subject": expr_to_ast_json(subject),
            "params": params,
            "body": ast_nodes_to_json(body),
            "else": ast_nodes_to_json(otherwise),
            "src": src(*span),
        }),
        Node::With {
            subject,
            params,
            body,
            otherwise,
            span,
        } => json!({
            "t": "with",
            "subject": expr_to_ast_json(subject),
            "params": params,
            "body": ast_nodes_to_json(body),
            "else": ast_nodes_to_json(otherwise),
            "src": src(*span),
        }),
        Node::Region { name, body } => json!({
            "t": "region",
            "name": name,
            "body": ast_nodes_to_json(body),
        }),
        Node::Yield { name, span } => json!({
            "t": "yield",
            "name": name,
            "src": src(*span),
        }),
        Node::PartialScope {
            context,
            hash,
            body,
            span,
        } => json!({
            "t": "partial_scope",
            "context": context.as_ref().map(expr_to_ast_json),
            "hash": hash_to_ast_json(hash),
            "body": ast_nodes_to_json(body),
            "src": src(*span),
        }),
        Node::Partial {
            name,
            context,
            hash,
            span,
        } => json!({
            "t": "partial",
            "name": name,
            "context": context.as_ref().map(expr_to_ast_json),
            "hash": hash_to_ast_json(hash),
            "src": src(*span),
        }),
    }
}

fn hash_to_ast_json(hash: &[(String, Expr)]) -> Value {
    let mut map = serde_json::Map::new();
    for (key, value) in hash {
        map.insert(key.clone(), expr_to_ast_json(value));
    }
    Value::Object(map)
}

fn ctx_kind_str(kind: CtxKind) -> &'static str {
    match kind {
        CtxKind::This => "this",
        CtxKind::Parent => "parent",
        CtxKind::Root => "root",
    }
}

fn expr_to_ast_json(expr: &Expr) -> Value {
    match expr {
        Expr::Identifier(name) => json!({ "t": "identifier", "name": name }),
        Expr::PathImplicit(segments) => json!({ "t": "path", "segments": segments }),
        Expr::Context(kind, path) => json!({
            "t": "context",
            "kind": ctx_kind_str(*kind),
            "path": path,
        }),
        Expr::Index0 => json!({ "t": "index" }),
        Expr::Index1 => json!({ "t": "index1" }),
        Expr::Key => json!({ "t": "key" }),
        Expr::First => json!({ "t": "first" }),
        Expr::Last => json!({ "t": "last" }),
        Expr::Lit(value) => json!({ "t": "lit", "value": value }),
        Expr::Transformer { name, args } => json!({
            "t": "call",
            "name": name,
            "args": args.iter().map(arg_to_ast_json).collect::<Vec<_>>(),
        }),
        Expr::Pipeline { lhs, stages } => json!({
            "t": "pipeline",
            "lhs": expr_to_ast_json(lhs),
            "stages": stages
                .iter()
                .map(|stage| json!({
                    "name": stage.name,
                    "args": stage.args.iter().map(arg_to_ast_json).collect::<Vec<_>>(),
                }))
                .collect::<Vec<_>>(),
        }),
    }
}

fn arg_to_ast_json(arg: &Arg) -> Value {
    match arg {
        Arg::Positional(expr) => json!({ "kind": "positional", "value": expr_to_ast_json(expr) }),
        Arg::Keyword(key, expr) => {
            json!({ "kind": "keyword", "key": key, "value": expr_to_ast_json(expr) })
        }
    }
}

// ── Small grammar helpers (mirror Stem.Expression's regexes) ─────────────────

// `^[a-z_][a-zA-Z0-9_]*$`
fn is_identifier(s: &str) -> bool {
    // Allow a single trailing `?` (Elixir-style predicate convention: empty?, present?).
    let s = s.strip_suffix('?').unwrap_or(s);
    let mut chars = s.chars();
    !s.is_empty()
        && matches!(chars.next(), Some(c) if c.is_ascii_lowercase() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

// A block-parameter binding name: `^[A-Za-z_][A-Za-z0-9_]*$`. Unlike
// `is_identifier`, this allows an uppercase leading letter — block params bind
// to a fresh gensym on the BEAM, so the author's casing is unconstrained.
fn is_binding_name(s: &str) -> bool {
    let mut chars = s.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
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

    // Compile with no partials (the common case for these unit tests).
    fn wire(source: &str) -> Result<Value, CompileError> {
        compile_to_wire(source, &Partials::new())
    }

    // Compares against authoritative wire from `Stem.Bytecode.to_wire/1`, parsed
    // as Values so field order is irrelevant.
    fn assert_wire(source: &str, expected_json: &str) {
        let got = wire(source).expect("should compile");
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
            "{{#each items}}{{@this}};{{/each}}",
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
    fn underscore_is_anonymous_and_repeatable() {
        assert_wire(
            "{{#each rows as |_ _ i1|}}{{i1}} {{/each}}",
            r#"{"version":"stem-bc/v1","instructions":[{"body":[{"escape":"html","t":"emit","value":{"name":"i1","t":"local"}},{"t":"text","text":" "}],"else":[],"params":["_","_","i1"],"subject":{"name":"rows","t":"assign"},"t":"each"}]}"#,
        );
    }

    #[test]
    fn duplicate_named_params_are_rejected() {
        assert!(wire("{{#each xs as |a a b|}}{{a}}{{/each}}").is_err());
    }

    // `_` is a wildcard only in block-param position; as an expression it stays a
    // normal key, so a data key named `_` remains readable.
    #[test]
    fn underscore_remains_a_readable_data_key() {
        assert_wire(
            "{{_}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"name":"_","t":"assign"}}]}"#,
        );
        assert_wire(
            "{{#each rows}}{{_}}{{/each}}",
            r#"{"version":"stem-bc/v1","instructions":[{"body":[{"escape":"html","t":"emit","value":{"base":{"t":"this"},"segments":["_"],"t":"get"}}],"else":[],"params":[],"subject":{"name":"rows","t":"assign"},"t":"each"}]}"#,
        );
    }

    #[test]
    fn this_is_the_block_context() {
        assert_wire(
            "Hello {{#with name}}{{@this}}{{/with}}!",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"Hello "},{"body":[{"escape":"html","t":"emit","value":{"t":"this"}}],"else":[],"params":[],"subject":{"name":"name","t":"assign"},"t":"with"},{"t":"text","text":"!"}]}"#,
        );
    }

    #[test]
    fn partials_expand_inline() {
        let mut partials = Partials::new();
        partials.insert("header".into(), "<h1>{{title}}</h1>".into());
        partials.insert("row".into(), "<li>{{@this.name}}</li>".into());
        let got = compile_to_wire(
            "{{> header}}<ul>{{#each items}}{{> row}}{{/each}}</ul>",
            &partials,
        )
        .expect("compiles");
        let want: Value = serde_json::from_str(
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"<h1>"},{"escape":"html","t":"emit","value":{"name":"title","t":"assign"}},{"t":"text","text":"</h1>"},{"t":"text","text":"<ul>"},{"body":[{"t":"text","text":"<li>"},{"escape":"html","t":"emit","value":{"base":{"t":"this"},"segments":["name"],"t":"get"}},{"t":"text","text":"</li>"}],"else":[],"params":[],"subject":{"name":"items","t":"assign"},"t":"each"},{"t":"text","text":"</ul>"}]}"#,
        )
        .unwrap();
        assert_eq!(got, want);
    }

    #[test]
    fn partial_context_argument_lowers_to_scope() {
        let mut partials = Partials::new();
        partials.insert("card".into(), "{{name}}".into());
        let got = compile_to_wire("{{> card user}}", &partials).expect("compiles");
        let want: Value = serde_json::from_str(
            r#"{"instructions":[{"base":{"name":"user","t":"assign"},"body":[{"escape":"html","t":"emit","value":{"name":"name","t":"assign"}}],"hash":{},"t":"scope"}],"version":"stem-bc/v1"}"#,
        )
        .unwrap();
        assert_eq!(got, want);
    }

    #[test]
    fn partial_hash_argument_inherits_assigns() {
        let mut partials = Partials::new();
        partials.insert("badge".into(), "{{label}}".into());
        let got = compile_to_wire(r#"{{> badge label="VIP"}}"#, &partials).expect("compiles");
        let want: Value = serde_json::from_str(
            r#"{"instructions":[{"base":{"t":"assigns"},"body":[{"escape":"html","t":"emit","value":{"name":"label","t":"assign"}}],"hash":{"label":{"t":"lit","value":"VIP"}},"t":"scope"}],"version":"stem-bc/v1"}"#,
        )
        .unwrap();
        assert_eq!(got, want);
    }

    #[test]
    fn partial_context_inside_each_uses_this() {
        let mut partials = Partials::new();
        partials.insert("card".into(), "{{name}}".into());
        let got = compile_to_wire("{{#each users}}{{> card @this}}{{/each}}", &partials)
            .expect("compiles");
        let want: Value = serde_json::from_str(
            r#"{"instructions":[{"body":[{"base":{"t":"this"},"body":[{"escape":"html","t":"emit","value":{"name":"name","t":"assign"}}],"hash":{},"t":"scope"}],"else":[],"params":[],"subject":{"name":"users","t":"assign"},"t":"each"}],"version":"stem-bc/v1"}"#,
        )
        .unwrap();
        assert_eq!(got, want);
    }

    #[test]
    fn partial_context_and_hash_combine() {
        let mut partials = Partials::new();
        partials.insert("card".into(), "{{name}}".into());
        let got = compile_to_wire(r#"{{> card user role="admin"}}"#, &partials).expect("compiles");
        let want: Value = serde_json::from_str(
            r#"{"instructions":[{"base":{"name":"user","t":"assign"},"body":[{"escape":"html","t":"emit","value":{"name":"name","t":"assign"}}],"hash":{"role":{"t":"lit","value":"admin"}},"t":"scope"}],"version":"stem-bc/v1"}"#,
        )
        .unwrap();
        assert_eq!(got, want);
    }

    #[test]
    fn partial_rejects_two_context_arguments() {
        let mut partials = Partials::new();
        partials.insert("card".into(), "x".into());
        let err = compile_to_wire("{{> card a b}}", &partials).unwrap_err();
        assert!(err.message.contains("at most one context argument"));
    }

    #[test]
    fn unknown_partial_errors() {
        let err = compile_to_wire("{{> nope}}", &Partials::new()).unwrap_err();
        assert!(err.message.contains("unknown partial"));
    }

    #[test]
    fn partial_recursion_is_detected() {
        let mut partials = Partials::new();
        partials.insert("a".into(), "x{{> a}}".into());
        let err = compile_to_wire("{{> a}}", &partials).unwrap_err();
        assert!(err.message.contains("recursion"));
    }

    #[test]
    fn each_index1_and_this_path() {
        assert_wire(
            "{{#each rows}}{{@index1}}. {{@this.name}}{{/each}}",
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
    fn parent_reference_gets_the_enclosing_context() {
        assert_wire(
            "{{#each items}}{{@parent.title}}: {{@this}}{{/each}}",
            r#"{"version":"stem-bc/v1","instructions":[{"body":[{"escape":"html","t":"emit","value":{"base":{"t":"parent"},"segments":["title"],"t":"get"}},{"t":"text","text":": "},{"escape":"html","t":"emit","value":{"t":"this"}}],"else":[],"params":[],"subject":{"name":"items","t":"assign"},"t":"each"}]}"#,
        );
    }

    #[test]
    fn this_and_root_resolve_to_gets_over_the_context() {
        assert_wire(
            "{{@this.name}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"base":{"t":"this"},"segments":["name"],"t":"get"}}]}"#,
        );
        assert_wire(
            "{{@root.title}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"base":{"t":"root"},"segments":["title"],"t":"get"}}]}"#,
        );
    }

    #[test]
    fn numeric_segments_index_lists() {
        assert_wire(
            "{{items.[2]}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"base":{"name":"items","t":"assign"},"segments":[2],"t":"get"}}]}"#,
        );
    }

    #[test]
    fn literal_variable_keys() {
        assert_wire(
            "{{[first-name]}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"name":"first-name","t":"assign"}}]}"#,
        );
        assert_wire(
            "{{user.[first-name]}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"base":{"name":"user","t":"assign"},"segments":["first-name"],"t":"get"}}]}"#,
        );
        // A bracket key may contain dots and other non-identifier characters.
        assert_wire(
            "{{[a.b]}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"name":"a.b","t":"assign"}}]}"#,
        );
        // Uppercase block params and `_` are valid bindings; literal item fields resolve by name.
        assert_wire(
            "{{#each people as |p _ I1|}}{{I1}}:{{p.[first-name]}} {{/each}}",
            r#"{"version":"stem-bc/v1","instructions":[{"body":[{"escape":"html","t":"emit","value":{"name":"I1","t":"local"}},{"t":"text","text":":"},{"escape":"html","t":"emit","value":{"base":{"name":"p","t":"local"},"segments":["first-name"],"t":"get"}},{"t":"text","text":" "}],"else":[],"params":["p","_","I1"],"subject":{"name":"people","t":"assign"},"t":"each"}]}"#,
        );
    }

    #[test]
    fn bracket_keys_with_spaces_are_atomic_tokens() {
        // A space inside `[my name]` is part of the key, not an argument
        // separator: the bracket chunk is atomic in the top-level tokenizer.
        assert_wire(
            r#"{{default [my name] "?"}}"#,
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"name":"my name","t":"assign"},{"t":"lit","value":"?"}],"kwargs":{},"name":"default","t":"call"}}]}"#,
        );
        // Also inside a parenthesised sub-expression.
        assert_wire(
            r#"{{upcase (default [my name] "?")}}"#,
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"args":[{"name":"my name","t":"assign"},{"t":"lit","value":"?"}],"kwargs":{},"name":"default","t":"call"}],"kwargs":{},"name":"upcase","t":"call"}}]}"#,
        );
    }

    #[test]
    fn iteration_variables_outside_each_are_rejected() {
        for source in [
            "{{@index}}",
            "{{@index1}}",
            "{{@key}}",
            "{{@first}}",
            "{{@last}}",
        ] {
            let err = wire(source).unwrap_err();
            assert!(
                err.message.contains("only available inside an #each"),
                "for {source:?}: {}",
                err.message
            );
        }
    }

    #[test]
    fn parent_outside_a_block_is_rejected() {
        let err = wire("{{@parent.x}}").unwrap_err();
        assert!(err
            .message
            .contains("@parent is only available inside a block"));
    }

    #[test]
    fn pipelines_lower_to_nested_calls() {
        assert_wire(
            "{{name | upcase}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"name":"name","t":"assign"}],"kwargs":{},"name":"upcase","t":"call"}}]}"#,
        );
        assert_wire(
            "{{name | upcase | trim}}",
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"args":[{"name":"name","t":"assign"}],"kwargs":{},"name":"upcase","t":"call"}],"kwargs":{},"name":"trim","t":"call"}}]}"#,
        );
        assert_wire(
            "{{text | truncate 20}}",
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
    fn single_quoted_strings_lower_like_double_quoted() {
        // A single-quoted literal is the same string value as its double-quoted
        // form, so both compile to identical bytecode.
        assert_eq!(
            wire("{{'hello world'}}").unwrap(),
            wire(r#"{{"hello world"}}"#).unwrap()
        );
        // An embedded double quote needs no escaping inside single quotes.
        assert_wire(
            r#"{{x | default 'a"b'}}"#,
            r#"{"version":"stem-bc/v1","instructions":[{"escape":"html","t":"emit","value":{"args":[{"name":"x","t":"assign"},{"t":"lit","value":"a\"b"}],"kwargs":{},"name":"default","t":"call"}}]}"#,
        );
        // Escape sequences are not ported yet — pending, like double-quoted.
        assert!(wire(r"{{'a\nb'}}").is_err());
    }

    #[test]
    fn regions_are_inlined_at_yield_sites() {
        assert_wire(
            "{{#region head}}H{{/region}}before{{yield head}}after",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"before"},{"t":"text","text":"H"},{"t":"text","text":"after"}]}"#,
        );
        // An undefined region yields nothing, like the BEAM.
        assert_wire(
            "{{yield missing}}x",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"x"}]}"#,
        );
    }

    #[test]
    fn recursive_yield_is_rejected() {
        let err = wire("{{#region a}}{{yield a}}{{/region}}{{yield a}}").unwrap_err();
        assert!(err.message.contains("recursive"), "{}", err.message);
    }

    #[test]
    fn comments_and_trim_markers() {
        assert_wire(
            "a {{~ x ~}} b",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"a"},{"escape":"html","t":"emit","value":{"name":"x","t":"assign"}},{"t":"text","text":"b"}]}"#,
        );
        assert_wire(
            "a {{! c }} b",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"a  b"}]}"#,
        );
        assert_wire(
            "{{!-- c --}}x",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"x"}]}"#,
        );
        assert_wire(
            "a {{x ~}}   b",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"a "},{"escape":"html","t":"emit","value":{"name":"x","t":"assign"}},{"t":"text","text":"b"}]}"#,
        );
    }

    #[test]
    fn unported_constructs_report_a_span() {
        for src in [r#"{{"a\tb"}}"#, "{{& raw}}", "{{a + b}}"] {
            let err = wire(src).unwrap_err();
            assert!(
                err.message.contains("not yet supported"),
                "for {src:?}: {}",
                err.message
            );
            assert!(err.end > err.start, "for {src:?}");
        }
    }

    #[test]
    fn reserved_boolean_operators_are_rejected_with_a_clear_message() {
        // Maximal munch: `||`/`&&` never split into pipe stages, spaced or not.
        for (src, op) in [
            ("{{ a || b }}", "||"),
            ("{{a||b}}", "||"),
            ("{{ a && b }}", "&&"),
            ("{{ x | a && b }}", "&&"),
        ] {
            let err = wire(src).unwrap_err();
            assert_eq!(
                err.message,
                format!("the '{op}' operator is not supported"),
                "for {src:?}"
            );
        }
        // A single `|` remains the pipe separator.
        assert!(wire("{{ name | upcase }}").is_ok());
    }

    #[test]
    fn empty_pipeline_stages_report_a_clear_error() {
        assert_eq!(
            wire("{{ x |  | trim }}").unwrap_err().message,
            "pipeline stages cannot be empty"
        );
    }

    #[test]
    fn structural_errors_report_a_span() {
        assert!(wire("{{#each x}}y")
            .unwrap_err()
            .message
            .contains("missing closing"));
        assert!(wire("{{#if a}}x{{/each}}")
            .unwrap_err()
            .message
            .contains("expected"));
        assert!(wire("done{{/if}}")
            .unwrap_err()
            .message
            .contains("unexpected closing"));
        assert_eq!(wire("Hi {{name").unwrap_err().start, 3);
    }

    #[test]
    fn backslash_escape() {
        // N=1: escape (literal tag, no evaluation)
        assert_wire(
            r"\{{name}}",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"{{name}}"}]}"#,
        );
        assert_wire(
            r"before \{{name}} after",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"before {{name}} after"}]}"#,
        );
        // N=2: consume 1, emit 1 backslash + evaluate
        assert_wire(
            r"\\{{name}}",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"\\"},{"escape":"html","t":"emit","value":{"name":"name","t":"assign"}}]}"#,
        );
        // N=3: consume 1, emit 2 backslashes + evaluate
        assert_wire(
            r"\\\{{name}}",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"\\\\"},{"escape":"html","t":"emit","value":{"name":"name","t":"assign"}}]}"#,
        );
        // N=4: consume 1, emit 3 backslashes + evaluate
        assert_wire(
            r"\\\\{{name}}",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"\\\\\\"},{"escape":"html","t":"emit","value":{"name":"name","t":"assign"}}]}"#,
        );
        // Standalone backslashes (not before {{) pass through unchanged
        assert_wire(
            r"a \ b \\ c",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"a \\ b \\\\ c"}]}"#,
        );
    }

    #[test]
    fn raw_block() {
        assert_wire(
            "{{{{#raw}}}}{{name}}{{{{/raw}}}}",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"{{name}}"}]}"#,
        );
        assert_wire(
            "before{{{{#raw}}}}{{name}}{{{{/raw}}}}after",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"before{{name}}after"}]}"#,
        );
        assert_wire(
            "{{{{#mycodeblock}}}}raw content{{{{/mycodeblock}}}}",
            r#"{"version":"stem-bc/v1","instructions":[{"t":"text","text":"raw content"}]}"#,
        );
    }

    // ── parse_ast (pre-expansion AST) ────────────────────────────────────────

    fn ast(source: &str) -> Value {
        parse_ast_to_wire(source).expect("should parse")
    }

    fn ast_nodes(source: &str) -> Value {
        ast(source)["nodes"].clone()
    }

    #[test]
    fn ast_keeps_partials_unexpanded() {
        // A partial reference stays a `partial` node (no inlining), even when no
        // partial map is supplied — this is what powers the dependency graph.
        assert_eq!(
            ast_nodes("a {{> header}} b"),
            json!([
                { "t": "text", "text": "a ", "src": { "start": 0, "end": 2 } },
                { "t": "partial", "name": "header", "context": null, "hash": {},
                  "src": { "start": 2, "end": 14 } },
                { "t": "text", "text": " b", "src": { "start": 14, "end": 16 } },
            ])
        );
    }

    #[test]
    fn ast_partial_args_carry_context_and_hash() {
        assert_eq!(
            ast_nodes(r#"{{> card user role="admin"}}"#),
            json!([{
                "t": "partial",
                "name": "card",
                "context": { "t": "identifier", "name": "user" },
                "hash": { "role": { "t": "lit", "value": "admin" } },
                "src": { "start": 0, "end": 28 },
            }])
        );
    }

    #[test]
    fn ast_version_and_expr_shapes() {
        assert_eq!(ast("x")["version"], json!("stem-ast/v1"));
        // Expressions keep their written syntactic form, not the scope-aware op.
        assert_eq!(
            ast_nodes("{{user.name | upcase}}"),
            json!([{
                "t": "emit",
                "escape": "html",
                "expr": {
                    "t": "pipeline",
                    "lhs": { "t": "path", "segments": ["user", "name"] },
                    "stages": [{ "name": "upcase", "args": [] }],
                },
                "src": { "start": 0, "end": 22 },
            }])
        );
    }

    #[test]
    fn ast_blocks_and_context_refs() {
        assert_eq!(
            ast_nodes("{{#each items}}{{@this.name}}{{/each}}"),
            json!([{
                "t": "each",
                "subject": { "t": "identifier", "name": "items" },
                "params": [],
                "body": [{
                    "t": "emit",
                    "escape": "html",
                    "expr": { "t": "context", "kind": "this", "path": ["name"] },
                    "src": { "start": 15, "end": 29 },
                }],
                "else": [],
                "src": { "start": 0, "end": 15 },
            }])
        );
    }
}
