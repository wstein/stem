// SPDX-License-Identifier: Apache-2.0
//
// PoC native renderer for Stem portable bytecode (`stem-bc/v1`).
//
// `handle/1` takes a JSON request — `{"program": <Stem.Bytecode.to_wire/1>,
// "data": <assigns>, "transformers": [<group names>]}`, or `{"batch": [...]}` —
// and returns the rendered output. The optional `transformers` list names the
// enabled capability groups (Minimum is always on); it defaults to Minimum-only.
// This JSON path is the Elixir conformance seam: the `stem_native` bin wraps it
// for WASI stdin/stdout. In-process Rust uses the typed API ([`compile`] /
// [`Program::render`]); the browser uses the wasm-bindgen `compile`/`render`
// exports (`wasm32-unknown-unknown`, no WASI). All three share one render core.
//
// It reimplements, natively, the subset of the Stem runtime the conformance
// corpus exercises — assign/path resolution, block helpers, the index/key/this
// scoping, HTML/JSON/XML/none escaping, and a transformer stdlib — so its output
// can be checked byte-for-byte against the BEAM reference.

use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::HashMap;

// The Stem compiler lives in its own crate so the compile-time macros can use it
// without pulling in the renderer. Aliased to `compile` so call sites read the
// same as when it was an internal module.
use stem_compile as compile;

pub use compile::{compile_to_wire_string, CompileError};

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

/// A compiled Stem template: the renderable unit produced by [`compile`]. Opaque
/// — its bytecode is an internal detail. Render it with [`Program::render`].
#[derive(Debug, Deserialize)]
pub struct Program {
    instructions: Vec<Instr>,
}

#[derive(Debug, Deserialize)]
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

#[derive(Debug, Deserialize)]
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
        // Keyword arguments, keyed by name. Built-in transformers take none, so
        // the pre-check refuses a built-in call that carries any; a host
        // transformer (the custom API) receives them evaluated. Optional on the
        // wire so older programs without the field still deserialize.
        #[serde(default)]
        kwargs: HashMap<String, Op>,
    },
}

// Provenance attached to a `text`/`emit` instruction by the span-annotated
// compiler: which template/partial it came from and (for `emit`) the byte span
// of the originating `{{ }}` tag in that file's source.
#[derive(Debug, Deserialize)]
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
    transform: TransformerResolver,
    groups: u8,
}

/// What a Rust embedder supplies to extend the engine: custom transformers.
/// Inert by default (the C ABI / browser use [`Host::default`]), so the shipped
/// engine ships none — the analogue of the BEAM, whose `transformers:` binding
/// is the caller's business.
#[derive(Clone, Copy)]
pub struct Host {
    /// Resolves custom transformer calls. See [`TransformerResolver`].
    pub transform: TransformerResolver,
    /// The transformer names `transform` handles. Declared up front so the
    /// pre-check can admit them (and refuse genuinely unknown names) without
    /// invoking the resolver — mirroring the BEAM binding, which is an
    /// enumerable map of name to function.
    pub transformer_names: &'static [&'static str],
}

impl Default for Host {
    fn default() -> Self {
        Host {
            transform: no_transformers,
            transformer_names: &[],
        }
    }
}

/// Renders a JSON request with no host extensions: only built-in transformers
/// are available. This is the entry the C ABI (and thus the browser) uses.
pub fn handle(raw: &str) -> String {
    handle_with_host(raw, &Host::default())
}

/// Renders a JSON request with a full [`Host`]: custom transformers supplied by
/// the embedder.
///
/// Total: malformed input yields a distinguishable error string rather than a
/// panic or process exit. `{"batch": [{program, data}, ...]}` renders many
/// requests and returns a JSON array of outputs (used by the differential fuzz
/// harness). Otherwise a single `{program, data}` renders to a raw string.
pub fn handle_with_host(raw: &str, host: &Host) -> String {
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
                    .map(|input| render_input(input, host))
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
            Ok(input) if mapped => render_input_mapped(&input, host),
            Ok(input) => render_input(&input, host),
            Err(err) => format!("stem_native error: invalid request shape: {err}"),
        }
    }
}

// ── Idiomatic Rust API ───────────────────────────────────────────────────────
//
// The typed, `Result`-returning surface for in-process Rust hosts. The JSON
// `handle*` entries above are a thin wrapper over this same core (kept for the
// Elixir conformance harness and the C ABI); a drift-guard test asserts the two
// agree.

/// A capability group of built-in transformers, loaded via [`RenderOptions`].
/// Groups are ordered by risk: Default (always-on) < Format (value transforms)
/// < Transform (structural/iterative). `Eval` is separate — it enables dynamic
/// expression evaluation and must be opted into explicitly. Mirrors
/// `Stem.Transformers.groups/0`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Group {
    /// Dynamic template evaluation: compiles and renders a Stem *template*
    /// string stored in data (e.g. `"{{name | upcase}}"`). Separate from the
    /// risk taxonomy; off by default — never enable for untrusted templates or
    /// untrusted data, since the data string is rendered as a template (SSTI).
    Eval,
    /// Value transforms: case, trim, truncate, replace. Bounded by string length.
    Format,
    /// Structural transforms: map, filter, sort, group_by, flatten, split, …
    /// May iterate unboundedly.
    Transform,
    I18n,
    /// The Minimum + Format convenience bundle.
    Standard,
}

fn group_bit(group: Group) -> u8 {
    match group {
        Group::Eval => GROUP_EVAL,
        Group::Format => GROUP_FORMAT,
        Group::Transform => GROUP_TRANSFORM,
        Group::I18n => GROUP_I18N,
        Group::Standard => GROUP_MINIMUM | GROUP_FORMAT,
    }
}

/// Per-render configuration: which capability groups are loaded and which
/// [`Host`] extensions (custom transformers) are available. Minimum is always
/// on; everything else is opt-in, secure by default.
#[derive(Clone, Copy)]
pub struct RenderOptions {
    groups: u8,
    host: Host,
}

impl Default for RenderOptions {
    fn default() -> Self {
        RenderOptions {
            groups: GROUP_MINIMUM,
            host: Host::default(),
        }
    }
}

impl RenderOptions {
    /// Minimum-only, no host extensions — the secure default.
    pub fn new() -> Self {
        Self::default()
    }

    /// Load one capability group (chainable).
    pub fn with_group(mut self, group: Group) -> Self {
        self.groups |= group_bit(group);
        self
    }

    /// Load several capability groups (chainable).
    pub fn with_groups(mut self, groups: impl IntoIterator<Item = Group>) -> Self {
        for group in groups {
            self.groups |= group_bit(group);
        }
        self
    }

    /// Supply host custom transformers (chainable).
    pub fn with_host(mut self, host: Host) -> Self {
        self.host = host;
        self
    }
}

