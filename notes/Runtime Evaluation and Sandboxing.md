---
id: 20260522100001
title: "Runtime Evaluation and Sandboxing"
aliases: []
tags: ['security', 'runtime', 'api']
---

#### What
`Stem.Unsafe.eval_string/3` and `Stem.Unsafe.eval_file/3` provide runtime template evaluation when the template source is not known at compile time. Both functions default to `allow_elixir_expressions: false`, which forbids arbitrary Elixir expressions inside `{{ }}` tags. When arbitrary Elixir expressions are truly needed and the template source is fully trusted, pass `allow_elixir_expressions: true` explicitly to opt in.

#### Why
Runtime evaluation of untrusted templates introduces Server-Side Template Injection (SSTI) risk. By placing these functions inside the `Stem.Unsafe` namespace and defaulting to `allow_elixir_expressions: false`, the API surface makes the risk visible during code review and forces an explicit, auditable opt-in for unrestricted execution. The false default also prevents accidental template-injection vulnerabilities from creeping in via trusted paths.

#### How
Use `Stem.Unsafe.eval_string(template, bindings)` for runtime templates. Pass `allow_elixir_expressions: true` only if the template source is authored and controlled exclusively by your own team:
```elixir
# Safe by default — structured Stem expressions only
Stem.Unsafe.eval_string("Hello {{name}}", assigns: [name: "Nina"])

# Explicit opt-in when arbitrary Elixir is required and source is trusted
Stem.Unsafe.eval_string("{{a + b}}", [assigns: [a: 1, b: 2]], allow_elixir_expressions: true)
```
Never pass end-user input as the template string to either function.

#### Links

- [[Execution Modes Overview]] - Comprehensive guide to restricted vs. unrestricted execution
- [[Compile-Time-Only Security Model]] - The preferred, safer compile-time alternative
- [[Project Configuration Defaults]] - The `.stem.config.json` settings that control default behavior
- [[Strict Model-View Separation and State Isolation]] - Why the sandboxing boundary matters
