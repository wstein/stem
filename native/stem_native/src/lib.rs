// SPDX-License-Identifier: Apache-2.0
//
// PoC native renderer for Stem portable bytecode (`stem-bc/v1`).
//
// `handle/1` takes a JSON request — `{"program": <Stem.Bytecode.to_wire/1>,
// "data": <assigns>}`, or `{"batch": [...]}` — and returns the rendered output.
// The `stem_native` bin wraps it for WASI stdin/stdout; the C-ABI exports
// (`stem_alloc`/`stem_dealloc`/`stem_render`) expose it to a browser via
// `wasm32-unknown-unknown` with no WASI.
//
// It reimplements, natively, the subset of the Stem runtime the conformance
// corpus exercises — assign/path resolution, block helpers, the index/key/this
// scoping, HTML/JSON/XML/none escaping, and a transformer stdlib — so its output
// can be checked byte-for-byte against the BEAM reference.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;

mod compile;

#[derive(Deserialize)]
struct Input {
    program: Program,
    data: Value,
}

#[derive(Deserialize)]
struct Program {
    instructions: Vec<Instr>,
}

#[derive(Deserialize)]
#[serde(tag = "t", rename_all = "lowercase")]
enum Instr {
    Text {
        text: String,
    },
    Emit {
        value: Op,
        escape: String,
    },
    If {
        cond: Op,
        then: Vec<Instr>,
        #[serde(rename = "else")]
        otherwise: Vec<Instr>,
    },
    Each {
        subject: Op,
        params: Vec<String>,
        body: Vec<Instr>,
        #[serde(rename = "else")]
        otherwise: Vec<Instr>,
    },
    With {
        subject: Op,
        params: Vec<String>,
        body: Vec<Instr>,
        #[serde(rename = "else")]
        otherwise: Vec<Instr>,
    },
    Scope {
        base: Op,
        hash: HashMap<String, Op>,
        body: Vec<Instr>,
    },
}

#[derive(Deserialize)]
#[serde(tag = "t", rename_all = "lowercase")]
enum Op {
    Lit {
        value: Value,
    },
    Assign {
        name: String,
    },
    Local {
        name: String,
    },
    Assigns,
    This,
    Index,
    Index1,
    Key,
    Get {
        base: Box<Op>,
        segments: Vec<String>,
    },
    Call {
        name: String,
        args: Vec<Op>,
        // The BEAM lowers keyword args to Elixir `{key, value}` tuples appended
        // to the flat arg list — a shape no native transformer consumes and a
        // JSON value cannot represent. They are captured here (not silently
        // dropped) so the pre-check can refuse a program that carries any,
        // rather than render with the keywords missing. Optional on the wire so
        // older programs without the field still deserialize.
        #[serde(default)]
        kwargs: HashMap<String, Op>,
    },
}

// Render context, mirroring `Stem.Bytecode.VM`'s threaded state.
struct Ctx {
    root: Value,
    this: Value,
    index: i64,
    key: Value,
    in_each: bool,
    locals: HashMap<String, Value>,
    resolve: GetterResolver,
}

/// Renders a JSON request to its output string with no host getters: a
/// `{"$getter": ...}` field is inert and resolves to null. This is the entry the
/// C ABI (and thus the browser) uses — the shipped engine ships no getters.
pub fn handle(raw: &str) -> String {
    handle_with_getters(raw, no_getters)
}

/// Like [`handle`], but a Rust embedder supplies a [`GetterResolver`] so that
/// `{"$getter": "name"}` fields resolve to host-computed values. The getter
/// logic lives entirely in the embedder's `resolve`; the engine only detects the
/// marker and delegates.
///
/// Total: malformed input yields a distinguishable error string rather than a
/// panic or process exit. `{"batch": [{program, data}, ...]}` renders many
/// requests and returns a JSON array of outputs (used by the differential fuzz
/// harness). Otherwise a single `{program, data}` renders to a raw string.
pub fn handle_with_getters(raw: &str, resolve: GetterResolver) -> String {
    let request: Value = match serde_json::from_str(raw) {
        Ok(value) => value,
        Err(err) => return format!("stem_native error: invalid input JSON: {err}"),
    };

    // `{"compile": "<template source>"}` returns the wire program, or
    // `{"error": {message, start, end}}` with a source span — the playground's
    // backend-free compile step.
    if let Some(Value::String(source)) = request.get("compile") {
        let partials = parse_partials(request.get("partials"));
        return serde_json::to_string(&compile_result(source, &partials)).unwrap_or_default();
    }

    // `{"compile_batch": [...]}` compiles many templates in one process and
    // returns a JSON array of wire-program-or-error objects, mirroring the render
    // `batch` shape — used by the BEAM-vs-Rust differential harness. An entry is
    // either a bare source string or `{"template": src, "partials": {..}}`.
    if let Some(Value::Array(entries)) = request.get("compile_batch") {
        let outputs: Vec<Value> = entries
            .iter()
            .map(|entry| match entry {
                Value::String(src) => compile_result(src, &compile::Partials::new()),
                Value::Object(obj) => match obj.get("template").and_then(Value::as_str) {
                    Some(src) => compile_result(src, &parse_partials(obj.get("partials"))),
                    None => json!({ "error": { "message": "compile_batch object needs a string `template`", "start": 0, "end": 0 } }),
                },
                _ => json!({ "error": { "message": "compile_batch entries must be strings or objects", "start": 0, "end": 0 } }),
            })
            .collect();
        return serde_json::to_string(&outputs).unwrap_or_default();
    }

    if let Some(batch) = request.get("batch") {
        match serde_json::from_value::<Vec<Input>>(batch.clone()) {
            Ok(inputs) => {
                let outputs: Vec<String> = inputs
                    .iter()
                    .map(|input| render_input(input, resolve))
                    .collect();
                serde_json::to_string(&outputs).unwrap_or_default()
            }
            Err(err) => format!("stem_native error: invalid batch shape: {err}"),
        }
    } else {
        match serde_json::from_value::<Input>(request) {
            Ok(input) => render_input(&input, resolve),
            Err(err) => format!("stem_native error: invalid request shape: {err}"),
        }
    }
}