/// A render-time failure: an unloaded capability group, an unknown transformer,
/// a keyword-arg misuse, an unsupported escape mode, or an i18n call without a
/// host translator. Carries the human message; the JSON boundary prefixes it
/// with "stem_native error: ".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderError {
    pub message: String,
}

impl std::fmt::Display for RenderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for RenderError {}

/// Compiles template source to a [`Program`], with no partials.
pub fn compile(source: &str) -> Result<Program, CompileError> {
    compile_with_partials(source, &HashMap::new())
}

/// Compiles template source to a [`Program`], expanding `{{> name}}` partials
/// from the given `name -> source` map.
pub fn compile_with_partials(
    source: &str,
    partials: &HashMap<String, String>,
) -> Result<Program, CompileError> {
    let wire = compile::compile_to_wire(source, partials)?;
    Ok(serde_json::from_value(wire).expect("compiler always emits a valid wire program"))
}

impl Program {
    /// Renders the compiled template against `data` under `options`, resolving
    /// built-in transformers (gated by the loaded groups) and any host
    /// extensions. A construct the loaded capabilities do not permit is refused
    /// up front as a [`RenderError`] — never a panic, never partial output.
    pub fn render(&self, data: &Value, options: &RenderOptions) -> Result<String, RenderError> {
        let caps = Caps {
            groups: options.groups,
            host_names: options.host.transformer_names,
        };
        match check_instrs(&self.instructions, &caps) {
            Some(message) => Err(RenderError { message }),
            None => Ok(render(
                &self.instructions,
                &root_ctx(data, &options.host, options.groups),
            )),
        }
    }

    /// Reconstructs a [`Program`] from a wire bytecode string
    /// (`Stem.Bytecode.to_wire/1` JSON) — the path a compile-time macro or the
    /// Elixir bridge uses to hand the engine an already-compiled template.
    pub fn from_wire(wire: &str) -> Result<Program, RenderError> {
        serde_json::from_str(wire).map_err(|err| RenderError {
            message: format!("invalid wire program: {err}"),
        })
    }
}

// ── Browser interop (wasm-bindgen) ───────────────────────────────────────────
//
// The browser target exports `compile` and `render` through wasm-bindgen, taking
// and returning JS values directly (serde-wasm-bindgen converts JsValue ↔
// serde_json::Value) — no hand-rolled JSON-string marshalling through linear
// memory. The WASI conformance bin (`main.rs`) and the JSON `handle*` Elixir seam
// are unaffected; the browser ships no host transformers, as before.
#[cfg(all(target_arch = "wasm32", target_os = "unknown"))]
mod wasm {
    use crate::{
        check_instrs, parse_groups, render_mapped, root_ctx, Caps, Host, Program, RenderOptions,
    };
    use serde::Serialize;
    use serde_json::Value;
    use std::collections::HashMap;
    use wasm_bindgen::prelude::*;

    // Serialize to a JS value with objects (not ES Maps) and plain numbers, so
    // the playground can walk `program.instructions` and read `error.message`.
    fn to_js(value: &impl Serialize) -> Result<JsValue, JsValue> {
        Ok(value.serialize(&serde_wasm_bindgen::Serializer::json_compatible())?)
    }

    /// Compiles template source (plus an optional `{name: source}` partials map)
    /// to a wire program, returned as a JS value. With `map`, the program carries
    /// `src` provenance for the source-map view. Throws `{message, start, end}`
    /// on a compile error so the editor can underline the span.
    #[wasm_bindgen]
    pub fn compile(source: &str, partials: JsValue, map: bool) -> Result<JsValue, JsValue> {
        let partials: HashMap<String, String> =
            serde_wasm_bindgen::from_value(partials).unwrap_or_default();
        let compiled = if map {
            crate::compile::compile_to_wire_with_spans(source, &partials)
        } else {
            crate::compile::compile_to_wire(source, &partials)
        };
        match compiled {
            Ok(wire) => to_js(&wire),
            Err(err) => Err(to_js(&serde_json::json!({
                "message": err.message, "start": err.start, "end": err.end,
            }))?),
        }
    }

