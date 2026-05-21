---
id: 20260521131200
aliases: [Escaping]
tags: [security, html]
---
Stem applies HTML escaping by default to expressions inside double-curly braces to prevent Cross-Site Scripting (XSS) vulnerabilities.

## What

`{{ expression }}` escapes `&`, `<`, `>`, `"`, and `'`.
`{{{ expression }}}` (triple-curly) bypasses escaping and renders the raw string.
`{{{{ literal }}}}` (four-curly) renders the content verbatim without any processing.

## Why

Safety by default is a core principle. Developers must make a conscious choice to render raw HTML, reducing the risk of accidental exposure to un-sanitized user input.

## How

Use `{{ }}` for all dynamic text. Reserve `{{{ }}}` for content that has already been sanitized or is known to be safe (e.g., generated Markdown). Use `{{{{ }}}}` when you need to output literal Handlebars tags in the final result.

## Links

- [[Handlebars-Inspired Philosophy]] - Alignment with Handlebars escaping standards.
- [[Compile-Time-Only Security Model]] - The broader security context of Stem.
