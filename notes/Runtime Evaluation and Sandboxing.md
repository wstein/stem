---
id: 20260522100001
title: "Runtime Evaluation and Sandboxing"
aliases: []
tags: ['security', 'runtime', 'api']
---

## What

`Stem.Unsafe.eval_string/3` and `Stem.Unsafe.eval_file/3` provide runtime template evaluation when the template source is not known at compile time. Both functions default to `allow_elixir_expressions: false`, which forbids arbitrary Elixir expressions inside `{{ }}` tags. When arbitrary Elixir expressions are truly needed and the template source is fully trusted, pass `allow_elixir_expressions: true` explicitly to opt in.

## Why

Runtime evaluation of untrusted templates introduces Server-Side Template Injection (SSTI) risk. By placing these functions inside the `Stem.Unsafe` namespace and defaulting to `allow_elixir_expressions: false`, the API surface makes the risk visible during code review and forces an explicit, auditable opt-in for unrestricted execution. The false default also prevents accidental template-injection vulnerabilities from creeping in via trusted paths.

Additionally, Stem enforces **capability management** for transformers: only built-in minimum transformers are available by default, and complex operations require explicit opt-in via the `transformers:` map. This reduces SSTI attack surface by limiting what operations an attacker can chain together if they achieve template injection.

## How

Use `Stem.Unsafe.eval_string(template, bindings)` for runtime templates. By default, only the built-in minimum transformers are available (escaping, defaults, lookup). Load additional transformers by passing a `transformers:` map:

```elixir
# Safe by default — only built-ins available
Stem.Unsafe.eval_string("Hello {{name}}", assigns: [name: "Nina"])

# With string manipulation transformers
Stem.Unsafe.eval_string(
  "Hello {{name |> upcase}}",
  assigns: [name: "nina"],
  transformers: Stem.Transformers.Strings.all()
)

# With data transformation — merge groups explicitly
Stem.Unsafe.eval_string(
  "{{items |> map(author) |> sort_by(name)}}",
  assigns: [items: books],
  transformers: Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
)

# Arbitrary Elixir — development only, when source is trusted
Stem.Unsafe.eval_string(
  "{{a + b}}",
  [assigns: [a: 1, b: 2]],
  allow_elixir_expressions: true
)
```

**Never pass end-user input as the template string** to either function. Only load transformer groups when their operations are actually needed.

## Links

- [[Execution Modes Overview]] - Comprehensive guide to restricted vs. unrestricted execution
- [[Compile-Time-Only Security Model]] - The preferred, safer compile-time alternative
- [[Project Configuration Defaults]] - The `.stem.config.json` settings that control default behavior
- [[Strict Model-View Separation and State Isolation]] - Why the sandboxing boundary matters