    /// Renders a wire `program` against `data` with the named capability
    /// `groups`. With `map`, returns `{ output, segments }` (the source map);
    /// otherwise the output string. A refusal surfaces as a `stem_native error:`
    /// string in the output, the sentinel the playground already detects.
    #[wasm_bindgen]
    pub fn render(
        program: JsValue,
        data: JsValue,
        groups: JsValue,
        map: bool,
    ) -> Result<JsValue, JsValue> {
        let program: Program = serde_wasm_bindgen::from_value(program)
            .map_err(|err| JsValue::from_str(&format!("invalid program: {err}")))?;
        let data: Value = serde_wasm_bindgen::from_value(data).unwrap_or(Value::Null);
        let groups: Vec<String> = serde_wasm_bindgen::from_value(groups).unwrap_or_default();
        let options = RenderOptions {
            groups: parse_groups(&groups),
            host: Host::default(),
        };

        if map {
            let caps = Caps {
                groups: options.groups,
                host_names: &[],
            };
            let (output, segments) = match check_instrs(&program.instructions, &caps) {
                Some(message) => (format!("stem_native error: {message}"), Vec::new()),
                None => render_mapped(
                    &program.instructions,
                    &root_ctx(&data, &options.host, options.groups),
                ),
            };
            to_js(&serde_json::json!({ "output": output, "segments": segments }))
        } else {
            let output = match program.render(&data, &options) {
                Ok(out) => out,
                Err(err) => format!("stem_native error: {}", err.message),
            };
            Ok(JsValue::from_str(&output))
        }
    }
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

fn root_ctx(data: &Value, host: &Host, groups: u8) -> Ctx {
    Ctx {
        root: data.clone(),
        this: Value::Null,
        index: 0,
        key: Value::Null,
        in_each: false,
        locals: HashMap::new(),
        transform: host.transform,
        groups,
    }
}

// The JSON-boundary render: drive the typed [`Program::render`] core, and on a
// refusal format the engine's "stem_native error: " sentinel the Elixir bridge
// and C ABI expect. (Refusing up front — never panicking, never emitting partial
// output — turns an input-triggered abort in the WASM build into a message.)
fn render_input(input: &Input, host: &Host) -> String {
    let options = RenderOptions {
        groups: parse_groups(&input.transformers),
        host: *host,
    };
    match input.program.render(&input.data, &options) {
        Ok(output) => output,
        Err(error) => format!("stem_native error: {}", error.message),
    }
}

// Render returning a JSON string `{"output", "segments"}`: the output plus a
// source map tiling it (see `render_mapped`). Used by the playground's mapped
// render path; the segment list is empty unless the program carries `src`
// provenance (compiled with `map: true`).
fn render_input_mapped(input: &Input, host: &Host) -> String {
    let caps = Caps {
        groups: parse_groups(&input.transformers),
        host_names: host.transformer_names,
    };
    let (output, segments) = match check_instrs(&input.program.instructions, &caps) {
        Some(message) => (format!("stem_native error: {message}"), Vec::new()),
        None => render_mapped(
            &input.program.instructions,
            &root_ctx(&input.data, host, parse_groups(&input.transformers)),
        ),
    };
    serde_json::to_string(&json!({ "output": output, "segments": segments })).unwrap_or_default()
}

// Escape modes the native renderer implements with byte-parity to the BEAM.
const SUPPORTED_ESCAPES: &[&str] = &["none", "html", "xml", "json"];

// ── Capability groups (mirror Stem.Transformers.groups/0) ───────────────────
//
// Minimum is the always-on floor; Format, Transform, and I18n are opt-in via
// the request "transformers" list. Inspect ops (read-only, O(n) bounded) are
// merged into Minimum — they need no opt-in. A built-in transformer is
// callable only when the group that provides it is enabled, so an untrusted
// template can never reach a more powerful transformer than the caller loaded —
// the same secure-by-default model as the BEAM dispatcher.
const GROUP_MINIMUM: u8 = 1 << 0;
const GROUP_FORMAT: u8 = 1 << 2;
const GROUP_TRANSFORM: u8 = 1 << 3;
const GROUP_I18N: u8 = 1 << 4;
const GROUP_EVAL: u8 = 1 << 5;

// Resolve the enabled-group set from the request's group names. Minimum is
// always included; unknown names are ignored. Legacy names ("strings",
// "collections", "predicates", "inspect") are accepted as aliases for backward
// compatibility with stored URL state.
fn parse_groups(names: &[String]) -> u8 {
    let mut set = GROUP_MINIMUM;
    for name in names {
        set |= match name.as_str() {
            "minimum" | "inspect" | "predicates" => GROUP_MINIMUM,
            "format" | "strings" => GROUP_FORMAT,
            "transform" | "collections" => GROUP_TRANSFORM,
            "i18n" => GROUP_I18N,
            "standard" => GROUP_MINIMUM | GROUP_FORMAT,
            "eval" => GROUP_EVAL,
            _ => 0,
        };
    }
    set
}

// The capability group that provides a built-in transformer, or `None` if the
// name is not a native built-in. Inspect ops (read-only, O(n)) are part of
// the default (minimum) group; format and transform are opt-in. Kept in sync
// with the match arms in `call`.
fn builtin_groups(name: &str) -> Option<u8> {
    Some(match name {
        // default — always on: escaping, encoding, read-only inspect ops
        "escape_html" | "escape_json" | "json" | "inspect" | "default" | "join" | "log"
        | "first" | "lookup" | "starts_with" | "ends_with" | "contains" | "empty?" | "present?"
        | "len" | "last" => GROUP_MINIMUM,
        // format — atomic value transforms, bounded by string length
        "trim" | "upcase" | "downcase" | "capitalize" | "truncate" | "replace" => GROUP_FORMAT,
        // transform — structural/iterative, may loop, potential DoS
        "split" | "drop" | "reverse" | "slice" | "take" | "map" | "filter" | "sort" | "sort_by"
        | "group_by" | "compact" | "uniq" | "flatten" => GROUP_TRANSFORM,
        // eval — dynamic expression evaluation, separate from risk taxonomy
        "eval" => GROUP_EVAL,
        _ => return None,
    })
}

// The inclusive positional-argument arity `(min, max)` of each built-in. The
// piped/subject value is the first positional, so `title | replace "a" "b"`
// carries three positionals. Mirrors the BEAM `Stem.Transformers.builtin_arity/1`
// table; the two are kept in lockstep so an arity mismatch reports the same
// message on both backends. Returns `None` for non-built-ins (host transformers
// declare their own arity).
fn builtin_arity(name: &str) -> Option<(usize, usize)> {
    Some(match name {
        "replace" | "slice" => (3, 3),
        "default" | "lookup" | "starts_with" | "ends_with" | "take" | "drop" | "map"
        | "sort_by" | "group_by" | "contains" => (2, 2),
        "truncate" => (2, 3),
        "join" | "split" | "filter" => (1, 2),
        "escape_html" | "escape_json" | "json" | "inspect" | "first" | "last" | "len"
        | "empty?" | "present?" | "upcase" | "downcase" | "trim" | "capitalize" | "reverse"
        | "sort" | "compact" | "uniq" | "flatten" | "eval" => (1, 1),
        _ => return None,
    })
}

// The shared arity-mismatch message, byte-identical to the BEAM backend.
fn arity_error(name: &str, min: usize, max: usize, got: usize) -> String {
    let expected = if min == max {
        format!("{min} argument{}", if min == 1 { "" } else { "s" })
    } else {
        format!("{min} to {max} arguments")
    };
    format!("transformer '{name}' takes {expected}, got {got}")
}

// Transformer names the BEAM delegates to a host translator (the i18n group).
// They have no native built-in, so they are usable only when a host supplies
// them through the [`Host::transform`] resolver.
fn is_i18n_transformer(name: &str) -> bool {
    matches!(name, "t" | "translate")
}

// Group names in a bitset, joined with " or " for the unloaded-group message.
fn group_phrase(set: u8) -> String {
    [
        (GROUP_MINIMUM, "default"),
        (GROUP_FORMAT, "format"),
        (GROUP_TRANSFORM, "transform"),
        (GROUP_I18N, "i18n"),
        (GROUP_EVAL, "eval"),
    ]
    .iter()
    .filter(|(bit, _)| set & bit != 0)
    .map(|(_, name)| *name)
    .collect::<Vec<_>>()
    .join(" or ")
}

// The capability state a program is checked against: the enabled built-in
// groups and the transformer names the host resolver handles.
struct Caps<'a> {
    groups: u8,
    host_names: &'a [&'a str],
}

// Walk a program for the first construct the native core cannot render with
// byte-parity, or the first transformer call the caller has not enabled,
// returning a bare message (no source span: the render input carries the
// compiled program, not the original template). The JSON boundary prefixes
// these with "stem_native error: "; the typed [`Program::render`] surfaces them
// in a [`RenderError`] verbatim.
fn check_instrs(instrs: &[Instr], caps: &Caps) -> Option<String> {
    instrs.iter().find_map(|instr| check_instr(instr, caps))
}

