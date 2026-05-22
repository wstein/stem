---
id: 20260522200001
title: "Formatter Plugin"
aliases:
  - Stem Formatter Plugin
  - mix format plugin
tags:
  - dx
  - formatter
  - tooling
---

## What

`Stem.Formatter` implements the `Mix.Tasks.Format` behaviour, making it a first-class
**Elixir formatter plugin**. Declaring it in `.formatter.exs` causes `mix format` to
automatically normalise every `.stem` file listed in `inputs`.

## Why

Without the plugin, developers must run `mix stem.format "**/*.stem"` separately from
`mix format`. Integrating into the standard formatter:

- Ensures `.stem` files are always formatted in one step alongside Elixir sources.
- Makes the formatter available in editor integrations that invoke `mix format` on save
  (e.g., VS Code, Emacs, Neovim).
- Removes a manual step from CI pipelines — `mix format --check-formatted` covers both
  Elixir and Stem template files.

## How

### Project setup

Declare the plugin in `.formatter.exs` and add `.stem` file globs to `inputs`:

```elixir
# .formatter.exs
[
  plugins: [Stem.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "templates/**/*.stem"
  ]
]
```

Running `mix format` now normalises all listed `.stem` files automatically.

### What the formatter fixes

- Removes extra whitespace inside `{{ }}` tags: `{{  name  }}` → `{{name}}`
- Normalises spaces around whitespace-trim tildes: `{{ ~ name ~ }}` → `{{~name~}}`
- Canonicalises helper subexpressions: `{{  format ( uppercase   name )  }}` → `{{format (uppercase name)}}`
- Normalises pipeline expressions: `{{  user.name  |> trim |> truncate( 20 )  }}` → `{{user.name |> trim |> truncate(20)}}`
- Normalises block open tags: `{{ #if  ok }}` → `{{#if ok}}`
- Normalises closing and partial tags: `{{ / if }}` → `{{/if}}`, `{{ > partial }}` → `{{> partial}}`

The formatter never changes template semantics — only visual noise is affected.

### Standalone task

The standalone `mix stem.format` task continues to work for direct invocations:

```sh
mix stem.format templates/**/*.stem
mix stem.format --check-formatted path/to/template.stem
```

## Links

- [[Whitespace Trim Markers]] - The `{{~` / `~}}` syntax this formatter normalises
- [[Native AST Compilation Pipeline]] - The parser that the formatter must not break
