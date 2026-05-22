---
id: 20260522101102
title: "Project Configuration Defaults"
aliases: []
tags: ['configuration', 'defaults', 'json']
---

## What
Stem supports project-level configuration via `.stem.config.json` files in the root of your project. These files allow you to set default values for compiler options like escape mode, warning flags, and expression restrictions, without repeating them in every API call or CLI invocation.

## Why
This keeps template source purely about rendering structure while giving applications one clear place to pin defaults such as `escape`, `warn_on_missing_assigns`, and `allow_elixir_expressions`. Configuration is hierarchical and can be overridden by explicit compile options or CLI flags.

## How
Define global defaults by creating a `.stem.config.json` file in your project root or any parent directory. Stem discovers that file automatically via upward directory traversal, stopping at `mix.exs`:

```json
{
  "escape": "html",
  "allow_elixir_expressions": false,
  "warn_on_missing_assigns": false
}
```

The effective precedence is: **explicit API options > CLI flags > `.stem.config.json` > engine defaults**.

For example:
- The compiler defaults to `allow_elixir_expressions: false`
- Set `"allow_elixir_expressions": true` in the config file only when templates authored by your team need arbitrary Elixir expressions
- Use `Stem.compile_string(source, allow_elixir_expressions: true)` to override the config for a single call

## Supported Options

- `"escape"` — One of `"none"`, `"html"` (default), `"xml"`, `"json"`, `"url"`
- `"warn_on_missing_assigns"` — Boolean; defaults to `false`
- `"allow_elixir_expressions"` — Boolean; defaults to `false`

## Links

- [[Runtime Evaluation and Sandboxing]] - Runtime API behavior
- [[Execution Modes Overview]] - Broader context on expression restrictions
- [[Strict CLI Contract and Launcher]] - How CLI flags interact with config
