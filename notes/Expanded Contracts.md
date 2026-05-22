---
id: 20260522200002
title: "Expanded Contracts"
aliases:
  - Stem Contracts
  - Group Interfaces
  - Template Contracts
tags:
  - api
  - compile-time
  - safety
---

## What

`Stem.Contract` provides compile-time declare and runtime enforce safety for template assigns,
modelled on **ST4 Group Interfaces**. Contracts declare which assigns a template expects, whether
they are required or optional, and what type each assign must have.

## Why

Without contracts, a missing required assign silently renders as an empty string. With contracts:

- Missing required assigns raise an `ArgumentError` at render time with a clear message.
- Typed assigns fail immediately when the caller passes the wrong type.
- Unknown type annotations fail at **template compile time** (not render time), giving early
  feedback before the template is deployed.
- A shared contract module can be referenced by many templates, providing a single place to
  maintain the interface.

## How

### Basic presence contract

```elixir
Stem.function_from_string(:def, :render, "{{title}}: {{body}}",
  [:assigns],
  contract: [required: [:title, :body], optional: [:subtitle]])
```

### Typed contract

```elixir
Stem.function_from_string(:def, :render, "{{title}} ({{count}})",
  [:assigns],
  contract: [
    required: [title: :string, count: :integer],
    optional: [active: :boolean, score: :float]
  ])
```

Supported types: `:string` (alias `:binary`), `:integer`, `:float`, `:number`, `:boolean`,
`:atom`, `:list`, `:map`, `:any`.

### Shared contract module (ST4-style Group Interface)

Define a shared interface once and reference it by module atom:

```elixir
defmodule MyApp.Contracts.ArticleView do
  def contract do
    [
      required: [title: :string, body: :string],
      optional: [author: :string, published_at: :string]
    ]
  end
end

# In any template module:
deftemplate :article, "{{title}}", [:assigns],
  contract: MyApp.Contracts.ArticleView
```

The module must export `contract/0`. If it does not, compilation fails with an
`ArgumentError`.

### Runtime error messages

```
# Missing required assign:
** (ArgumentError) missing required assigns for Stem contract: title, body

# Type mismatch:
** (ArgumentError) Stem contract type mismatch: assign :count must be integer, got "three"
```

### Compile-time type check

Unknown type atoms (e.g., `[title: :widget]`) are caught by `Stem.Contract.validate_types!/1`
which runs during template compilation via `maybe_apply_contract/2` in `Stem`:

```
** (ArgumentError) Stem contract: unknown type :widget.
Valid types: :string, :integer, :float, :number, :boolean, :atom, :list, :map, :binary, :any
```

## Links

- [[Strict Model-View Separation and State Isolation]] - The boundary contracts enforce
- [[Compile-Time-Only Security Model]] - Compile-time safety as a general principle
- [[Presentation-Only Static Dictionaries]] - The complementary compile-time data safety feature
