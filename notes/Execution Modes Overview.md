---
id: 20260522131203
aliases: []
tags: ['security', 'execution-modes', 'architecture']
---

## Overview

Stem provides two execution modes that govern how templates are evaluated and what code they're allowed to execute.

## Mode Comparison

| Aspect | Restricted (Default) | Unrestricted |
|--------|-----------|-----------------|
| **Flag** | `allow_elixir_expressions: false` | `allow_elixir_expressions: true` |
| **Default** | Yes | No |
| **Production** | ✅ Recommended | ❌ Never |
| **Arbitrary Code** | Forbidden | Allowed |
| **SSTI Risk** | Protected | High |
| **Expression Types** | Structured only | Full Elixir AST |
| **Use Case** | All production | Dev/local only |
| **Explicit Config** | Not required | Required as flag |

## Detailed Guides

- [[Compile-Time-Only Security Model]] — How compile-time templates are intrinsically safe
- [[Project Configuration Defaults]] — How to configure defaults via `.stem.config.json`

## Core Architectural Principle

**All production templates should use `allow_elixir_expressions: false` (the default).**

This enforces a hard boundary between the view layer and business logic, preventing Server-Side Template Injection (SSTI) vulnerabilities. The requirement to explicitly set `allow_elixir_expressions: true` in application config serves as a **highly visible code-review flag**, making it difficult to accidentally ship unsafe templates to production.

If a developer feels forced to use `allow_elixir_expressions: true` in production, this indicates an **architectural flaw**: business logic is leaking into the presentation layer and should be refactored into registered helpers or backend services.

## Security Principles

- **Secure by default**: `false` is the default to protect against SSTI
- **Opt-in unsafe**: `true` must be explicitly chosen and visibly configured
- **Clear naming**: using `Stem.Unsafe` namespace makes security implications explicit to developers
- **Development-only use**: `allow_elixir_expressions: true` is reserved for local experiments and rapid development

## Implementation Notes

Both modes are enforced during compilation:
- `allow_elixir_expressions: false` raises `CompileError` if arbitrary expressions are detected
- `allow_elixir_expressions: true` allows those expressions to pass through as Elixir AST

The choice affects APIs like `Stem.Unsafe.eval_string/3` and `Stem.Unsafe.eval_file/3`, as well as configuration via `.stem.config.json` and the CLI `--allow-elixir-expressions` flag.

## Links
