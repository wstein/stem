---
id: 20260522140000
title: "Transformer Capability Groups"
aliases: ["Helper Capability Groups"]
tags: ['security', 'transformers', 'api', 'capabilities']
---

## What

Stem enforces **capability management** for transformer functions to reduce Server-Side Template Injection (SSTI) attack surface. Rather than exposing all transformers globally, Stem provides a secure minimum and requires explicit opt-in to capability groups for complex data operations.

## Why

An SSTI attacker with access to powerful helpers can chain operations to extract internal state or manipulate data. Restricting available helpers per execution context raises the exploitation barrier:

- **Secure by default**: only essential output-escaping and basic helpers are always available
- **Explicit opt-in**: complex data transformation must be deliberately declared in code or config
- **Auditable surface**: enabling a capability group is a visible review flag

## How

### Capability Groups

- **`Stem.Transformers.Minimum`** (always on, cannot be disabled): `escape_html`, `escape_json`, `json`, `inspect`, `default`, `lookup`, `join`, `log`. Never exposes dangerous operations.
- **`Stem.Transformers.Strings`**: `trim`, `upcase`, `downcase`, `capitalize`, `truncate`, `replace`, `take`, `drop`, `slice`, `first`, `reverse`, `starts_with`, `ends_with`.
- **`Stem.Transformers.Collections`**: `map`, `filter`, `compact`, `uniq`, `sort`, `sort_by`, `group_by`, `take`, `drop`, `slice`, `first`, `flatten`, `reverse`. ⚠️ Powerful — an attacker could chain these to extract internal state; enable only for trusted sources.
- **`Stem.Transformers.Predicates`**: `contains`, `empty?`, `present?`. For `{{#if}}` blocks and `filter`.

### Native backend parity

The native (Rust/WASM) core enforces the **same** model off the BEAM (see [[Native Backend Strategy]] and `native/README.md`). The render request carries the loaded groups in a `transformers` list of group names (`"strings"`, `"collections"`, `"predicates"`, `"i18n"`, or the `"standard"` bundle); Minimum is the always-on floor, and a call into an unloaded group is refused before render with a group-naming message — the analogue of `invoke/3` raising. The list is absent on the parity wire and from the C ABI, defaulting to Minimum-only, so a browser embed is secure by default. Custom transformers (including `i18n`'s host-delegated `t`/`translate`) come from a host `TransformerResolver`, consulted before the built-ins for the same caller-binding-first precedence; declaring the resolver's names lets the pre-check admit them while still refusing genuinely unknown names. The full built-in stdlib reaches byte-parity except for the value-formatting gaps in [[Cross-Backend Conformance Spec]].

Loading examples, audit behavior, and migration guidance live in [[Transformer Capability Group Operations]].

## Links

- [[Execution Modes Overview]] - The structured-only execution model
- [[Compile-Time-Only Security Model]] - Why compile-time templates are safer
- [[Runtime Evaluation and Sandboxing]] - Runtime API details
- [[Universal Architecture Principles]] - Capability management as a portable design principle
- [[CI Security Gates]] - Why the audit task was removed
- [[Transformer Capability Group Operations]] - Loading, auditing, and migration details
