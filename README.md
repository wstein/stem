# Stem

Stem is a native template compiler for Elixir that fuses the familiar syntax of **Handlebars** with the attribute strictness of **StringTemplate** and the powerful transformation pipelines of **Jinja2**.
It compiles double-curly-brace templates directly into Elixir's abstract syntax tree.
There is no intermediate template language.

## Why Stem

*   **Handlebars Syntax**: Remains approachable and compatible with standard frontend tooling.
*   **StringTemplate Strictness**: Enforces clear separation of concerns with restricted expression evaluation and safe-mode compatibility.
*   **Jinja2 Pipelines**: Enables elegant data transformation using the Elixir-style `|>` pipe operator to chain built-in and project-specific helpers.
*   **Native Performance**: Templates become ordinary compiled functions, so rendering is fast and type-checked by the compiler.
*   **Flexibility**: Choose compile-time macros for static performance or runtime APIs for dynamic content.

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
- Helper calls support nested subexpressions such as `{{format (uppercase name)}}`.
- Elixir-style helper pipelines such as `{{user.name |> trim |> upcase |> truncate(20)}}` compile to nested helper calls.
- `{{#each items as |item idx|}}` and `{{#with story as |article|}}` introduce block parameters.
- `{{~ ... ~}}` trims surrounding literal whitespace around a tag.

Bare identifiers resolve to assigns, so `{{name}}` reads the `:name` assign.
Inside `{{#each}}`, `{{this}}` is the current item, `{{@index}}` the index, and `{{@key}}` the key when iterating a map.
`{{../name}}` reaches the parent (top-level assign) scope.
Block conditionals follow Elixir truthiness: only `false` and `nil` are falsey.
Use helpers or regular Elixir functions when output needs transformation (for example, sanitization, normalization, or formatting).
Nested brace forms inside expressions are not supported.
Pipeline stages are restricted to helper names and helper calls so templates stay declarative.

## Runtime APIs

Stem supports runtime compilation and evaluation in addition to compile-time macros:

```elixir
quoted = Stem.compile_string("Hello {{name}}")
{result, _binding} = Code.eval_quoted(quoted, assigns: [name: "Nina"], helpers: [])
#=> {"Hello Nina", ...}

Stem.eval_string("Hello {{name}}", assigns: [name: "Nina"])
#=> "Hello Nina"

Stem.eval_string("{{name}}", assigns: [name: "Nina"], mode: :safe)
#=> "Nina"

Stem.eval_string("{{name}}", assigns: [name: "Nina"], contract: [required: [:name]])
#=> "Nina"
```

`mode: :safe` disables the arbitrary Elixir fallback path and only accepts structured Stem expressions, literals, helpers, and paths.
`contract:` lets templates declare required assigns at the call boundary.
Helper pipelines are safe-mode compatible because they lower to helper invocations instead of arbitrary Elixir.

## Built-In Helpers

Stem ships pipeline-friendly builtins for common presentation and collection work:

- `default`, `join`, `inspect`, `json`, `escape_json`, `escape_html`
- `trim`, `upcase`, `downcase`, `capitalize`, `replace`, `truncate`
- `contains`, `empty?`, `present?`, `starts_with`, `ends_with`
- `map`, `filter`, `sort`, `sort_by`, `group_by`, `take`, `drop`, `slice`, `first`, `compact`, `uniq`, `flatten`, `reverse`

Selector-based helpers such as `map`, `filter`, `sort_by`, and `group_by` accept a simple dotted path string like `"author.name"` so templates can stay declarative without anonymous functions.

## Tooling

Stem can format template files with:

```sh
mix stem.format path/to/template.stem
mix stem.format --check-formatted path/to/template.stem
```

Compiler diagnostics are available with `warn_on_diagnostics: true` and currently cover constant block conditions and unused block parameters.

## Pipeline

Compilation flows through four stages:

```text
source -> Stem.Tokenizer -> Stem.Parser -> Stem.AST -> Stem.Compiler -> quoted Elixir
```

`Stem.Expression` translates the contents of each tag into Elixir during the compiler stage.
Pipeline expressions are represented in that expression AST and lowered into nested helper invocations during compilation.

## Security

`{{...}}` output is not escaped automatically.
Apply escaping or sanitization explicitly through helper functions such as `escape_html`, or project-specific helpers.

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