// ── C ABI for wasm32-unknown-unknown (browser) ───────────────────────────────
//
// The host writes the request JSON into linear memory at `stem_alloc(len)`,
// calls `stem_render(ptr, len)` which returns a packed `(out_ptr << 32) | out_len`,
// reads the UTF-8 output, then frees both buffers with `stem_dealloc`.

/// Allocates `len` bytes in wasm linear memory and returns the pointer.
#[no_mangle]
pub extern "C" fn stem_alloc(len: usize) -> *mut u8 {
    let layout = std::alloc::Layout::from_size_align(len.max(1), 1).unwrap();
    unsafe { std::alloc::alloc(layout) }
}

/// Frees a buffer previously returned by `stem_alloc`/`stem_render`.
///
/// # Safety
/// `ptr`/`len` must come from this module's allocator.
#[no_mangle]
pub unsafe extern "C" fn stem_dealloc(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        let layout = std::alloc::Layout::from_size_align(len.max(1), 1).unwrap();
        std::alloc::dealloc(ptr, layout);
    }
}

/// Renders the UTF-8 request at `ptr`/`len`, returning `(out_ptr << 32) | out_len`.
///
/// # Safety
/// `ptr`/`len` must describe a valid UTF-8 buffer in this module's memory.
#[no_mangle]
pub unsafe extern "C" fn stem_render(ptr: *const u8, len: usize) -> u64 {
    let input = std::slice::from_raw_parts(ptr, len);
    let raw = std::str::from_utf8(input).unwrap_or("");
    let bytes = handle(raw).into_bytes();
    let out_len = bytes.len();
    let out_ptr = stem_alloc(out_len);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_ptr, out_len);
    ((out_ptr as u64) << 32) | (out_len as u64)
}

// Compile one template to its wire program, or an `{"error": {message, span}}`
// object the playground can underline.
fn compile_result(source: &str, partials: &compile::Partials) -> Value {
    match compile::compile_to_wire(source, partials) {
        Ok(program) => program,
        Err(err) => json!({
            "error": { "message": err.message, "start": err.start, "end": err.end }
        }),
    }
}

// Read an optional `{"partials": {name: source, ..}}` request field into a
// name->source map; non-object values and non-string entries are ignored.
fn parse_partials(value: Option<&Value>) -> compile::Partials {
    match value {
        Some(Value::Object(map)) => map
            .iter()
            .filter_map(|(name, src)| src.as_str().map(|s| (name.clone(), s.to_string())))
            .collect(),
        _ => compile::Partials::new(),
    }
}

fn render_input(input: &Input, resolve: GetterResolver) -> String {
    // Refuse — never panic — on any feature this core cannot render with
    // byte-parity: escape modes beyond none/html/xml/json, transformers outside
    // the parity stdlib, and keyword arguments. Returning a structured error
    // here turns an input-triggered abort (a DoS in the browser/WASM build) into
    // a recoverable message.
    if let Some(feature) = unsupported_feature(&input.program.instructions) {
        return format!("stem_native error: unsupported {feature} in this native PoC");
    }

    let ctx = Ctx {
        root: input.data.clone(),
        this: Value::Null,
        index: 0,
        key: Value::Null,
        in_each: false,
        locals: HashMap::new(),
        resolve,
    };

    render(&input.program.instructions, &ctx)
}

// Escape modes the native renderer implements with byte-parity to the BEAM.
const SUPPORTED_ESCAPES: &[&str] = &["none", "html", "xml", "json"];

// Transformers the native `call` dispatcher implements with byte-parity. Kept
// in sync with the match arms in `call`; a name outside this set is refused
// rather than panicked on.
const SUPPORTED_TRANSFORMERS: &[&str] = &[
    "upcase",
    "downcase",
    "trim",
    "capitalize",
    "replace",
    "truncate",
    "starts_with",
    "ends_with",
    "reverse",
    "take",
    "drop",
    "slice",
    "first",
    "default",
    "join",
    "lookup",
    "escape_html",
    "escape_json",
    "map",
    "filter",
    "sort",
    "sort_by",
    "group_by",
    "compact",
    "uniq",
    "flatten",
    "contains",
    "empty?",
    "present?",
];