fn check_instr(instr: &Instr, caps: &Caps) -> Option<String> {
    match instr {
        Instr::Text { .. } => None,
        Instr::Emit { value, escape, .. } => {
            if !SUPPORTED_ESCAPES.contains(&escape.as_str()) {
                Some(format!("unsupported escape mode '{escape}'"))
            } else {
                check_op(value, caps)
            }
        }
        Instr::If {
            cond,
            then,
            otherwise,
        } => check_op(cond, caps)
            .or_else(|| check_instrs(then, caps))
            .or_else(|| check_instrs(otherwise, caps)),
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
        } => check_op(subject, caps)
            .or_else(|| check_instrs(body, caps))
            .or_else(|| check_instrs(otherwise, caps)),
        Instr::Scope { base, hash, body } => check_op(base, caps)
            .or_else(|| hash.values().find_map(|op| check_op(op, caps)))
            .or_else(|| check_instrs(body, caps)),
    }
}

fn check_op(op: &Op, caps: &Caps) -> Option<String> {
    match op {
        Op::Call { name, args, kwargs } => {
            if caps.host_names.contains(&name.as_str()) {
                // A host transformer: enabled because the embedder supplied it
                // (the binding is the enablement, as on the BEAM). It may take
                // keyword args, so validate both arg lists for nested calls.
                args.iter()
                    .chain(kwargs.values())
                    .find_map(|arg| check_op(arg, caps))
            } else if let Some(provides) = builtin_groups(name) {
                if !kwargs.is_empty() {
                    Some(format!(
                        "keyword arguments to transformer '{name}' are not supported"
                    ))
                } else if provides & caps.groups == 0 {
                    Some(format!(
                        "transformer '{name}' requires the {} capability group, \
                         which is not enabled. Add it to the request \"transformers\" list.",
                        group_phrase(provides)
                    ))
                } else if let Some((min, max)) = builtin_arity(name) {
                    if args.len() < min || args.len() > max {
                        Some(arity_error(name, min, max, args.len()))
                    } else {
                        args.iter().find_map(|arg| check_op(arg, caps))
                    }
                } else {
                    args.iter().find_map(|arg| check_op(arg, caps))
                }
            } else if is_i18n_transformer(name) {
                // i18n is host-delegated: it needs both the group loaded and a
                // host translator. Either gap is knowable here, so refuse up
                // front rather than rendering to null.
                if caps.groups & GROUP_I18N == 0 {
                    Some(format!(
                        "transformer '{name}' requires the i18n capability group, \
                         which is not enabled. Add it to the request \"transformers\" list."
                    ))
                } else {
                    Some(format!(
                        "transformer '{name}' requires a host translator; \
                         supply one through the transformer resolver."
                    ))
                }
            } else {
                Some(format!("unknown transformer '{name}'"))
            }
        }
        Op::Get { base, .. } => check_op(base, caps),
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
        transform: ctx.transform,
        groups: ctx.groups,
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
        transform: ctx.transform,
        groups: ctx.groups,
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
        transform: ctx.transform,
        groups: ctx.groups,
    }
}

fn eval(op: &Op, ctx: &Ctx) -> Value {
    match op {
        Op::Lit { value } => value.clone(),
        Op::Assign { name } => ctx.root.get(name).cloned().unwrap_or(Value::Null),
        Op::Local { name } => ctx.locals.get(name).cloned().unwrap_or(Value::Null),
        Op::Assigns => ctx.root.clone(),
        Op::This => ctx.this.clone(),
        Op::Index => Value::from(ctx.index),
        Op::Index1 => Value::from(ctx.index + 1),
        Op::Key => ctx.key.clone(),
        Op::Get { base, segments } => {
            let mut value = eval(base, ctx);
            for segment in segments {
                value = get_field(&value, segment);
            }
            value
        }
        // A host transformer (consulted first, so it can override a built-in,
        // matching the BEAM precedence: caller binding → built-ins) takes both
        // positional and keyword arguments. Built-ins take positional only;
        // `check_op` has already refused any built-in call carrying kwargs.
        Op::Call { name, args, kwargs } => {
            let positional: Vec<Value> = args.iter().map(|a| eval(a, ctx)).collect();
            let keyword: Map<String, Value> = kwargs
                .iter()
                .map(|(key, op)| (key.clone(), eval(op, ctx)))
                .collect();

            // eval: treat the argument as a full Stem template string (it may
            // contain literal text and one or more `{{ … }}` tags), compile it,
            // and render against the current scope. The caller supplies the
            // braces — `"{{name | upcase}}"`, not `"name | upcase"`. GROUP_EVAL
            // is cleared in the sub-context to prevent recursive eval calls.
            if *name == "eval" && ctx.groups & GROUP_EVAL != 0 {
                let tmpl = positional.first().and_then(Value::as_str).unwrap_or("");
                if let Ok(program) = compile_with_partials(tmpl, &HashMap::new()) {
                    let sub_groups = ctx.groups & !GROUP_EVAL;
                    let sub_caps = Caps {
                        groups: sub_groups,
                        host_names: &[],
                    };
                    if check_instrs(&program.instructions, &sub_caps).is_none() {
                        let sub_ctx = Ctx {
                            groups: sub_groups,
                            ..clone_ctx(ctx)
                        };
                        return Value::String(render(&program.instructions, &sub_ctx));
                    }
                }
                return Value::Null;
            }

            let host_call = TransformerCall {
                name,
                args: &positional,
                kwargs: &keyword,
                assigns: &ctx.root,
                this: &ctx.this,
            };
            match (ctx.transform)(&host_call) {
                Some(value) => value,
                None => call(name, &positional),
            }
        }
    }
}

