---
id: 20260522100001
title: "Runtime Evaluation and Sandboxing"
aliases: []
tags: ['security', 'runtime', 'api']
---

## What

`Stem.Unsafe.eval_string/3` and `Stem.Unsafe.eval_file/3` provide runtime template evaluation when the template source is not known at compile time. Both functions accept only structured Stem syntax inside `{{ }}` tags — there is no arbitrary-Elixir escape hatch; an unrecognised expression raises `Stem.SyntaxError`.

## Why

Runtime evaluation of untrusted templates introduces Server-Side Template Injection (SSTI) risk. By placing these functions inside the `Stem.Unsafe` namespace, the API surface makes the risk visible during code review. Because templates are structured-only, the risk is limited to rendering an attacker-controlled *template*, not arbitrary code execution.

Additionally, Stem enforces **capability management** for transformers: only built-in minimum transformers are available by default, and complex operations require explicit opt-in via the `transformers:` map. This reduces SSTI attack surface by limiting what operations an attacker can chain together if they achieve template injection.

## How

Use `Stem.Unsafe.eval_string(template, bindings)` for runtime templates. By default, only the built-in minimum transformers are available (escaping, defaults, lookup). Load additional transformers by passing a `transformers:` map:

```elixir
# Safe by default — only built-ins available
Stem.Unsafe.eval_string("Hello {{name}}", assigns: [name: "Nina"])

# With string manipulation transformers
Stem.Unsafe.eval_string(
  "Hello {{name | upcase}}",
  assigns: [name: "nina"],
  transformers: Stem.Transformers.Strings.all()
)

# With data transformation — merge groups explicitly
Stem.Unsafe.eval_string(
  "{{items | map author | sort_by name}}",
  assigns: [items: books],
  transformers: Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
)
```

**Never pass end-user input as the template string** to either function. Only load transformer groups when their operations are actually needed.

### The `eval` transformer (native engine)

Distinct from `Stem.Unsafe.eval_string`, the native engine ships an `eval` *transformer* in its own opt-in `eval` capability group (off by default; the BEAM backend has no equivalent built-in). It takes a string drawn from **data** and renders it as a full Stem template against the current scope:

```text
{{expr | eval}}    # expr = "{{name | upcase}}", name = "ada"  →  ADA
```

The argument is a complete template, not a bare expression — the caller supplies the braces (`"{{name | upcase}}"`, not `"name | upcase"`; a string with no tags renders to itself). `eval` clears its own group in the sub-render, so it cannot recurse.

This widens the SSTI surface beyond the template author to the **data source**: because the rendered string comes from data, enabling `eval` over attacker-controlled data is itself a template-injection vector, even when the outer template is trusted. Enable the `eval` group only when *both* the template and the data feeding it are trusted; never for untrusted data (e.g. user-submitted fields, third-party API payloads). See [[Helper Capability Groups]] and the `eval` section of the transformers manual.

## Links

- [[Execution Modes Overview]] - Comprehensive guide to restricted vs. unrestricted execution
- [[Compile-Time-Only Security Model]] - The preferred, safer compile-time alternative
- [[Project Configuration Defaults]] - The `.stem.config.json` settings that control default behavior
- [[Strict Model-View Separation and State Isolation]] - Why the sandboxing boundary matters