// Walks a program for the first construct the native core cannot render with
// byte-parity, returning a human description (no source span: the render input
// carries the compiled program, not the original template).
fn unsupported_feature(instrs: &[Instr]) -> Option<String> {
    instrs.iter().find_map(instr_unsupported)
}

fn instr_unsupported(instr: &Instr) -> Option<String> {
    match instr {
        Instr::Text { .. } => None,
        Instr::Emit { value, escape } => {
            if !SUPPORTED_ESCAPES.contains(&escape.as_str()) {
                Some(format!("escape mode '{escape}'"))
            } else {
                op_unsupported(value)
            }
        }
        Instr::If {
            cond,
            then,
            otherwise,
        } => op_unsupported(cond)
            .or_else(|| unsupported_feature(then))
            .or_else(|| unsupported_feature(otherwise)),
        Instr::Each {
            subject,
            body,
            otherwise,
            ..
        }
        | Instr::With {
            subject,
            body,
            otherwise,
            ..
        } => op_unsupported(subject)
            .or_else(|| unsupported_feature(body))
            .or_else(|| unsupported_feature(otherwise)),
        Instr::Scope { base, hash, body } => op_unsupported(base)
            .or_else(|| hash.values().find_map(op_unsupported))
            .or_else(|| unsupported_feature(body)),
    }
}

fn op_unsupported(op: &Op) -> Option<String> {
    match op {
        Op::Call { name, args, kwargs } => {
            if !SUPPORTED_TRANSFORMERS.contains(&name.as_str()) {
                Some(format!("transformer '{name}'"))
            } else if !kwargs.is_empty() {
                Some(format!("keyword arguments to transformer '{name}'"))
            } else {
                args.iter().find_map(op_unsupported)
            }
        }
        Op::Get { base, .. } => op_unsupported(base),
        _ => None,
    }
}

fn render(instructions: &[Instr], ctx: &Ctx) -> String {
    let mut out = String::new();
    for instr in instructions {
        exec(instr, ctx, &mut out);
    }
    out
}

fn exec(instr: &Instr, ctx: &Ctx, out: &mut String) {
    match instr {
        Instr::Text { text } => out.push_str(text),

        Instr::Emit { value, escape } => {
            let rendered = to_string(&eval(value, ctx));
            out.push_str(&escape_with(&rendered, escape));
        }

        Instr::If {
            cond,
            then,
            otherwise,
        } => {
            if truthy(&eval(cond, ctx)) {
                out.push_str(&render(then, ctx));
            } else {
                out.push_str(&render(otherwise, ctx));
            }
        }

        Instr::Each {
            subject,
            params,
            body,
            otherwise,
        } => {
            let entries = each_entries(&eval(subject, ctx));
            if entries.is_empty() {
                let else_ctx = Ctx {
                    in_each: false,
                    ..clone_ctx(ctx)
                };
                out.push_str(&render(otherwise, &else_ctx));
            } else {
                for (index, (current, key)) in entries.into_iter().enumerate() {
                    let inner = each_context(ctx, params, current, key, index as i64);
                    out.push_str(&render(body, &inner));
                }
            }
        }

        Instr::With {
            subject,
            params,
            body,
            otherwise,
        } => {
            let value = eval(subject, ctx);
            if truthy(&value) {
                out.push_str(&render(body, &with_context(ctx, params, value)));
            } else {
                out.push_str(&render(otherwise, ctx));
            }
        }

        Instr::Scope { base, hash, body } => {
            out.push_str(&render(body, &scope_context(ctx, base, hash)));
        }
    }
}

// Build a partial's render context: the base (context arg, or the caller's
// current data context) coerced to an object, merged with the evaluated hash,
// with the block-scoped state reset. Mirrors `Stem.Bytecode.VM`'s `:scope`.
fn scope_context(ctx: &Ctx, base: &Op, hash: &HashMap<String, Op>) -> Ctx {
    let mut scope = match eval(base, ctx) {
        Value::Object(map) => map,
        _ => serde_json::Map::new(),
    };
    for (key, value_op) in hash {
        scope.insert(key.clone(), eval(value_op, ctx));
    }

    Ctx {
        root: Value::Object(scope),
        this: Value::Null,
        index: 0,
        key: Value::Null,
        in_each: false,
        locals: HashMap::new(),
        resolve: ctx.resolve,
    }
}

fn each_context(ctx: &Ctx, params: &[String], current: Value, key: Value, index: i64) -> Ctx {
    let mut locals = ctx.locals.clone();
    match params {
        [] => {}
        [item] => {
            locals.insert(item.clone(), current.clone());
        }
        // |item key| binds the map key (or the index for lists, where key is null).
        [item, key_name] => {
            locals.insert(item.clone(), current.clone());
            let bound_key = if key.is_null() {
                Value::from(index)
            } else {
                key.clone()
            };
            locals.insert(key_name.clone(), bound_key);
        }
        // |item index0 index1| binds the item and both index forms.
        [item, index0, index1] => {
            locals.insert(item.clone(), current.clone());
            locals.insert(index0.clone(), Value::from(index));
            locals.insert(index1.clone(), Value::from(index + 1));
        }
        _ => {}
    }

    Ctx {
        root: ctx.root.clone(),
        this: current,
        index,
        key,
        in_each: true,
        locals,
        resolve: ctx.resolve,
    }
}

