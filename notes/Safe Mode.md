---
id: 20260522131157
aliases: []
tags: ['security', 'execution-modes', 'sandbox']
---

## Overview

The default execution sandbox mode. Completely disables the arbitrary Elixir fallback path and restricts templates to only structured Stem expressions.

## Characteristics

- **Forbids arbitrary code**: intentionally halts and raises a `CompileError` if arbitrary Elixir expressions are detected inside tags during compilation, with message: "safe mode forbids arbitrary Elixir expressions in Stem tags"
- **Strictly structured expressions**: the execution context is tightly sandboxed, restricting the template to only allowing:
  - variable paths
  - explicitly registered helper calls
  - helper pipelines
  - literals
- **Drops unauthorized access**: actively removes the template's access to unauthorized helper functions, ensuring the template acts purely as a declarative view
- **Secure by default**: this is the default mode for Stem's dynamic runtime evaluation APIs (`Stem.Unsafe.eval_string/3` and `Stem.Unsafe.eval_file/3`)

## ✅ Production Best Practice

**All production templates should use `:safe` mode.**

This enforces strict model-view separation and prevents Server-Side Template Injection (SSTI) vulnerabilities. The secure-by-default design protects against developers accidentally leaking business logic into presentation layers. If you feel forced to use [[permissive-mode]] in production, re-examine your architectural design—this is a warning sign of a deeper structural problem.

## When to Use

Use `:safe` mode (the default) for:
- **All production environments** (strongly recommended)
- User-generated or untrusted template sources
- Compliance-sensitive applications
- Any situation where template inputs may be influenced by external actors

## Related

See [[permissive-mode]] for the unrestricted (development-only) alternative and [[execution-modes-overview]] for comparison.

## Links
