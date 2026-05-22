---
id: 20260522100001
title: "Runtime Evaluation and Sandboxing"
aliases: []
tags: ['security', 'runtime', 'api']
---

#### What
`Stem.Unsafe.eval_string/3` and `Stem.Unsafe.eval_file/3` provide runtime template evaluation when the template source is not known at compile time. Both functions default to `mode: :safe`, which forbids arbitrary Elixir expressions inside `{{ }}` tags. When arbitrary Elixir expressions are truly needed and the template source is fully trusted, pass `mode: :permissive` explicitly to opt in.

#### Why
Runtime evaluation of untrusted templates introduces Server-Side Template Injection (SSTI) risk. By placing these functions inside the `Stem.Unsafe` namespace and defaulting to `:safe` mode, the API surface makes the risk visible during code review and forces an explicit, auditable opt-in for permissive execution. The `:safe` default also prevents accidental template-injection vulnerabilities from creeping in via trusted paths.

#### How
Use `Stem.Unsafe.eval_string(template, bindings)` for runtime templates. Pass `mode: :permissive` only if the template source is authored and controlled exclusively by your own team:
```elixir
# Safe by default — structured Stem expressions only
Stem.Unsafe.eval_string("Hello {{name}}", assigns: [name: "Nina"])

# Explicit opt-in when arbitrary Elixir is required and source is trusted
Stem.Unsafe.eval_string("{{a + b}}", [assigns: [a: 1, b: 2]], mode: :permissive)
```
Never pass end-user input as the template string to either function.

#### Links
- [[Compile-Time-Only Security Model]] - The preferred, safer compile-time alternative.
- [[Project Configuration Defaults]] - The `.stem.config.json` settings that influence mode.
- [[Strict Model-View Separation and State Isolation]] - Why the safe boundary matters.