fn with_context(ctx: &Ctx, params: &[String], subject: Value) -> Ctx {
    let mut locals = ctx.locals.clone();
    if let [item] = params {
        locals.insert(item.clone(), subject.clone());
    }

    Ctx {
        this: subject,
        locals,
        ..clone_ctx(ctx)
    }
}

fn clone_ctx(ctx: &Ctx) -> Ctx {
    Ctx {
        root: ctx.root.clone(),
        this: ctx.this.clone(),
        index: ctx.index,
        key: ctx.key.clone(),
        in_each: ctx.in_each,
        locals: ctx.locals.clone(),
        resolve: ctx.resolve,
    }
}

fn eval(op: &Op, ctx: &Ctx) -> Value {
    match op {
        Op::Lit { value } => value.clone(),
        Op::Assign { name } => {
            let fetched = ctx.root.get(name).cloned().unwrap_or(Value::Null);
            resolve_getter(fetched, &ctx.root, ctx.resolve)
        }
        Op::Local { name } => ctx.locals.get(name).cloned().unwrap_or(Value::Null),
        Op::Assigns => ctx.root.clone(),
        Op::This => ctx.this.clone(),
        Op::Index => Value::from(ctx.index),
        Op::Index1 => Value::from(ctx.index + 1),
        Op::Key => ctx.key.clone(),
        Op::Get { base, segments } => {
            let mut value = eval(base, ctx);
            for segment in segments {
                value = get_field(&value, segment, ctx.resolve);
            }
            value
        }
        // Keyword args are refused up front by `unsupported_feature`, so a Call
        // reaching the VM only has positional args.
        Op::Call { name, args, .. } => {
            let positional: Vec<Value> = args.iter().map(|a| eval(a, ctx)).collect();
            call(name, &positional)
        }
    }
}

fn get_field(value: &Value, segment: &str, resolve: GetterResolver) -> Value {
    match value {
        Value::Object(map) => {
            let fetched = map.get(segment).cloned().unwrap_or(Value::Null);
            resolve_getter(fetched, value, resolve)
        }
        _ => Value::Null,
    }
}

// ── Per-host computed getters ────────────────────────────────────────────────
//
// A field whose wire value is the sentinel `{"$getter": "name"}` is *computed*:
// the engine hands `name` and the field's parent object (the ST4 "self") to a
// host-supplied `GetterResolver` and renders its result. This is the native
// analogue of the BEAM backend's zero-arity assign getters.
//
// The engine ships **no** getters: getter logic is the embedder's business and
// is never part of the library or the wire. Only the field marker is data, and
// it is inert under the default resolver ([`no_getters`], used by [`handle`] and
// the C ABI). A Rust embedder supplies getters via [`handle_with_getters`].
// Because the logic lives in the host, this has no cross-backend byte-parity and
// stays out of the conformance corpus; it is covered by the tests below.

const GETTER_SENTINEL: &str = "$getter";

/// Resolves `{"$getter": "name"}` fields: given the getter name and the parent
/// object as its "self", returns the computed value.
pub type GetterResolver = fn(&str, &Value) -> Value;

/// The default resolver: no getters. A `$getter` field resolves to null.
pub fn no_getters(_name: &str, _parent: &Value) -> Value {
    Value::Null
}

// If `value` is a getter sentinel, delegate to the host resolver with `parent`
// as "self"; otherwise return it unchanged.
fn resolve_getter(value: Value, parent: &Value, resolve: GetterResolver) -> Value {
    if let Value::Object(map) = &value {
        if map.len() == 1 {
            if let Some(Value::String(name)) = map.get(GETTER_SENTINEL) {
                return resolve(name, parent);
            }
        }
    }
    value
}

// ── Value helpers (mirror Stem.Runtime / String.Chars) ──────────────────────

fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
        // Only the integer 0 is falsey; the float 0.0 is truthy, matching
        // `Stem.Runtime.is_truthy/1` whose falsey set contains the integer 0 but
        // not 0.0.
        Value::Number(n) => !(n.as_i64() == Some(0) || n.as_u64() == Some(0)),
    }
}

fn present(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
        _ => true,
    }
}

