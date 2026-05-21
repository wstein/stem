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
Prefer compile-time macros for all static templates. Only use `Stem.Unsafe.eval_string/3` or `Stem.Unsafe.eval_file/3` when templates are dynamically generated from strictly trusted sources (e.g., controlled internal tools). You can further restrict runtime evaluation by passing `mode: :safe` to forbid arbitrary Elixir expressions.

#### Links
* [[Native AST Compilation Pipeline]] - The pipeline these macros drive.
* [[HTML Escaping Behavior]] - Output sanitization and raw expression guidance.

## Links