fn get_field(value: &Value, segment: &str) -> Value {
    match value {
        Value::Object(map) => map.get(segment).cloned().unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

// ── Per-host custom transformers ─────────────────────────────────────────────
//
// A transformer call the engine has no built-in for (or one the host wants to
// override) is dispatched to a host-supplied [`TransformerResolver`]. This is
// the native analogue of the BEAM `transformers:` binding: the embedder owns
// the function, the engine only routes the call. The resolver is consulted
// before the built-ins, so it can override them, matching the BEAM precedence.
//
// It powers the i18n group too: `t`/`translate` have no native built-in and are
// usable only when the host supplies them, mirroring the BEAM's configured
// translator. The engine ships **no** transformers beyond the built-ins; the
// resolver is inert by default ([`no_transformers`], used by [`handle`] and the
// C ABI), so a browser build has no host transformers.

/// One transformer invocation handed to a host resolver, mirroring the
/// `(args, %{assigns, this})` shape a BEAM transformer receives.
pub struct TransformerCall<'a> {
    /// The transformer name (e.g. `"t"`).
    pub name: &'a str,
    /// Positional arguments, already evaluated. The pipeline value, if any, is
    /// the first argument (the BEAM prepends it the same way).
    pub args: &'a [Value],
    /// Keyword arguments, already evaluated, keyed by name.
    pub kwargs: &'a Map<String, Value>,
    /// The current assigns (the render root), as the BEAM's `:assigns`.
    pub assigns: &'a Value,
    /// The current block item inside `{{#each}}`/`{{#with}}`, else null — the
    /// BEAM's `:this`.
    pub this: &'a Value,
}

/// Resolves a custom transformer call to its value, or `None` to fall through to
/// the engine's built-in for that name (so a host need only handle the names it
/// adds or overrides).
pub type TransformerResolver = fn(&TransformerCall) -> Option<Value>;

/// The default resolver: no custom transformers. Every call falls through to the
/// built-ins.
pub fn no_transformers(_call: &TransformerCall) -> Option<Value> {
    None
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
        Value::Number(n) => number_string(n),
        Value::String(s) => s.clone(),
        // Lists/maps are never emitted directly by the corpus; render as JSON.
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

// Render a JSON number as the BEAM's `String.Chars.to_string/1` does: integers
// verbatim, floats via the Erlang `:short` formatting reproduced by
// `format_float`.
fn number_string(n: &serde_json::Number) -> String {
    match n.as_f64() {
        Some(f) if n.is_f64() => format_float(f),
        _ => n.to_string(),
    }
}

// Format a float byte-for-byte like Erlang `:erlang.float_to_binary(f, [:short])`
// — the BEAM's float rendering. `shortest_digits` (Ryū) yields the same shortest
// round-trip digits the BEAM uses. Erlang's `:short` policy then chooses
// scientific notation when the magnitude reaches 2^53 (above which not every
// integer is representable, so a fixed integer form would mislead) or when
// scientific is strictly shorter than the fixed form, and decimal otherwise
// (ties to decimal). Both forms keep a decimal point with at least one
// fractional digit; the scientific exponent carries no `+` and no leading zeros.
fn format_float(f: f64) -> String {
    let (digits, exp) = shortest_digits(f.abs());
    let k = digits.len() as i32;

    let decimal = if exp >= 0 {
        if exp + 1 >= k {
            format!("{}{}.0", digits, "0".repeat((exp + 1 - k) as usize))
        } else {
            let point = (exp + 1) as usize;
            format!("{}.{}", &digits[..point], &digits[point..])
        }
    } else {
        format!("0.{}{}", "0".repeat((-exp - 1) as usize), digits)
    };

    let scientific = {
        let fraction = if digits.len() > 1 { &digits[1..] } else { "0" };
        format!("{}.{}e{}", &digits[..1], fraction, exp)
    };

    // 2^53 is the largest f64 below which every integer is exactly representable.
    const INTEGER_LIMIT: f64 = (1u64 << 53) as f64;
    let use_scientific = f.abs() >= INTEGER_LIMIT || scientific.len() < decimal.len();
    let chosen = if use_scientific { scientific } else { decimal };
    if f.is_sign_negative() {
        format!("-{chosen}")
    } else {
        chosen
    }
}

// The shortest round-trip significant digits of a non-negative finite float and
// the decimal exponent of its leading digit (value = d.ddd… × 10^exp). Uses the
// Ryū crate so the digits and tie-breaking match the BEAM's `:short` (also Ryū);
// Ryū's own notation is discarded — only the digits and exponent are taken.
fn shortest_digits(f: f64) -> (String, i32) {
    let mut buffer = ryu::Buffer::new();
    let formatted = buffer.format_finite(f);
    let (mantissa, extra_exp) = match formatted.split_once(['e', 'E']) {
        Some((mantissa, exp)) => (mantissa, exp.parse::<i32>().unwrap_or(0)),
        None => (formatted, 0),
    };
    let (int_part, frac_part) = mantissa.split_once('.').unwrap_or((mantissa, ""));
    let all: String = format!("{int_part}{frac_part}");
    match all.find(|c: char| c != '0') {
        // `f` is zero: a single "0" digit at exponent 0 renders as "0.0".
        None => ("0".to_string(), 0),
        Some(first) => {
            let last = all.rfind(|c: char| c != '0').unwrap();
            let digits = all[first..=last].to_string();
            let exp = (int_part.len() as i32 - 1) - first as i32 + extra_exp;
            (digits, exp)
        }
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

        "split" => {
            let s = to_string(&args[0]);
            let sep = args.get(1).map(to_string).unwrap_or_default();
            Value::Array(
                s.split(sep.as_str())
                    .map(|p| Value::String(p.to_string()))
                    .collect(),
            )
        }

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
        "json" => Value::from(json_encode(&args[0])),
        "inspect" => Value::from(inspect(&args[0])),
        // `log` renders to "" on the BEAM (its value is the side effect); the
        // native build keeps the output parity and leaves any logging to a host
        // transformer override. So a `{{ x | log }}` stage is a transparent ""
        // pass-through here.
        "log" => Value::from(""),

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

        // Inspect — read-only sequence / predicate ops
        "contains" => Value::from(contains(&args[0], &args[1])),
        "empty?" => Value::from(!present(&args[0])),
        "present?" => Value::from(present(&args[0])),
        "len" => match &args[0] {
            Value::String(s) => Value::from(s.chars().count() as i64),
            Value::Array(a) => Value::from(a.len() as i64),
            Value::Object(o) => Value::from(o.len() as i64),
            _ => Value::Null,
        },
        "last" => match &args[0] {
            Value::String(s) => Value::from(s.chars().last().map(String::from).unwrap_or_default()),
            other => enumerable(other).into_iter().last().unwrap_or(Value::Null),
        },

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

// Compact JSON, matching Elixir's `JSON.encode!/1` over the JSON value domain.
// serde_json sorts object keys (BTreeMap) and an Elixir ≤32-key string-keyed map
// iterates in the same term (byte) order, so the encodings agree; multi-key map
// order is not stable across backends (gap G5). Floats are formatted by
// `format_float` (Elixir `JSON.encode!` renders a float exactly like
// `float_to_binary(_, [:short])`), so they are encoded recursively here rather
// than via serde_json's float `Display`.
fn json_encode(value: &Value) -> String {
    match value {
        Value::Array(items) => {
            let inner = items.iter().map(json_encode).collect::<Vec<_>>().join(",");
            format!("[{inner}]")
        }
        Value::Object(map) => {
            let inner = map
                .iter()
                .map(|(key, value)| {
                    let key = serde_json::to_string(key).unwrap_or_default();
                    format!("{key}:{}", json_encode(value))
                })
                .collect::<Vec<_>>()
                .join(",");
            format!("{{{inner}}}")
        }
        Value::Number(n) => number_string(n),
        // Strings (with escaping), booleans, and null match serde_json exactly.
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

// Elixir's `Kernel.inspect/1` over the JSON value domain: `nil`, booleans and
// integers verbatim; floats via `format_float`; strings quoted with escapes;
// lists `[a, b]`; string-keyed maps `%{"k" => v}` in sorted-key order. (A map's
// keys print as quoted strings, so the atom-keyed maps the conformance harness
// builds from JSON are exercised only via scalars and lists — see gap G7.)
fn inspect(value: &Value) -> String {
    match value {
        Value::Null => "nil".to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => number_string(n),
        Value::String(s) => inspect_string(s),
        Value::Array(items) => {
            let inner = items.iter().map(inspect).collect::<Vec<_>>().join(", ");
            format!("[{inner}]")
        }
        Value::Object(map) => {
            let inner = map
                .iter()
                .map(|(key, value)| format!("{} => {}", inspect_string(key), inspect(value)))
                .collect::<Vec<_>>()
                .join(", ");
            format!("%{{{inner}}}")
        }
    }
}

// A string as Elixir's `inspect/1` renders it: double-quoted, with backslash,
// quote, and the common control characters escaped.
fn inspect_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => out.push(ch),
        }
    }
    out.push('"');
    out
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
mod typed_api_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn compile_and_render_round_trip() {
        let program = compile("Hello {{ name }}!").unwrap();
        let out = program
            .render(&json!({ "name": "Ada" }), &RenderOptions::new())
            .unwrap();
        assert_eq!(out, "Hello Ada!");
    }

    #[test]
    fn compile_error_is_typed() {
        let err = compile("{{ unterminated").unwrap_err();
        // CompileError is a real error with a span and a Display impl.
        assert!(err.end >= err.start);
        assert!(!format!("{err}").is_empty());
    }

    #[test]
    fn loading_a_group_enables_its_transformers() {
        let program = compile("{{ name | upcase }}").unwrap();
        let data = json!({ "name": "ada" });

        // Minimum-only: refused, as a typed RenderError.
        let err = program.render(&data, &RenderOptions::new()).unwrap_err();
        assert!(err.message.contains("requires the format capability group"));

        // Format loaded: renders.
        let opts = RenderOptions::new().with_group(Group::Format);
        assert_eq!(program.render(&data, &opts).unwrap(), "ADA");
    }

    #[test]
    fn host_transformer_via_options() {
        fn shout(call: &TransformerCall) -> Option<Value> {
            Some(Value::from(format!(
                "{}!",
                call.args.first().and_then(Value::as_str).unwrap_or("")
            )))
        }
        let program = compile("{{ name | shout }}").unwrap();
        let opts = RenderOptions::new().with_host(Host {
            transform: shout,
            transformer_names: &["shout"],
        });
        assert_eq!(
            program.render(&json!({ "name": "ada" }), &opts).unwrap(),
            "ada!"
        );
    }

    #[test]
    fn from_wire_reconstructs_a_program() {
        let wire = r#"{"version":"stem-bc/v1","instructions":[
            {"t":"emit","escape":"html","value":{"t":"assign","name":"x"}}]}"#;
        let program = Program::from_wire(wire).unwrap();
        assert_eq!(
            program
                .render(&json!({ "x": "ok" }), &RenderOptions::new())
                .unwrap(),
            "ok"
        );
    }

    // Drift guard: the typed core and the JSON `handle*` boundary must agree, so
    // the Elixir seam can never diverge from the Rust API.
    #[test]
    fn typed_and_json_paths_agree() {
        let source = "{{ tags | sort | join \", \" }} / {{ name | upcase }}";
        let data = json!({ "tags": ["b", "a"], "name": "ada" });
        let program = compile(source).unwrap();

        let typed = program
            .render(
                &data,
                &RenderOptions::new().with_groups([Group::Format, Group::Transform]),
            )
            .unwrap();

        // The JSON path takes the wire program directly (its `version` field is
        // ignored on deserialize).
        let wire = compile::compile_to_wire(source, &compile::Partials::new()).unwrap();
        let request = json!({
            "program": wire,
            "data": data,
            "transformers": ["strings", "collections"]
        });
        let json_out = handle(&request.to_string());

        assert_eq!(typed, json_out);
        assert_eq!(typed, "a, b / ADA");
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

    // Build an `{{ subject | name args... }}` emit program (subject + literal args).
    fn call_program(name: &str, subject: &str, args: Vec<Value>) -> Value {
        let mut call_args = vec![json!({ "t": "assign", "name": subject })];
        call_args.extend(args.into_iter().map(|v| json!({ "t": "lit", "value": v })));
        json!([{
            "t": "emit",
            "value": { "t": "call", "name": name, "args": call_args, "kwargs": {} },
            "escape": "html"
        }])
    }

    #[test]
    fn arity_mismatch_is_a_structured_error_not_a_panic() {
        let data = json!({ "title": "hello world" });

        // Too few args (the former `unreachable` panic): a clean, message-bearing
        // error. The test completing at all proves there is no panic.
        assert_eq!(
            render_groups(
                call_program("replace", "title", vec![json!("x")]),
                data.clone(),
                &["format"],
            ),
            "stem_native error: transformer 'replace' takes 3 arguments, got 2"
        );
        // Too many args (formerly silently dropped) is also refused.
        assert_eq!(
            render_groups(
                call_program("upcase", "title", vec![json!("extra")]),
                data.clone(),
                &["format"],
            ),
            "stem_native error: transformer 'upcase' takes 1 argument, got 2"
        );
        // Range boundaries remain valid (regression against over-tightening).
        assert_eq!(
            render_groups(
                call_program("truncate", "title", vec![json!(5)]),
                data.clone(),
                &["format"],
            ),
            "hello"
        );
        assert_eq!(
            render_groups(
                call_program("truncate", "title", vec![json!(5), json!("…")]),
                data.clone(),
                &["format"],
            ),
            "hell…"
        );
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
            &["format"],
        );
        assert_eq!(out, "HI");
    }

    #[test]
    fn transformer_in_an_unloaded_group_is_refused_before_render() {
        // Minimum-only: `upcase` (Format group) is gated off and refused up front.
        let out = render(upcase_program(), json!({ "x": "hi" }));
        assert!(
            out.contains("requires the format capability group"),
            "got: {out}"
        );
    }

    #[test]
    fn transformer_renders_once_its_group_is_loaded() {
        assert_eq!(
            render_groups(upcase_program(), json!({ "x": "hi" }), &["format"]),
            "HI"
        );
    }

    #[test]
    fn standard_bundle_loads_format() {
        // "standard" is the Minimum+Inspect+Format convenience bundle.
        assert_eq!(
            render_groups(upcase_program(), json!({ "x": "hi" }), &["standard"]),
            "HI"
        );
    }

    #[test]
    fn transform_group_is_gated_independently_of_format() {
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

        // Format loaded but not Transform: `sort` is still refused.
        let refused = render_groups(program.clone(), data.clone(), &["format"]);
        assert!(
            refused.contains("transformer 'sort' requires the transform capability group"),
            "got: {refused}"
        );

        // Transform loaded: it renders. (`join` is Minimum, always on.)
        assert_eq!(render_groups(program, data, &["transform"]), "a,b,c");
    }

    #[test]
    fn inspect_ops_are_in_the_default_group() {
        // `first`, `lookup`, and friends are merged into the default (minimum)
        // group — they need no opt-in and are never refused.
        let program = json!([{
            "t": "emit",
            "value": { "t": "call", "name": "first", "args": [{ "t": "assign", "name": "xs" }], "kwargs": {} },
            "escape": "html"
        }]);
        let data = json!({ "xs": ["a", "b"] });
        // Works with minimum-only (no extra groups):
        assert_eq!(render_groups(program.clone(), data.clone(), &[]), "a");
        // "inspect" still accepted as a backward-compat alias:
        assert_eq!(render_groups(program, data, &["inspect"]), "a");
    }

    #[test]
    fn split_requires_transform_group() {
        let program = json!([{
            "t": "emit",
            "value": {
                "t": "call", "name": "join",
                "args": [
                    { "t": "call", "name": "split",
                      "args": [{ "t": "assign", "name": "s" }, { "t": "lit", "value": "," }],
                      "kwargs": {} },
                    { "t": "lit", "value": "|" }
                ],
                "kwargs": {}
            },
            "escape": "html"
        }]);
        let data = json!({ "s": "a,b,c" });
        let refused = render(program.clone(), data.clone());
        assert!(
            refused.contains("requires the transform capability group"),
            "got: {refused}"
        );
        assert_eq!(render_groups(program, data, &["transform"]), "a|b|c");
    }

    #[test]
    fn eval_requires_eval_group() {
        // expr contains a full Stem template string (tags + optional literal text)
        let program = json!([{
            "t": "emit",
            "value": {
                "t": "call", "name": "eval",
                "args": [{ "t": "assign", "name": "expr" }],
                "kwargs": {}
            },
            "escape": "html"
        }]);
        let data = json!({ "name": "world", "expr": "{{name}}" });
        let refused = render(program.clone(), data.clone());
        assert!(
            refused.contains("requires the eval capability group"),
            "got: {refused}"
        );
        assert_eq!(render_groups(program, data, &["eval"]), "world");
    }

    #[test]
    fn eval_renders_template_against_current_scope() {
        // eval renders its argument as a full template against the current scope.
        let program = json!([{
            "t": "emit",
            "value": {
                "t": "call", "name": "eval",
                "args": [{ "t": "assign", "name": "expr" }],
                "kwargs": {}
            },
            "escape": "html"
        }]);
        // A single tag.
        assert_eq!(
            render_groups(
                program.clone(),
                json!({ "greeting": "Hello!", "expr": "{{greeting}}" }),
                &["eval"],
            ),
            "Hello!"
        );
        // Literal text around a tag is preserved (full template, not just an expr).
        assert_eq!(
            render_groups(
                program.clone(),
                json!({ "name": "ada", "expr": "Hi {{name}}!" }),
                &["eval"],
            ),
            "Hi ada!"
        );
        // Pipelines work when the required group is also loaded.
        assert_eq!(
            render_groups(
                program,
                json!({ "name": "ada", "expr": "{{name | upcase}}" }),
                &["eval", "format"],
            ),
            "ADA"
        );
    }

    #[test]
    fn eval_does_not_recurse() {
        // eval clears GROUP_EVAL in sub-renders; an inner eval is refused.
        let program = json!([{
            "t": "emit",
            "value": {
                "t": "call", "name": "eval",
                "args": [{ "t": "assign", "name": "expr" }],
                "kwargs": {}
            },
            "escape": "html"
        }]);
        let out = render_groups(
            program,
            json!({ "name": "x", "expr": "{{name | eval}}" }),
            &["eval"],
        );
        // Inner eval is refused → null → empty output.
        assert_eq!(out, "");
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

    #[test]
    fn log_is_a_transparent_empty_pass_through() {
        let out = render(
            json!([{
                "t": "emit",
                "value": { "t": "call", "name": "log", "args": [{ "t": "assign", "name": "x" }], "kwargs": {} },
                "escape": "html"
            }]),
            json!({ "x": "noisy" }),
        );
        assert_eq!(out, "");
    }
}

#[cfg(test)]
mod host_transformer_tests {
    use super::*;
    use serde_json::json;

    // A demo host transformer set, the embedder's analogue of a BEAM
    // `transformers:` binding. Lives in the test, never the engine.
    fn demo(call: &TransformerCall) -> Option<Value> {
        match call.name {
            // A brand-new custom transformer.
            "shout" => Some(Value::from(format!(
                "{}!",
                to_string(&call.args[0]).to_uppercase()
            ))),
            // Overrides the built-in `upcase`, to prove host precedence.
            "upcase" => Some(Value::from(format!("<{}>", to_string(&call.args[0])))),
            // A fake i18n translator: interpolates the `name` keyword binding.
            "t" | "translate" => {
                let msgid = to_string(&call.args[0]);
                let name = call.kwargs.get("name").map(to_string).unwrap_or_default();
                let text = match msgid.as_str() {
                    "greeting" => format!("Hello, {name}!"),
                    other => other.to_string(),
                };
                Some(Value::from(text))
            }
            _ => None,
        }
    }

    const WITH_I18N: &[&str] = &["shout", "upcase", "t", "translate"];
    const WITHOUT_I18N: &[&str] = &["shout", "upcase"];

    fn render_host(program: Value, data: Value, groups: &[&str], names: &'static [&str]) -> String {
        let request =
            json!({ "program": { "instructions": program }, "data": data, "transformers": groups });
        let host = Host {
            transform: demo,
            transformer_names: names,
        };
        handle_with_host(&request.to_string(), &host)
    }

    fn call_program(name: &str, arg: &str) -> Value {
        json!([{
            "t": "emit",
            "value": { "t": "call", "name": name, "args": [{ "t": "assign", "name": arg }], "kwargs": {} },
            "escape": "none"
        }])
    }

    #[test]
    fn custom_transformer_is_dispatched_to_the_host() {
        // `shout` is not a built-in; the host provides it, so it is admitted and
        // dispatched even with only the Minimum floor loaded.
        let out = render_host(
            call_program("shout", "x"),
            json!({ "x": "hi" }),
            &[],
            WITHOUT_I18N,
        );
        assert_eq!(out, "HI!");
    }

    #[test]
    fn host_transformer_overrides_a_builtin() {
        // The resolver is consulted before the built-in, so `upcase` resolves to
        // the host's override rather than the native implementation — and the
        // host opting in enables it without loading the Strings group.
        let out = render_host(
            call_program("upcase", "x"),
            json!({ "x": "hi" }),
            &[],
            WITHOUT_I18N,
        );
        assert_eq!(out, "<hi>");
    }

    #[test]
    fn unprovided_custom_name_is_refused() {
        // The host does not declare `shout`, so it is genuinely unknown.
        let out = render_host(call_program("shout", "x"), json!({ "x": "hi" }), &[], &[]);
        assert!(out.contains("unknown transformer 'shout'"), "got: {out}");
    }

    #[test]
    fn i18n_translate_threads_keyword_bindings_through_the_host() {
        let program = json!([{
            "t": "emit",
            "value": {
                "t": "call", "name": "t",
                "args": [{ "t": "lit", "value": "greeting" }],
                "kwargs": { "name": { "t": "assign", "name": "user" } }
            },
            "escape": "none"
        }]);
        let out = render_host(program, json!({ "user": "Ada" }), &["i18n"], WITH_I18N);
        assert_eq!(out, "Hello, Ada!");
    }

    #[test]
    fn i18n_without_its_group_is_refused() {
        // No i18n group and the host does not declare `t`: the message points at
        // the missing group.
        let program = json!([{
            "t": "emit",
            "value": { "t": "call", "name": "t", "args": [{ "t": "lit", "value": "greeting" }], "kwargs": {} },
            "escape": "none"
        }]);
        let out = render_host(program, json!({}), &[], WITHOUT_I18N);
        assert!(
            out.contains("transformer 't' requires the i18n capability group"),
            "got: {out}"
        );
    }

    #[test]
    fn i18n_group_without_a_translator_is_refused() {
        // i18n loaded but no host translator declared: the message points at the
        // missing translator.
        let program = json!([{
            "t": "emit",
            "value": { "t": "call", "name": "t", "args": [{ "t": "lit", "value": "greeting" }], "kwargs": {} },
            "escape": "none"
        }]);
        let out = render_host(program, json!({}), &["i18n"], WITHOUT_I18N);
        assert!(
            out.contains("transformer 't' requires a host translator"),
            "got: {out}"
        );
    }
}

#[cfg(test)]
mod serialization_tests {
    use super::*;
    use serde_json::json;

    // Render `{{ x | name }}` with no escaping so the serializer output is
    // verbatim. `json`/`inspect` are Minimum, so the default groups suffice.
    fn render(name: &str, data: Value) -> String {
        let request = json!({
            "program": { "instructions": [{
                "t": "emit",
                "value": { "t": "call", "name": name, "args": [{ "t": "assign", "name": "x" }], "kwargs": {} },
                "escape": "none"
            }] },
            "data": data
        });
        handle(&request.to_string())
    }

    #[test]
    fn json_encodes_the_value_domain() {
        assert_eq!(render("json", json!({ "x": "hi" })), r#""hi""#);
        assert_eq!(render("json", json!({ "x": [1, 2, 3] })), "[1,2,3]");
        assert_eq!(render("json", json!({ "x": true })), "true");
        assert_eq!(render("json", json!({ "x": null })), "null");
        assert_eq!(render("json", json!({ "x": 42 })), "42");
    }

    #[test]
    fn json_sorts_object_keys() {
        // Native always sorts object keys (serde_json's BTreeMap). This is a
        // native behavioural guarantee, not cross-backend parity: the BEAM's
        // JSON.encode! preserves the map's internal order, so multi-key object
        // order is a documented divergence (gap G5) kept out of the corpus.
        assert_eq!(
            render("json", json!({ "x": { "b": 2, "a": 1 } })),
            r#"{"a":1,"b":2}"#
        );
    }

    #[test]
    fn inspect_matches_elixir_for_scalars_and_lists() {
        assert_eq!(render("inspect", json!({ "x": null })), "nil");
        assert_eq!(render("inspect", json!({ "x": true })), "true");
        assert_eq!(render("inspect", json!({ "x": 42 })), "42");
        assert_eq!(render("inspect", json!({ "x": "hi" })), r#""hi""#);
        assert_eq!(render("inspect", json!({ "x": [1, 2, 3] })), "[1, 2, 3]");
    }

    #[test]
    fn inspect_escapes_strings_and_renders_maps() {
        assert_eq!(render("inspect", json!({ "x": "a\"b" })), r#""a\"b""#);
        assert_eq!(render("inspect", json!({ "x": "a\nb" })), r#""a\nb""#);
        assert_eq!(
            render("inspect", json!({ "x": { "a": 1 } })),
            r#"%{"a" => 1}"#
        );
    }
}

#[cfg(test)]
mod float_tests {
    use super::*;

    // Reference pairs from `:erlang.float_to_binary(f, [:short])` on the BEAM.
    #[test]
    fn format_float_matches_the_beam_short_format() {
        let cases: &[(f64, &str)] = &[
            (0.0, "0.0"),
            (-0.0, "-0.0"),
            (1.0, "1.0"),
            (-1.0, "-1.0"),
            (0.5, "0.5"),
            (3.25, "3.25"),
            (10.0, "10.0"),
            (100.0, "100.0"),
            (0.0001, "0.0001"),
            (1.0e-5, "1.0e-5"),
            (1.23e-4, "1.23e-4"),
            (100000000.0, "1.0e8"),
            (1.5e10, "1.5e10"),
            (123456.789, "123456.789"),
            (9999999.0, "9999999.0"),
            (1000000.0, "1.0e6"),
            (1234567890.0, "1234567890.0"),
            (123456789000.0, "1.23456789e11"),
            (1.0e21, "1.0e21"),
            // The 2^53 notation boundary: just below stays fixed, at/above goes
            // scientific (the BEAM switches where integers stop being exact).
            (9006199254740992.0, "9006199254740992.0"),
            (9007199254740992.0, "9.007199254740992e15"),
            (9.492750501338764e15, "9.492750501338764e15"),
            (-9.91111824457831e15, "-9.91111824457831e15"),
        ];
        for (input, expected) in cases {
            assert_eq!(&format_float(*input), expected, "for {input}");
        }
    }

    // Every f64 round-trips through `format_float` back to the same bits.
    #[test]
    fn format_float_round_trips() {
        for f in [0.0, 1.0, -2.5, 12.5, 1.0e8, 1.0e-8, 6.022e23, 9.999999e6] {
            let parsed: f64 = format_float(f).parse().unwrap();
            assert_eq!(parsed.to_bits(), f.to_bits(), "round-trip for {f}");
        }
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