fn to_string(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::Bool(b) => b.to_string(),
        // Integers match the BEAM. Floats are a KNOWN DIVERGENCE (gap G2): the
        // BEAM uses Erlang `:erlang.float_to_binary(f, [:short])` (e.g. `1.0e8`),
        // while serde_json's notation/exponent rules differ. Floats are kept out
        // of the conformance corpus until this is ported — see the "Known
        // divergences" section of the Cross-Backend Conformance Spec note.
        Value::Number(n) => n.to_string(),
        Value::String(s) => s.clone(),
        // Lists/maps are never emitted directly by the corpus; render as JSON.
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

fn each_entries(value: &Value) -> Vec<(Value, Value)> {
    match value {
        Value::Array(items) => items.iter().map(|i| (i.clone(), Value::Null)).collect(),
        Value::Object(map) => map
            .iter()
            .map(|(k, v)| (v.clone(), Value::from(k.clone())))
            .collect(),
        Value::Null => vec![],
        Value::Bool(false) => vec![],
        other => vec![(other.clone(), Value::Null)],
    }
}

// ── Escaping (mirror Stem.Escaping) ─────────────────────────────────────────

fn escape_with(s: &str, mode: &str) -> String {
    match mode {
        "none" => s.to_string(),
        "xml" => s
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;"),
        "json" => s
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
            .replace('\t', "\\t"),
        // "html" and — defensively — any mode the render-time pre-check did not
        // already reject fall back to HTML escaping, the secure default, so a
        // missed mode can never emit raw markup.
        _ => s
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
            .replace('\'', "&#39;"),
    }
}

// ── Transformer stdlib (mirror Stem.Transformers) ───────────────────────────
//
// Implements the built-in transformers that can match the BEAM byte-for-byte.
// The set is mirrored in `SUPPORTED_TRANSFORMERS`; `unsupported_feature` refuses
// any program referencing a name outside it, so dispatch here never has to
// panic. Deliberately excluded (no byte-parity is possible, so they are kept out
// of the differential fuzzer):
//   * json / inspect — Elixir-specific serialization formatting and map key
//     ordering;
//   * i18n `t` — delegates to a host-provided translator (a host closure), so
//     the bytecode marks it a host transformer the native core cannot run.
// Unicode-cased transforms match for ASCII; the fuzzer restricts inputs to
// ASCII, where String.upcase/downcase and Rust's casing agree.

fn call(name: &str, args: &[Value]) -> Value {
    match name {
        // Strings
        "upcase" => Value::from(to_string(&args[0]).to_uppercase()),
        "downcase" => Value::from(to_string(&args[0]).to_lowercase()),
        "trim" => Value::from(to_string(&args[0]).trim().to_string()),
        "capitalize" => Value::from(capitalize(&to_string(&args[0]))),
        "replace" => {
            Value::from(to_string(&args[0]).replace(&to_string(&args[1]), &to_string(&args[2])))
        }
        "truncate" => Value::from(truncate(&args[0], &args[1], args.get(2))),
        "starts_with" => Value::from(to_string(&args[0]).starts_with(&to_string(&args[1]))),
        "ends_with" => Value::from(to_string(&args[0]).ends_with(&to_string(&args[1]))),

        // Shared sequence ops (string- and list-aware)
        "reverse" => reverse(&args[0]),
        "take" => take(&args[0], &args[1]),
        "drop" => drop(&args[0], &args[1]),
        "slice" => slice(&args[0], &args[1], &args[2]),
        "first" => first(&args[0]),

        // Minimum
        "default" => {
            if present(&args[0]) {
                args[0].clone()
            } else {
                args[1].clone()
            }
        }
        "join" => {
            let sep = args.get(1).map(to_string).unwrap_or_default();
            Value::from(join(&args[0], &sep))
        }
        "lookup" => lookup(&args[0], &args[1]),
        "escape_html" => Value::from(escape_with(&to_string(&args[0]), "html")),
        "escape_json" => Value::from(escape_json(&to_string(&args[0]))),

        // Collections
        "map" => Value::Array(
            enumerable(&args[0])
                .iter()
                .map(|i| select(i, &to_string(&args[1])))
                .collect(),
        ),
        "filter" => filter(&args[0], args.get(1)),
        "sort" => sort(&args[0]),
        "sort_by" => sort_by(&args[0], &to_string(&args[1])),
        "group_by" => group_by(&args[0], &to_string(&args[1])),
        "compact" => Value::Array(
            enumerable(&args[0])
                .into_iter()
                .filter(|v| !v.is_null())
                .collect(),
        ),
        "uniq" => uniq(&args[0]),
        "flatten" => Value::Array(flatten(&args[0])),

        // Predicates
        "contains" => Value::from(contains(&args[0], &args[1])),
        "empty?" => Value::from(!present(&args[0])),
        "present?" => Value::from(present(&args[0])),

        // Unreachable: `unsupported_feature` rejects any name outside
        // `SUPPORTED_TRANSFORMERS` before rendering begins. Returns null rather
        // than panicking so an out-of-sync allowlist can never abort the engine.
        _ => Value::Null,
    }
}

fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + &chars.as_str().to_lowercase(),
        None => String::new(),
    }
}

fn enumerable(value: &Value) -> Vec<Value> {
    match value {
        Value::Array(items) => items.clone(),
        Value::Object(map) => map.values().cloned().collect(),
        Value::Null => vec![],
        other => vec![other.clone()],
    }
}

fn join(value: &Value, sep: &str) -> String {
    enumerable(value)
        .iter()
        .map(to_string)
        .collect::<Vec<_>>()
        .join(sep)
}

