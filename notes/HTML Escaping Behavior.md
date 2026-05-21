---
id: 20260521131200
title: "HTML Escaping Behavior"
aliases: [Escaping]
tags: ['security', 'html']
---

## What

Stem is secure-by-default: output from `{{ expression }}` tags is automatically HTML-escaped. Raw, unescaped output must be explicitly requested using triple braces `{{{ expression }}}`. The escape mode is configurable, supporting `:html` (default), `:xml`, `:json`, `:url`, `:none`, or custom formatter functions.

## Why

Automatic HTML escaping protects against Cross-Site Scripting (XSS) and other injection vulnerabilities by default, without relying on developers to remember to manually invoke an `escape_html` helper on every output. Providing multiple built-in escape modes ensures the engine adapts securely to different rendering contexts, such as JSON APIs or XML feeds.

## How

Use `{{ }}` for all standard output. Only use `{{{ }}}` when you are absolutely certain the rendered content is trusted and safe to be printed without sanitization. You can override the default escape mode via the `--escape` CLI flag, a `.stem.config.json` file, or the `:escape` compile option.

## Links

* [[Compile-Time-Only Security Model]] - The broader security context of Stem.
* [[Project Configuration Defaults]] - How to configure escape modes per project.
