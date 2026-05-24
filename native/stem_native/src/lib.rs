// SPDX-License-Identifier: Apache-2.0
//
// PoC native renderer for Stem portable bytecode (`stem-bc/v1`).
//
// `handle/1` takes a JSON request — `{"program": <Stem.Bytecode.to_wire/1>,
// "data": <assigns>, "transformers": [<group names>]}`, or `{"batch": [...]}` —
// and returns the rendered output. The optional `transformers` list names the
// enabled capability groups (Minimum is always on); it defaults to Minimum-only.
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
    // Capability groups the caller has loaded, by name ("strings",
    // "collections", "predicates", "i18n", or the "standard" bundle). Mirrors
    // the BEAM `transformers:` binding: the Minimum group is always on, and a
    // transformer from any other group is refused unless its group is listed.
    // Absent on the parity wire and from the C ABI, where it defaults to
    // Minimum-only (secure by default).
    #[serde(default)]
    transformers: Vec<String>,
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
        // Provenance for the source map. Present only in span-annotated programs
        // (compiled via `compile_to_wire_with_spans`); absent on the parity wire.
        #[serde(default)]
        src: Option<Src>,
    },
    Emit {
        value: Op,
        escape: String,
        #[serde(default)]
        src: Option<Src>,
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

// Provenance attached to a `text`/`emit` instruction by the span-annotated
// compiler: which template/partial it came from and (for `emit`) the byte span
// of the originating `{{ }}` tag in that file's source.
#[derive(Deserialize)]
struct Src {
    file: String,
    #[serde(default)]
    start: Option<usize>,
    #[serde(default)]
    end: Option<usize>,
}

// One contiguous run of rendered output attributed to a source instruction. The
// segments returned by a mapped render tile the output in order, so the browser
// can map any output offset back to its originating file/tag.
#[derive(serde::Serialize)]
struct Segment {
    // Byte offset and length of this run within the rendered output.
    out: usize,
    len: usize,
    // Originating template/partial ("main" for the entry).
    file: String,
    // "text" for literal text, "emit" for an expression — lets the UI label and
    // style the run without inspecting the span.
    kind: &'static str,
    // Byte span of the source (the text run, or the `{{ }}` tag) in `file`.
    #[serde(skip_serializing_if = "Option::is_none")]
    start: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    end: Option<usize>,
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
        let with_spans = request.get("map").and_then(Value::as_bool).unwrap_or(false);
        return serde_json::to_string(&compile_result(source, &partials, with_spans))
            .unwrap_or_default();
    }

    // `{"compile_batch": [...]}` compiles many templates in one process and
    // returns a JSON array of wire-program-or-error objects, mirroring the render
    // `batch` shape — used by the BEAM-vs-Rust differential harness. An entry is
    // either a bare source string or `{"template": src, "partials": {..}}`.
    if let Some(Value::Array(entries)) = request.get("compile_batch") {
        let outputs: Vec<Value> = entries
            .iter()
            .map(|entry| match entry {
                Value::String(src) => compile_result(src, &compile::Partials::new(), false),
                Value::Object(obj) => match obj.get("template").and_then(Value::as_str) {
                    Some(src) => compile_result(src, &parse_partials(obj.get("partials")), false),
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
        // `{"map": true}` returns `{"output", "segments"}` JSON (the source map);
        // otherwise a single `{program, data}` renders to a raw output string.
        let mapped = request.get("map").and_then(Value::as_bool).unwrap_or(false);
        match serde_json::from_value::<Input>(request) {
            Ok(input) if mapped => render_input_mapped(&input, resolve),
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
// object the playground can underline. With `with_spans`, the program carries
// `src` provenance for the render-time source map (a superset wire); without it
// the output is byte-identical to the BEAM reference.
fn compile_result(source: &str, partials: &compile::Partials, with_spans: bool) -> Value {
    let compiled = if with_spans {
        compile::compile_to_wire_with_spans(source, partials)
    } else {
        compile::compile_to_wire(source, partials)
    };
    match compiled {
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

// The first construct in the program this core cannot render with byte-parity,
// or the first transformer call outside the caller's enabled capability groups,
// as a recoverable error string. Refusing up front — never panicking, never
// emitting partial output — turns an input-triggered abort (a DoS in the
// browser/WASM build) into a message and mirrors the BEAM, which raises before
// rendering when a template reaches an unloaded transformer.
fn refuse_unsupported(input: &Input) -> Option<String> {
    let groups = parse_groups(&input.transformers);
    check_instrs(&input.program.instructions, groups)
}

fn root_ctx(data: &Value, resolve: GetterResolver) -> Ctx {
    Ctx {
        root: data.clone(),
        this: Value::Null,
        index: 0,
        key: Value::Null,
        in_each: false,
        locals: HashMap::new(),
        resolve,
    }
}

fn render_input(input: &Input, resolve: GetterResolver) -> String {
    if let Some(error) = refuse_unsupported(input) {
        return error;
    }
    render(&input.program.instructions, &root_ctx(&input.data, resolve))
}

// Render returning a JSON string `{"output", "segments"}`: the output plus a
// source map tiling it (see `render_mapped`). Used by the playground's mapped
// render path; the segment list is empty unless the program carries `src`
// provenance (compiled with `map: true`).
fn render_input_mapped(input: &Input, resolve: GetterResolver) -> String {
    let (output, segments) = match refuse_unsupported(input) {
        Some(error) => (error, Vec::new()),
        None => render_mapped(&input.program.instructions, &root_ctx(&input.data, resolve)),
    };
    serde_json::to_string(&json!({ "output": output, "segments": segments })).unwrap_or_default()
}

// Escape modes the native renderer implements with byte-parity to the BEAM.
const SUPPORTED_ESCAPES: &[&str] = &["none", "html", "xml", "json"];

// ── Capability groups (mirror Stem.Transformers.groups/0) ───────────────────
//
// Minimum is the always-on floor; Strings, Collections, Predicates, and I18n
// are opt-in via the request "transformers" list. A built-in transformer is
// callable only when one of the groups that provide it is enabled, so an
// untrusted template can never reach a more powerful transformer than the
// caller loaded — the same secure-by-default model as the BEAM dispatcher.
const GROUP_MINIMUM: u8 = 1 << 0;
const GROUP_STRINGS: u8 = 1 << 1;
const GROUP_COLLECTIONS: u8 = 1 << 2;
const GROUP_PREDICATES: u8 = 1 << 3;
const GROUP_I18N: u8 = 1 << 4;

// Resolve the enabled-group set from the request's group names. Minimum is
// always included; unknown names are ignored. "standard" is the Minimum+Strings
// convenience bundle, matching `Stem.Transformers.Standard`.
fn parse_groups(names: &[String]) -> u8 {
    let mut set = GROUP_MINIMUM;
    for name in names {
        set |= match name.as_str() {
            "minimum" => GROUP_MINIMUM,
            "strings" => GROUP_STRINGS,
            "collections" => GROUP_COLLECTIONS,
            "predicates" => GROUP_PREDICATES,
            "i18n" => GROUP_I18N,
            "standard" => GROUP_MINIMUM | GROUP_STRINGS,
            _ => 0,
        };
    }
    set
}

// The capability group(s) that provide a built-in transformer, or `None` if the
// name is not a native built-in. `take`/`drop`/`slice`/`first`/`reverse` are
// shared by Strings and Collections, so either group enables them. Kept in sync
// with the match arms in `call`.
fn builtin_groups(name: &str) -> Option<u8> {
    Some(match name {
        "escape_html" | "escape_json" | "default" | "lookup" | "join" => GROUP_MINIMUM,
        "trim" | "upcase" | "downcase" | "capitalize" | "truncate" | "replace" | "starts_with"
        | "ends_with" => GROUP_STRINGS,
        "take" | "drop" | "slice" | "first" | "reverse" => GROUP_STRINGS | GROUP_COLLECTIONS,
        "map" | "filter" | "sort" | "sort_by" | "group_by" | "compact" | "uniq" | "flatten" => {
            GROUP_COLLECTIONS
        }
        "contains" | "empty?" | "present?" => GROUP_PREDICATES,
        _ => return None,
    })
}

// Group names in a bitset, joined with " or " for the unloaded-group message.
fn group_phrase(set: u8) -> String {
    [
        (GROUP_MINIMUM, "minimum"),
        (GROUP_STRINGS, "strings"),
        (GROUP_COLLECTIONS, "collections"),
        (GROUP_PREDICATES, "predicates"),
        (GROUP_I18N, "i18n"),
    ]
    .iter()
    .filter(|(bit, _)| set & bit != 0)
    .map(|(_, name)| *name)
    .collect::<Vec<_>>()
    .join(" or ")
}

// Walk a program for the first construct the native core cannot render with
// byte-parity, or the first transformer call outside the enabled groups,
// returning the full error string (no source span: the render input carries the
// compiled program, not the original template).
fn check_instrs(instrs: &[Instr], groups: u8) -> Option<String> {
    instrs.iter().find_map(|instr| check_instr(instr, groups))
}

fn check_instr(instr: &Instr, groups: u8) -> Option<String> {
    match instr {
        Instr::Text { .. } => None,
        Instr::Emit { value, escape, .. } => {
            if !SUPPORTED_ESCAPES.contains(&escape.as_str()) {
                Some(format!(
                    "stem_native error: unsupported escape mode '{escape}'"
                ))
            } else {
                check_op(value, groups)
            }
        }
        Instr::If {
            cond,
            then,
            otherwise,
        } => check_op(cond, groups)
            .or_else(|| check_instrs(then, groups))
            .or_else(|| check_instrs(otherwise, groups)),
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
        } => check_op(subject, groups)
            .or_else(|| check_instrs(body, groups))
            .or_else(|| check_instrs(otherwise, groups)),
        Instr::Scope { base, hash, body } => check_op(base, groups)
            .or_else(|| hash.values().find_map(|op| check_op(op, groups)))
            .or_else(|| check_instrs(body, groups)),
    }
}

fn check_op(op: &Op, groups: u8) -> Option<String> {
    match op {
        Op::Call { name, args, kwargs } => match builtin_groups(name) {
            None => Some(format!("stem_native error: unknown transformer '{name}'")),
            Some(provides) => {
                if !kwargs.is_empty() {
                    Some(format!(
                        "stem_native error: keyword arguments to transformer '{name}' are not supported"
                    ))
                } else if provides & groups == 0 {
                    Some(format!(
                        "stem_native error: transformer '{name}' requires the {} capability group, \
                         which is not enabled. Add it to the request \"transformers\" list.",
                        group_phrase(provides)
                    ))
                } else {
                    args.iter().find_map(|arg| check_op(arg, groups))
                }
            }
        },
        Op::Get { base, .. } => check_op(base, groups),
        _ => None,
    }
}

fn render(instructions: &[Instr], ctx: &Ctx) -> String {
    let (out, _segments) = render_mapped(instructions, ctx);
    out
}

// Render and, alongside the output, a segment map tiling it: each `text`/`emit`
// instruction that carries `src` provenance records the byte range it produced.
// Block instructions append their children into the same shared buffer, so the
// recorded offsets are global to the whole output. A program without `src`
// (the parity wire) yields an empty segment list and identical output.
fn render_mapped(instructions: &[Instr], ctx: &Ctx) -> (String, Vec<Segment>) {
    let mut out = String::new();
    let mut segs = Vec::new();
    exec_all(instructions, ctx, &mut out, &mut segs);
    (out, segs)
}

fn exec_all(instructions: &[Instr], ctx: &Ctx, out: &mut String, segs: &mut Vec<Segment>) {
    for instr in instructions {
        exec(instr, ctx, out, segs);
    }
}

// Record a non-empty output run `[begin, end)` against its source provenance.
// Empty runs (e.g. an emit that renders to "") map to no output and are skipped.
fn record(
    segs: &mut Vec<Segment>,
    src: &Option<Src>,
    begin: usize,
    end: usize,
    kind: &'static str,
) {
    if let (Some(src), true) = (src, end > begin) {
        segs.push(Segment {
            out: begin,
            len: end - begin,
            file: src.file.clone(),
            kind,
            start: src.start,
            end: src.end,
        });
    }
}

fn exec(instr: &Instr, ctx: &Ctx, out: &mut String, segs: &mut Vec<Segment>) {
    match instr {
        Instr::Text { text, src } => {
            let begin = out.len();
            out.push_str(text);
            record(segs, src, begin, out.len(), "text");
        }

        Instr::Emit { value, escape, src } => {
            let begin = out.len();
            let rendered = to_string(&eval(value, ctx));
            out.push_str(&escape_with(&rendered, escape));
            record(segs, src, begin, out.len(), "emit");
        }

        Instr::If {
            cond,
            then,
            otherwise,
        } => {
            let branch = if truthy(&eval(cond, ctx)) {
                then
            } else {
                otherwise
            };
            exec_all(branch, ctx, out, segs);
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
                exec_all(otherwise, &else_ctx, out, segs);
            } else {
                for (index, (current, key)) in entries.into_iter().enumerate() {
                    let inner = each_context(ctx, params, current, key, index as i64);
                    exec_all(body, &inner, out, segs);
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
                exec_all(body, &with_context(ctx, params, value), out, segs);
            } else {
                exec_all(otherwise, ctx, out, segs);
            }
        }

        Instr::Scope { base, hash, body } => {
            exec_all(body, &scope_context(ctx, base, hash), out, segs);
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
// Implements the built-in transformers that match the BEAM byte-for-byte. Each
// name's providing capability group is declared in `builtin_groups`, and
// `check_op` refuses a program before rendering if it calls a name whose group
// the caller has not enabled — so dispatch here is reached only for an allowed
// name and never has to panic. Unicode-cased transforms (`upcase`/`downcase`/
// `capitalize`) match for ASCII; the fuzzer restricts inputs to ASCII, where
// String.upcase/downcase and Rust's casing agree.

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

    // Minimum-only render (the secure default): no capability groups loaded.
    fn render(program: Value, data: Value) -> String {
        let request = json!({ "program": { "instructions": program }, "data": data });
        handle(&request.to_string())
    }

    // Render with explicit capability groups loaded.
    fn render_groups(program: Value, data: Value, groups: &[&str]) -> String {
        let request =
            json!({ "program": { "instructions": program }, "data": data, "transformers": groups });
        handle(&request.to_string())
    }

    fn upcase_program() -> Value {
        json!([{
            "t": "emit",
            "value": { "t": "call", "name": "upcase", "args": [{ "t": "assign", "name": "x" }], "kwargs": {} },
            "escape": "html"
        }])
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
    fn unknown_transformer_is_a_structured_error_not_a_panic() {
        let out = render_groups(
            json!([{
                "t": "emit",
                "value": { "t": "call", "name": "no_such_xform", "args": [{ "t": "assign", "name": "x" }], "kwargs": {} },
                "escape": "html"
            }]),
            json!({ "x": "a" }),
            &["strings", "collections", "predicates"],
        );
        assert!(
            out.contains("unknown transformer 'no_such_xform'"),
            "got: {out}"
        );
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
        let out = render_groups(
            json!([{
                "t": "emit",
                "value": { "t": "call", "name": "upcase", "args": [{ "t": "assign", "name": "x" }] },
                "escape": "html"
            }]),
            json!({ "x": "hi" }),
            &["strings"],
        );
        assert_eq!(out, "HI");
    }

    #[test]
    fn transformer_in_an_unloaded_group_is_refused_before_render() {
        // Minimum-only: `upcase` (Strings) is gated off and refused up front.
        let out = render(upcase_program(), json!({ "x": "hi" }));
        assert!(
            out.contains("requires the strings capability group"),
            "got: {out}"
        );
    }

    #[test]
    fn transformer_renders_once_its_group_is_loaded() {
        assert_eq!(
            render_groups(upcase_program(), json!({ "x": "hi" }), &["strings"]),
            "HI"
        );
    }

    #[test]
    fn standard_bundle_loads_strings() {
        // "standard" is the Minimum+Strings convenience bundle.
        assert_eq!(
            render_groups(upcase_program(), json!({ "x": "hi" }), &["standard"]),
            "HI"
        );
    }

    #[test]
    fn collections_transformer_is_gated_independently_of_strings() {
        let program = json!([{
            "t": "emit",
            "value": {
                "t": "call", "name": "join",
                "args": [
                    { "t": "call", "name": "sort", "args": [{ "t": "assign", "name": "xs" }], "kwargs": {} },
                    { "t": "lit", "value": "," }
                ],
                "kwargs": {}
            },
            "escape": "html"
        }]);
        let data = json!({ "xs": ["b", "a", "c"] });

        // Strings loaded but not Collections: `sort` is still refused.
        let refused = render_groups(program.clone(), data.clone(), &["strings"]);
        assert!(
            refused.contains("transformer 'sort' requires the collections capability group"),
            "got: {refused}"
        );

        // Collections loaded: it renders. (`join` is Minimum, always on.)
        assert_eq!(render_groups(program, data, &["collections"]), "a,b,c");
    }

    #[test]
    fn shared_transformer_is_enabled_by_either_group() {
        // `first` is shared by Strings and Collections; either group enables it.
        let program = json!([{
            "t": "emit",
            "value": { "t": "call", "name": "first", "args": [{ "t": "assign", "name": "xs" }], "kwargs": {} },
            "escape": "html"
        }]);
        let data = json!({ "xs": ["a", "b"] });
        assert_eq!(
            render_groups(program.clone(), data.clone(), &["strings"]),
            "a"
        );
        assert_eq!(render_groups(program, data, &["collections"]), "a");
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

#[cfg(test)]
mod source_map_tests {
    use super::*;
    use serde_json::json;

    // Compile with span provenance via the `{"compile", "map": true}` request,
    // returning the wire program (or error object).
    fn compile_mapped(source: &str, partials: &[(&str, &str)]) -> Value {
        let mut map = serde_json::Map::new();
        for (name, src) in partials {
            map.insert((*name).into(), json!(src));
        }
        let request = json!({ "compile": source, "partials": map, "map": true });
        serde_json::from_str(&handle(&request.to_string())).expect("compile json")
    }

    // Render with `{"map": true}`, returning the parsed `{output, segments}`.
    fn render_mapped_req(program: &Value, data: Value) -> Value {
        let request = json!({ "program": program, "data": data, "map": true });
        serde_json::from_str(&handle(&request.to_string())).expect("render json")
    }

    // The segments must tile the output: ordered, contiguous, no gaps/overlaps,
    // covering exactly `[0, output.len())`. Returns the parsed segment array.
    fn assert_tiles(result: &Value) -> Vec<Value> {
        let output = result["output"].as_str().expect("output string");
        let segments = result["segments"]
            .as_array()
            .expect("segments array")
            .clone();
        let mut cursor = 0usize;
        for seg in &segments {
            let out = seg["out"].as_u64().unwrap() as usize;
            let len = seg["len"].as_u64().unwrap() as usize;
            assert_eq!(
                out, cursor,
                "segment gap/overlap at {cursor}; segments: {segments:?}"
            );
            assert!(len > 0, "empty segment recorded: {seg:?}");
            cursor += len;
        }
        assert_eq!(
            cursor,
            output.len(),
            "segments do not cover the whole output"
        );
        segments
    }

    #[test]
    fn segments_attribute_text_and_emit_to_their_file() {
        let program = compile_mapped("Hi {{name}}!", &[]);
        let result = render_mapped_req(&program, json!({ "name": "Ada" }));
        assert_eq!(result["output"], "Hi Ada!");

        let segments = assert_tiles(&result);
        // "Hi " (text, main) | "Ada" (emit, main) | "!" (text, main); every run
        // carries its source byte span.
        assert_eq!(segments.len(), 3);
        assert_eq!(segments[0]["file"], "main");
        assert_eq!(segments[0]["kind"], "text");
        assert_eq!(segments[0]["start"], 0); // "Hi " span
        assert_eq!(segments[0]["end"], 3);
        assert_eq!(segments[1]["file"], "main");
        assert_eq!(segments[1]["kind"], "emit");
        assert_eq!(segments[1]["start"], 3); // byte offset of `{{name}}`
        assert_eq!(segments[1]["end"], 11);
        assert_eq!(segments[2]["kind"], "text");
        assert_eq!(segments[2]["start"], 11); // "!" span
        assert_eq!(segments[2]["end"], 12);
    }

    #[test]
    fn emit_from_a_partial_is_attributed_to_the_partial() {
        let program = compile_mapped("a {{> card}} b", &[("card", "[{{name}}]")]);
        let result = render_mapped_req(&program, json!({ "name": "X" }));
        assert_eq!(result["output"], "a [X] b");

        let segments = assert_tiles(&result);
        // The emitted "X" run must trace back to the `card` partial, not "main".
        let emit = segments
            .iter()
            .find(|s| s["kind"] == "emit")
            .expect("an emit segment");
        assert_eq!(emit["file"], "card");
    }

    #[test]
    fn empty_emit_records_no_segment() {
        // A missing assign renders to "" and must not leave a zero-length segment.
        let program = compile_mapped("[{{missing}}]", &[]);
        let result = render_mapped_req(&program, json!({}));
        assert_eq!(result["output"], "[]");
        let segments = assert_tiles(&result);
        assert_eq!(
            segments.len(),
            2,
            "only the two bracket texts: {segments:?}"
        );
    }

    #[test]
    fn default_wire_carries_no_src_and_maps_to_no_segments() {
        // Compiling without `map` yields the parity wire (no `src`); rendering it
        // with `map: true` still works but produces an empty segment list.
        let program =
            compile::compile_to_wire("Hi {{name}}!", &compile::Partials::new()).expect("compiles");
        let instrs = program["instructions"].as_array().unwrap();
        assert!(
            instrs.iter().all(|i| i.get("src").is_none()),
            "wire leaked src"
        );

        let result = render_mapped_req(&program, json!({ "name": "Ada" }));
        assert_eq!(result["output"], "Hi Ada!");
        assert!(result["segments"].as_array().unwrap().is_empty());
    }

    #[test]
    fn block_output_is_attributed_through_recursion() {
        let program = compile_mapped("{{#each xs}}{{this}}{{/each}}", &[]);
        let result = render_mapped_req(&program, json!({ "xs": ["a", "b", "c"] }));
        assert_eq!(result["output"], "abc");
        // Each iteration's emit records a global-offset segment tiling the output.
        let segments = assert_tiles(&result);
        assert_eq!(segments.len(), 3);
        assert!(segments.iter().all(|s| s["file"] == "main"));
    }
}