// Navigate a dotted selector (e.g. "meta.rank"), mirroring Stem's select_value:
// object keys, and integer indices into lists.
fn select(value: &Value, selector: &str) -> Value {
    selector
        .split('.')
        .filter(|s| !s.is_empty())
        .fold(value.clone(), |acc, segment| match &acc {
            Value::Object(map) => map.get(segment).cloned().unwrap_or(Value::Null),
            Value::Array(items) => segment
                .parse::<usize>()
                .ok()
                .and_then(|i| items.get(i))
                .cloned()
                .unwrap_or(Value::Null),
            _ => Value::Null,
        })
}

fn lookup(collection: &Value, key: &Value) -> Value {
    match (collection, key) {
        (Value::Object(map), Value::String(k)) => map.get(k).cloned().unwrap_or(Value::Null),
        (Value::Array(items), Value::Number(n)) => n
            .as_u64()
            .and_then(|i| items.get(i as usize))
            .cloned()
            .unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

fn contains(collection: &Value, needle: &Value) -> bool {
    match collection {
        Value::String(s) => s.contains(&to_string(needle)),
        Value::Array(items) => items.contains(needle),
        Value::Object(map) => match needle {
            Value::String(k) => map.contains_key(k),
            _ => false,
        },
        _ => false,
    }
}

fn truncate(value: &Value, count: &Value, omission: Option<&Value>) -> String {
    let text = to_string(value);
    let chars: Vec<char> = text.chars().collect();
    let count = count_arg(count);
    let omission = omission.map(to_string).unwrap_or_default();

    if chars.len() <= count {
        text
    } else if omission.is_empty() {
        chars[..count].iter().collect()
    } else {
        let keep = count.saturating_sub(omission.chars().count());
        chars[..keep].iter().collect::<String>() + &omission
    }
}

fn reverse(value: &Value) -> Value {
    match value {
        Value::String(s) => Value::from(s.chars().rev().collect::<String>()),
        other => Value::Array(enumerable(other).into_iter().rev().collect()),
    }
}

fn take(value: &Value, count: &Value) -> Value {
    let n = count_arg(count);
    match value {
        Value::String(s) => Value::from(s.chars().take(n).collect::<String>()),
        other => Value::Array(enumerable(other).into_iter().take(n).collect()),
    }
}

fn drop(value: &Value, count: &Value) -> Value {
    let n = count_arg(count);
    match value {
        Value::String(s) => Value::from(s.chars().skip(n).collect::<String>()),
        other => Value::Array(enumerable(other).into_iter().skip(n).collect()),
    }
}

fn slice(value: &Value, start: &Value, length: &Value) -> Value {
    let start = count_arg(start);
    let length = count_arg(length);
    match value {
        Value::String(s) => Value::from(s.chars().skip(start).take(length).collect::<String>()),
        other => Value::Array(
            enumerable(other)
                .into_iter()
                .skip(start)
                .take(length)
                .collect(),
        ),
    }
}

fn first(value: &Value) -> Value {
    match value {
        Value::String(s) => Value::from(s.chars().next().map(String::from).unwrap_or_default()),
        other => enumerable(other).into_iter().next().unwrap_or(Value::Null),
    }
}

fn filter(value: &Value, selector: Option<&Value>) -> Value {
    let items = enumerable(value);
    let kept = match selector {
        None => items.into_iter().filter(truthy).collect(),
        Some(sel) => {
            let sel = to_string(sel);
            items
                .into_iter()
                .filter(|i| truthy(&select(i, &sel)))
                .collect()
        }
    };
    Value::Array(kept)
}

fn sort(value: &Value) -> Value {
    let mut items = enumerable(value);
    items.sort_by(value_cmp);
    Value::Array(items)
}

fn sort_by(value: &Value, selector: &str) -> Value {
    let mut items = enumerable(value);
    items.sort_by(|a, b| value_cmp(&select(a, selector), &select(b, selector)));
    Value::Array(items)
}

fn group_by(value: &Value, selector: &str) -> Value {
    let mut groups = serde_json::Map::new();
    for item in enumerable(value) {
        let key = to_string(&select(&item, selector));
        groups
            .entry(key)
            .or_insert_with(|| Value::Array(vec![]))
            .as_array_mut()
            .unwrap()
            .push(item);
    }
    Value::Object(groups)
}

fn uniq(value: &Value) -> Value {
    let mut seen: Vec<Value> = vec![];
    for item in enumerable(value) {
        if !seen.contains(&item) {
            seen.push(item);
        }
    }
    Value::Array(seen)
}

fn flatten(value: &Value) -> Vec<Value> {
    enumerable(value)
        .into_iter()
        .flat_map(|item| match item {
            Value::Array(_) => flatten(&item),
            other => vec![other],
        })
        .collect()
}

fn escape_json(s: &str) -> String {
    let encoded = serde_json::to_string(&Value::from(s)).unwrap_or_default();
    encoded
        .strip_prefix('"')
        .and_then(|e| e.strip_suffix('"'))
        .unwrap_or(&encoded)
        .to_string()
}

fn count_arg(value: &Value) -> usize {
    match value {
        Value::Number(n) => n
            .as_i64()
            .filter(|i| *i >= 0)
            .map(|i| i as usize)
            .unwrap_or(0),
        Value::String(s) => s.parse::<usize>().unwrap_or(0),
        _ => 0,
    }
}

// Approximate Elixir term ordering for the homogeneous lists the fuzzer sorts:
// by JSON kind, then by value within numbers and strings.
fn value_cmp(a: &Value, b: &Value) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    fn rank(v: &Value) -> u8 {
        match v {
            Value::Null => 0,
            Value::Bool(_) => 1,
            Value::Number(_) => 2,
            Value::String(_) => 3,
            Value::Array(_) => 4,
            Value::Object(_) => 5,
        }
    }
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x
            .as_f64()
            .partial_cmp(&y.as_f64())
            .unwrap_or(Ordering::Equal),
        (Value::String(x), Value::String(y)) => x.cmp(y),
        (Value::Bool(x), Value::Bool(y)) => x.cmp(y),
        _ => rank(a).cmp(&rank(b)),
    }
}

