// SPDX-License-Identifier: Apache-2.0
//
// PoC native renderer for Stem portable bytecode (`stem-bc/v1`).
//
// Reads a JSON object `{"program": <Stem.Bytecode.to_wire/1>, "data": <assigns>}`
// from stdin and writes the rendered template to stdout. Built for the host or
// for `wasm32-wasip1`; the same source runs unchanged under a WASI runtime.
//
// It reimplements, natively, the subset of the Stem runtime the conformance
// corpus exercises — assign/path resolution, block helpers, the index/key/this
// scoping, HTML/JSON/XML/none escaping, and a small transformer stdlib — so its
// output can be checked byte-for-byte against the BEAM reference.

use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::io::{Read, Write};

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
    This,
    Index,
    Index1,
    Key,
    Get {
        base: Box<Op>,
        segments: Vec<String>,
    },
    // Keyword args (the wire format's "kwargs") are only used by host
    // transformers, which the native PoC does not run, so they are ignored.
    Call {
        name: String,
        args: Vec<Op>,
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
}

fn main() {
    let mut raw = String::new();
    if std::io::stdin().read_to_string(&mut raw).is_err() {
        std::process::exit(1);
    }

    let request: Value = match serde_json::from_str(&raw) {
        Ok(value) => value,
        Err(err) => {
            eprintln!("stem_native: invalid input JSON: {err}");
            std::process::exit(1);
        }
    };

    // `{"batch": [{program, data}, ...]}` renders many requests and emits a JSON
    // array of outputs (used by the differential fuzz harness, one process per
    // batch). Otherwise a single `{program, data}` renders to a raw string.
    let output = if let Some(batch) = request.get("batch") {
        let inputs: Vec<Input> = decode(batch.clone());
        let outputs: Vec<String> = inputs.iter().map(render_input).collect();
        serde_json::to_string(&outputs).expect("serializable outputs")
    } else {
        render_input(&decode(request))
    };

    let mut stdout = std::io::stdout();
    let _ = stdout.write_all(output.as_bytes());
    let _ = stdout.flush();
}

fn decode<T: serde::de::DeserializeOwned>(value: Value) -> T {
    match serde_json::from_value(value) {
        Ok(decoded) => decoded,
        Err(err) => {
            eprintln!("stem_native: invalid request shape: {err}");
            std::process::exit(1);
        }
    }
}

fn render_input(input: &Input) -> String {
    let ctx = Ctx {
        root: input.data.clone(),
        this: Value::Null,
        index: 0,
        key: Value::Null,
        in_each: false,
        locals: HashMap::new(),
    };

    render(&input.program.instructions, &ctx)
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
    }
}

fn eval(op: &Op, ctx: &Ctx) -> Value {
    match op {
        Op::Lit { value } => value.clone(),
        Op::Assign { name } => ctx.root.get(name).cloned().unwrap_or(Value::Null),
        Op::Local { name } => ctx.locals.get(name).cloned().unwrap_or(Value::Null),
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
        Op::Call { name, args } => {
            let positional: Vec<Value> = args.iter().map(|a| eval(a, ctx)).collect();
            call(name, &positional)
        }
    }
}

fn get_field(value: &Value, segment: &str) -> Value {
    match value {
        Value::Object(map) => map.get(segment).cloned().unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

// ── Value helpers (mirror Stem.Runtime / String.Chars) ──────────────────────

fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(true),
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
        "html" => s
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
            .replace('\'', "&#39;"),
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
        other => panic!("stem_native: unsupported escape mode '{other}'"),
    }
}

// ── Transformer stdlib (mirror Stem.Transformers) ───────────────────────────
//
// Implements the built-in transformers that can match the BEAM byte-for-byte.
// Deliberately excluded (no byte-parity is possible, so they panic loudly and
// are kept out of the differential fuzzer):
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

        other => {
            panic!("stem_native: transformer '{other}' is not byte-parity capable in this PoC")
        }
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
