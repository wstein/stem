---
id: 20260522131203
aliases: []
tags: ['security', 'execution-modes', 'architecture']
---

## Overview

Stem provides two execution modes that govern how templates are evaluated and what code they're allowed to execute.

## Mode Comparison

| Aspect | Safe Mode | Permissive Mode |
|--------|-----------|-----------------|
| **Default** | Yes | No |
| **Production** | ✅ Recommended | ❌ Never |
| **Arbitrary Code** | Forbidden | Allowed |
| **SSTI Risk** | Protected | High |
| **Expression Types** | Structured only | Full Elixir AST |
| **Use Case** | All production | Dev/local only |
| **Explicit Config** | Not required | Required as flag |

## Detailed Guides

- [[safe-mode]] — The default sandbox with strict expression restrictions (production-safe)
- [[permissive-mode]] — Unrestricted mode for trusted, internal template sources (development-only)

## Core Architectural Principle

**All production templates should use `:safe` mode.**

This enforces a hard boundary between the view layer and business logic, preventing Server-Side Template Injection (SSTI) vulnerabilities. The requirement to explicitly set `mode: :permissive` in application config serves as a **highly visible code-review flag**, making it difficult to accidentally ship unsafe templates to production.

If a developer feels forced to use `:permissive` in production, this indicates an **architectural flaw**: business logic is leaking into the presentation layer and should be refactored into registered helpers or backend services.

## Security Principles

- **Secure by default**: `:safe` is the default to protect against SSTI
- **Opt-in unsafe**: `:permissive` must be explicitly chosen and visibly configured
- **Clear naming**: using `Stem.Unsafe` namespace makes security implications explicit to developers
- **Development-only use**: `:permissive` is reserved for local experiments, hacking, and rapid development

## Implementation Notes

Both modes are enforced during compilation:
- `:safe` raises `CompileError` if arbitrary expressions are detected
- `:permissive` allows those expressions to pass through as Elixir AST

The choice affects APIs like `Stem.Unsafe.eval_string/3` and `Stem.Unsafe.eval_file/3`.

## Links