#[cfg(test)]
mod getter_tests {
    use super::*;
    use serde_json::json;

    // Host getters live in the embedder's code, never the engine. These are the
    // test embedder's: `full_name`/`initials` derived from the parent object.
    fn demo_getters(name: &str, self_obj: &Value) -> Value {
        let field = |key: &str| self_obj.get(key).map(to_string).unwrap_or_default();
        match name {
            "full_name" => Value::from(
                format!("{} {}", field("first"), field("last"))
                    .trim()
                    .to_string(),
            ),
            "initials" => {
                let initial = |key: &str| {
                    field(key)
                        .chars()
                        .next()
                        .map(|c| c.to_uppercase().to_string())
                        .unwrap_or_default()
                };
                Value::from(format!("{}{}", initial("first"), initial("last")))
            }
            _ => Value::Null,
        }
    }

    // Render through the default (no-getter) entry.
    fn render(program: Value, data: Value) -> String {
        let request = json!({ "program": { "instructions": program }, "data": data });
        handle(&request.to_string())
    }

    // Render with a host getter resolver injected.
    fn render_with(program: Value, data: Value, resolve: GetterResolver) -> String {
        let request = json!({ "program": { "instructions": program }, "data": data });
        handle_with_getters(&request.to_string(), resolve)
    }

    fn emit_assign(name: &str) -> Value {
        json!([{ "t": "emit", "value": { "t": "assign", "name": name }, "escape": "html" }])
    }

    #[test]
    fn default_path_ships_no_getters() {
        // The C ABI / browser entry resolves `$getter` fields to null.
        let out = render(
            emit_assign("full_name"),
            json!({ "first": "Ada", "last": "Lovelace", "full_name": { "$getter": "full_name" } }),
        );
        assert_eq!(out, "");
    }

    #[test]
    fn top_level_getter_is_invoked_with_root_as_self() {
        let out = render_with(
            emit_assign("full_name"),
            json!({ "first": "Ada", "last": "Lovelace", "full_name": { "$getter": "full_name" } }),
            demo_getters,
        );
        assert_eq!(out, "Ada Lovelace");
    }

    #[test]
    fn leaf_getter_receives_its_parent_object_as_self() {
        let program = json!([{
            "t": "emit",
            "value": { "t": "get", "base": { "t": "assign", "name": "user" }, "segments": ["full_name"] },
            "escape": "html"
        }]);
        let out = render_with(
            program,
            json!({ "user": { "first": "Grace", "last": "Hopper", "full_name": { "$getter": "full_name" } } }),
            demo_getters,
        );
        assert_eq!(out, "Grace Hopper");
    }

    #[test]
    fn getter_result_is_html_escaped_like_any_value() {
        let out = render_with(
            emit_assign("full_name"),
            json!({ "first": "<b>", "last": "x", "full_name": { "$getter": "full_name" } }),
            demo_getters,
        );
        assert_eq!(out, "&lt;b&gt; x");
    }

    #[test]
    fn resolver_dispatches_distinct_getters() {
        let out = render_with(
            emit_assign("initials"),
            json!({ "first": "ada", "last": "lovelace", "initials": { "$getter": "initials" } }),
            demo_getters,
        );
        assert_eq!(out, "AL");
    }

    #[test]
    fn unknown_getter_resolves_to_empty() {
        let out = render_with(
            emit_assign("mystery"),
            json!({ "mystery": { "$getter": "no_such" } }),
            demo_getters,
        );
        assert_eq!(out, "");
    }

    #[test]
    fn getter_drives_block_truthiness() {
        let program = json!([{
            "t": "if",
            "cond": { "t": "assign", "name": "full_name" },
            "then": [{ "t": "text", "text": "Y" }],
            "else": []
        }]);
        let on = render_with(
            program.clone(),
            json!({ "first": "A", "last": "B", "full_name": { "$getter": "full_name" } }),
            demo_getters,
        );
        assert_eq!(on, "Y");

        let off = render_with(
            program,
            json!({ "first": "", "last": "", "full_name": { "$getter": "full_name" } }),
            demo_getters,
        );
        assert_eq!(off, "");
    }

    #[test]
    fn plain_object_field_is_not_treated_as_a_getter() {
        let program = json!([{
            "t": "emit",
            "value": { "t": "get", "base": { "t": "assign", "name": "user" }, "segments": ["name"] },
            "escape": "html"
        }]);
        let out = render_with(
            program,
            json!({ "user": { "name": "plain" } }),
            demo_getters,
        );
        assert_eq!(out, "plain");
    }
}

