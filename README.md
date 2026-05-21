# Stem

Stem is a native Handlebars-inspired template compiler for Elixir.
It compiles double-curly-brace templates directly into Elixir's abstract syntax tree.
There is no intermediate template language and no runtime evaluation of template source.

## Why Stem

Templates become ordinary compiled functions, so rendering is fast and type-checked by the compiler.
Template source is never evaluated at runtime, which keeps untrusted input out of the code path.
The syntax stays familiar if you know double-curly templating systems.

## Quick Start

Compile a template into a function at compile time:

```elixir
defmodule Greeting do
  require Stem
  Stem.function_from_string(:def, :render, "Hello {{name}}", [:assigns])
end

Greeting.render(name: "Nina")
#=> "Hello Nina"
```

The compile-time DSL also supports a more declarative form:

```elixir
defmodule Views do
  use Stem

  deftemplate :hello, "Hello {{name}}", [:assigns]
  deftemplate_file :card, "templates/card.stem", [:assigns]
end
```

For inline rendering inside a function, import `Stem.Sigil` or `use Stem.DSL` / `use Stem` and use the compile-time `~STEM` sigil:

```elixir
import Stem.Sigil

def render(assigns) do
  ~STEM"Hello {{name}}"
end
```

See `examples/` for runnable scripts via `mix run examples/<name>.exs`.

## Syntax

- `{{expression}}` evaluates an expression and prints the string result without HTML escaping.
- `{{! comment }}` and `{{!-- comment --}}` are discarded.
- `{{> partial}}` expands a named partial.
- `{{#if}}`, `{{#unless}}`, `{{#each}}`, and `{{#with}}` open blocks closed by `{{/...}}`, each with an optional `{{else}}`.

Bare identifiers resolve to assigns, so `{{name}}` reads the `:name` assign.
Inside `{{#each}}`, `{{this}}` is the current item, `{{@index}}` the index, and `{{@key}}` the key when iterating a map.
`{{../name}}` reaches the parent (top-level assign) scope.
Block conditionals follow Elixir truthiness: only `false` and `nil` are falsey.
Use helpers or regular Elixir functions when output needs transformation (for example, sanitization, normalization, or formatting).

## Pipeline

Compilation flows through four stages:

```text
source -> Stem.Tokenizer -> Stem.Parser -> Stem.AST -> Stem.Compiler -> quoted Elixir
```

`Stem.Expression` translates the contents of each tag into Elixir during the compiler stage.

## Security

The runtime entry points (`Stem.eval_string/3`, `Stem.eval_file/3`, `Stem.compile_string/2`, and `Stem.compile_file/2`) raise `Stem.SecurityError`.
Stem only compiles templates at compile time, through the macros above.

## Command Line

Render a template file with JSON data:

```sh
mix stem template.stem '{"name":"Nina"}'
mix stem template.stem data.json -o output.txt
mix stem - < data.json
```

## Documentation

The repository includes an Antora documentation site under `docs/` with onboarding, manual, and arc42 architecture surfaces.
Design minutes and specifications live in `papers/`, and durable design notes live in `notes/`.

## License

Stem is released under the Apache-2.0 license.
See `LICENSE` for details.
