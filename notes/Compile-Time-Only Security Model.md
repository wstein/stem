---
id: 20260521120100
title: "Compile-Time-Only Security Model"
aliases: []
tags: ['security', 'api']
---

#### What
Stem emphasizes compile-time APIs (`Stem.function_from_string/5` and `Stem.compile_string/2`) for static performance and security. Runtime evaluation APIs (`eval_string/3` and `eval_file/3`) have been moved to the explicit `Stem.Unsafe` namespace.

#### Why
Dynamic rendering of untrusted template source at runtime introduces Server-Side Template Injection (SSTI) vulnerabilities, which can lead to arbitrary code execution. Quarantining runtime evaluation behind an explicit `Unsafe` namespace introduces intentional friction and ensures the risk is properly acknowledged during code review.

#### How
Prefer compile-time macros for all static templates. Only use `Stem.Unsafe.eval_string/3` or `Stem.Unsafe.eval_file/3` when templates are dynamically generated from strictly trusted sources (e.g., controlled internal tools). Both Unsafe functions default to `allow_elixir_expressions: false`, which forbids arbitrary Elixir expressions. Pass `allow_elixir_expressions: true` explicitly only when the template source is fully trusted and structured Stem expressions are insufficient.

Add `mix stem.audit` to your CI pipeline to enforce this boundary automatically. It scans production config files and fails the build if `allow_elixir_expressions: true` is found, making policy violations visible before deployment.

#### Links

* [[Execution Modes Overview]] - How the allow_elixir_expressions flag works
* [[Runtime Evaluation and Sandboxing]] - Runtime API details and flag semantics
* [[Native AST Compilation Pipeline]] - The pipeline these macros drive
* [[HTML Escaping Behavior]] - Output sanitization and raw expression guidance
* [[CI Security Gates]] - `mix stem.audit` task documentation