#[cfg(test)]
mod scope_tests {
    use super::*;
    use serde_json::json;

    // Compile a template (with partials) to wire, then render it against data —
    // the full native pipeline the playground uses.
    fn render_template(source: &str, partials: &[(&str, &str)], data: Value) -> String {
        let mut map = compile::Partials::new();
        for (name, src) in partials {
            map.insert((*name).into(), (*src).into());
        }
        let program = compile::compile_to_wire(source, &map).expect("compiles");
        let request = json!({ "program": program, "data": data });
        handle(&request.to_string())
    }

    #[test]
    fn context_argument_sets_the_partial_scope() {
        let out = render_template(
            "{{> card user}}",
            &[("card", "Name: {{name}}")],
            json!({ "user": { "name": "Nina" } }),
        );
        assert_eq!(out, "Name: Nina");
    }

    #[test]
    fn hash_arguments_are_available_by_name() {
        let out = render_template(
            r#"{{> badge label="VIP"}}"#,
            &[("badge", "[{{label}}]")],
            json!({}),
        );
        assert_eq!(out, "[VIP]");
    }

    #[test]
    fn hash_arguments_override_context_keys() {
        let out = render_template(
            r#"{{> card user name="Override"}}"#,
            &[("card", "{{name}}")],
            json!({ "user": { "name": "Nina" } }),
        );
        assert_eq!(out, "Override");
    }

    #[test]
    fn context_argument_works_inside_each() {
        let out = render_template(
            "{{#each users}}{{> card this}}{{/each}}",
            &[("card", "[{{name}}]")],
            json!({ "users": [{ "name": "A" }, { "name": "B" }] }),
        );
        assert_eq!(out, "[A][B]");
    }

    #[test]
    fn hash_combines_with_inherited_caller_scope() {
        let out = render_template(
            r#"{{> line label="Total"}}"#,
            &[("line", "{{label}}: {{amount}}")],
            json!({ "amount": 42 }),
        );
        assert_eq!(out, "Total: 42");
    }

    #[test]
    fn scalar_context_argument_yields_an_empty_scope() {
        let out = render_template(
            "{{> card greeting}}",
            &[("card", "[{{name}}]")],
            json!({ "greeting": "hi" }),
        );
        assert_eq!(out, "[]");
    }
}

#[cfg(test)]
mod guard_tests {
    use super::*;
    use serde_json::json;

    fn render(program: Value, data: Value) -> String {
        let request = json!({ "program": { "instructions": program }, "data": data });
        handle(&request.to_string())
    }

    #[test]
    fn unsupported_escape_mode_is_a_structured_error_not_a_panic() {
        let out = render(
            json!([{ "t": "emit", "value": { "t": "assign", "name": "x" }, "escape": "url" }]),
            json!({ "x": "a" }),
        );
        assert!(out.contains("stem_native error"), "got: {out}");
        assert!(out.contains("escape mode 'url'"), "got: {out}");
    }

    #[test]
    fn unsupported_transformer_is_a_structured_error_not_a_panic() {
        let out = render(
            json!([{
                "t": "emit",
                "value": { "t": "call", "name": "json", "args": [{ "t": "assign", "name": "x" }], "kwargs": {} },
                "escape": "html"
            }]),
            json!({ "x": "a" }),
        );
        assert!(out.contains("transformer 'json'"), "got: {out}");
    }

    #[test]
    fn keyword_arguments_are_refused_not_dropped() {
        let out = render(
            json!([{
                "t": "emit",
                "value": {
                    "t": "call", "name": "truncate",
                    "args": [{ "t": "assign", "name": "x" }, { "t": "lit", "value": 5 }],
                    "kwargs": { "omission": { "t": "lit", "value": "…" } }
                },
                "escape": "html"
            }]),
            json!({ "x": "abcdefgh" }),
        );
        assert!(
            out.contains("keyword arguments to transformer 'truncate'"),
            "got: {out}"
        );
    }

    #[test]
    fn missing_kwargs_field_still_deserializes() {
        // Programs predating the kwargs field omit it; serde defaults it empty.
        let out = render(
            json!([{
                "t": "emit",
                "value": { "t": "call", "name": "upcase", "args": [{ "t": "assign", "name": "x" }] },
                "escape": "html"
            }]),
            json!({ "x": "hi" }),
        );
        assert_eq!(out, "HI");
    }

    fn render_if(data: Value) -> String {
        render(
            json!([{
                "t": "if",
                "cond": { "t": "assign", "name": "x" },
                "then": [{ "t": "text", "text": "Y" }],
                "else": [{ "t": "text", "text": "N" }]
            }]),
            data,
        )
    }

    #[test]
    fn float_zero_is_truthy_but_integer_zero_is_falsey() {
        assert_eq!(render_if(json!({ "x": 0.0 })), "Y");
        assert_eq!(render_if(json!({ "x": 0 })), "N");
        assert_eq!(render_if(json!({ "x": 0.5 })), "Y");
        assert_eq!(render_if(json!({ "x": 3 })), "Y");
    }
}
