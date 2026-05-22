---
id: 20260522131152
aliases: []
tags: ['security', 'execution-modes', 'unsafe']
---

## Overview

Allows arbitrary code execution: unrecognized expressions are allowed to fall back to being executed as arbitrary Elixir AST.

## Characteristics

- **Maximum flexibility**: provides the full power of the host language without forcing developers to register a custom helper for every standard library function they might want to invoke
- **High security risk**: because it permits arbitrary Elixir expressions, it intrinsically enables Server-Side Template Injection (SSTI) vulnerabilities if an attacker manages to manipulate the template
- **Opt-in required**: must be explicitly specified via `mode: :permissive` in application config

## ⚠️ Production Warning

**Using `:permissive` mode in production is a major architectural red flag.**

It indicates improperly leaking backend business logic into the presentation layer, violating model-view separation. In mature production applications, templates should always compile in [[safe-mode]] to enforce strict architectural boundaries.

The requirement to explicitly write `mode: :permissive` in config serves as a highly visible code-review signal during risk assessment and approval workflows.

## Appropriate Use Cases

Only use `:permissive` mode for:
- Local experimentation and prototyping
- Development and debugging workflows
- Rapid hacking and investigation
- Internal templates where the source is entirely trusted and controlled by your own team
- **Never** in production or for user-generated templates

## Related

See [[safe-mode]] for the default secure alternative and [[execution-modes-overview]] for comparison.

## Links
