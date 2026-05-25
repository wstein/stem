---
id: 20260523030741
aliases: []
tags: ['design', 'runtime', 'rationale', 'security']
---


A zero-arity function assign is auto-invoked during resolution and its result rendered — an ST4-style computed getter that stays declarative because the template can't pass it arguments.

## What

- `assigns = %{full_name: fn -> user.first <> " " <> user.last end}` makes `{{full_name}}` render the computed value. The template reads a property *name* the backend chose to back with a function; it cannot supply arguments.
- Resolution lives in `Stem.Runtime.resolve/1` (`is_function(v, 0)` → `v.()`, else identity) and is applied at: `fetch_assign!/3` (top-level assigns), the emit boundary, `Stem.Transformers.invoke/3` (transformer args), `Stem.Runtime.is_truthy/1` (block conditions), `Stem.Builtins.each_entries/1` (each collections), and the `{{#with}}` subject binding.
- This covers top-level and dotted-path **leaf** getters in every context — output, pipelines (`{{user.name | upcase}}`), `{{#if}}`/`{{#each}}`/`{{#with}}` — on both the compiled backend and the bytecode VM, since both share those primitives.
- Arity-0 only. The result is HTML-escaped like any other value.

## Why

- It is the ST4-faithful feature, and the line that preserves model-view separation ([[Strict Model-View Separation and State Isolation]]). An ST4 *getter* is a zero-argument, model-defined accessor; a Mustache *lambda* receives the section body/context and drives rendering — that's template-influenced logic, which breaks separation. Auto-invoking a 0-arity value is just a backend-authored assign with lazy/encapsulated evaluation: assigns are always authored by the backend (a template can't inject a function), so a getter is as safe as a precomputed assign.
- The guardrail that keeps it ST4 and not Mustache: arity 0 only. The moment a template could write `{{val arg}}` against a data function, logic would be back in the template.

## How

- Back a presentation property with a pure 0-arity function in Elixir assigns; reference it by name (`{{full_name}}` or `{{user.full_name}}`).
- Getters are an **Elixir-assigns convenience**: JSON/YAML can't carry functions. The native (Rust/WASM) path has its own equivalent (see *Native variant*); BEAM-closure getters stay out of the conformance corpus ([[Cross-Backend Conformance Spec]]).
- Keep getters pure (Stem can't enforce it) and at the value position: a getter that *returns* an object you then dot into mid-path (or a `this` bound to a function you traverse into) is not auto-invoked mid-traversal — return the final value instead.

## Native variant (per-host getters)

- A closure can't cross the wire, so the native engine offers a **host hook**: a field valued `{"$getter": "<name>"}` marks it computed, and the engine delegates to an embedder-supplied `GetterResolver` (`fn(name, parent) -> Value`), invoked with the field's **parent object** as "self".
- The engine ships **no** getters — getter logic is the embedder's, never the library's or the wire's. In `native/stem_native/src/lib.rs`, `resolve_getter` detects the single-key `$getter` marker at each assign/dotted-path step and calls the resolver; the default `no_getters` (used by `handle` and the C ABI, hence the browser) computes nothing, so the marker is **inert** unless a Rust embedder opts in via `handle_with_getters`. Result escaped like any value; unknown getter → null. No cross-backend parity (logic lives in the host) → out of the corpus; covered by native-only tests that inject a resolver and assert the default path stays inert.


## Links

- [[Strict Model-View Separation and State Isolation]] - The boundary getters must not cross.
- [[Handlebars Expression Resolution]] - How `{{name}}`/`{{a.b}}` resolve, where getters hook in.
- [[HTML Escaping Behavior]] - Getter results are escaped like any value.
- [[Cross-Backend Conformance Spec]] - Why BEAM-closure getters are out of the wire/native path.
- [[Native Backend Strategy]] - The wire/engine the per-host getter hook extends.
