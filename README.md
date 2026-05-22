# Stem

Stem is a native template compiler for Elixir that fuses the familiar syntax of **Handlebars** with the attribute strictness of **StringTemplate** and the powerful transformation pipelines of **Jinja2**.
It compiles double-curly-brace templates directly into Elixir's abstract syntax tree.
There is no intermediate template language.

## Why Stem

* **Handlebars Syntax**: Remains approachable and compatible with standard frontend tooling.
* **StringTemplate Strictness**: Enforces clear separation of concerns with restricted expression evaluation and safe-mode compatibility.
* **Jinja2 Pipelines**: Enables elegant data transformation using the Elixir-style `|>` pipe operator to chain built-in and project-specific helpers.
* **Native Performance**: Templates become ordinary compiled functions, so rendering is fast and type-checked by the compiler.
* **Flexibility**: Choose compile-time macros for static performance or runtime APIs for dynamic content.

## Quick Start

### 1. The `~STEM` Sigil

For inline rendering inside any Elixir function, use the `~STEM` sigil. It compiles the template to native AST at compile-time for maximum performance.

```elixir
defmodule MyView do
  import Stem.Sigil

  def render(assigns) do
    ~STEM"Hello {{name |> trim |> capitalize}}"
  end
end
```

### 2. File-Based Templates

Use `.stem` files for larger templates. Stem provides DSL macros to bind these files to module functions.

```elixir
defmodule Views do
  use Stem

  # Binds templates/card.stem to Views.card_template(assigns)
  deftemplate_file :card_template, "templates/card.stem", [:assigns]
end
```

### 3. Command Line Interface (CLI)

Format your templates or render them directly using the bundled executable in the `bin/` folder.

```bash
# Format your .stem files
mix stem.format "lib/**/*.stem"

# Render a template from a data file
bin/stem data.json template.stem

# Or pipe JSON data into it
echo '{"name": "Nina"}' | bin/stem template.stem
```

## Compilation Strategies

### Performance: Compile-Time Macros

Stem can compile templates directly into functions within your modules.

```elixir
defmodule Greeting do
  require Stem
  Stem.function_from_string(:def, :render, "Hello {{name}}", [:assigns])
end

Greeting.render(name: "Nina")
#=> "Hello Nina"
```

### Flexibility: Runtime Eval

For dynamic contents or user-provided templates, use the runtime API:

```elixir
Stem.Unsafe.eval_string("Hello {{name}}", assigns: [name: "Nina"])
#=> "Hello Nina"
```

## Syntax

* `{{expression}}` evaluates an expression and prints the string result with HTML escaping by default (secure-by-default).
* `{{{expression}}}` evaluates an expression and prints the string result without escaping (raw output).
* `{{! comment }}` and `{{!-- comment --}}` are discarded.
* `{{> partial}}` expands a named partial.
* `{{#if}}`, `{{#unless}}`, `{{#each}}`, `{{#with}}`, and `{{#region name}}` open blocks closed by `{{/...}}`, with `{{else}}` available on conditional and iteration blocks.
* `{{yield name}}` renders a named region from the current expanded template scope.
* Helper calls support nested subexpressions such as `{{format (uppercase name)}}`.
* Elixir-style helper pipelines such as `{{user.name |> trim |> upcase |> truncate(20)}}` compile to nested helper calls.
* `{{#each items as |item idx|}}` and `{{#with story as |article|}}` introduce block parameters.
* `{{~ ... ~}}`, `{{~ ...}}`, and `{{... ~}}` trim surrounding literal whitespace around a tag on both or one side.

Bare identifiers resolve to assigns, so `{{name}}` reads the `:name` assign.
Inside `{{#each}}`, `{{this}}` is the current item, `{{@index}}` the index, and `{{@key}}` the key when iterating a map.
`{{../name}}` reaches the parent (top-level assign) scope.
Block conditionals follow Handlebars truthiness: `false`, `nil`, `0`, `""`, `[]`, and `{}` (empty map) are falsey.
Use helpers or regular Elixir functions when output needs transformation (for example, sanitization, normalization, or formatting).
Nested brace forms inside expressions are not supported.
Pipeline stages are restricted to helper names and helper calls so templates stay declarative.

## Layouts with Regions and Partials

Stem supports first-class named regions for layout composition. Define a region in the caller, then render it inside a wrapper partial with `{{yield name}}`. Because partials still expand inline during parsing, yields can resolve regions across nested partial boundaries without prop drilling.

```elixir
partials = %{
  layout: "<article><header>{{yield header}}</header><main>{{yield body}}</main></article>"
}

Stem.Unsafe.eval_string("{{#region header}}<h1>{{title}}</h1>{{/region}}{{#region body}}Hello {{name}}{{/region}}{{> layout}}",
  assigns: [title: "Stem", name: "Nina"],
  partials: partials
)
```

Missing yields render as empty strings, so wrapper partials can expose optional slots without extra conditionals.

## Runtime APIs

Stem supports runtime compilation and evaluation in addition to compile-time macros:

```elixir
quoted = Stem.compile_string("Hello {{name}}")
{result, _binding} = Code.eval_quoted(quoted, assigns: [name: "Nina"], helpers: [])
#=> {"Hello Nina", ...}

Stem.Unsafe.eval_string("Hello {{name}}", assigns: [name: "Nina"])
#=> "Hello Nina"

Stem.Unsafe.eval_string("{{name}}", assigns: [name: "Nina"], mode: :safe)
#=> "Nina"

Stem.Unsafe.eval_string("{{name}}", assigns: [name: "Nina"], contract: [required: [:name]])
#=> "Nina"
```

`mode: :safe` disables the arbitrary Elixir fallback path and only accepts structured Stem expressions, literals, helpers, and paths.
`contract:` lets templates declare required assigns at the call boundary.
Helper pipelines are safe-mode compatible because they lower to helper invocations instead of arbitrary Elixir.

## Built-In Helpers

Stem ships pipeline-friendly builtins for common presentation and collection work:

* `default`, `join`, `inspect`, `json`, `escape_json`, `escape_html`
* `trim`, `upcase`, `downcase`, `capitalize`, `replace`, `truncate`
* `contains`, `empty?`, `present?`, `starts_with`, `ends_with`
* `map`, `filter`, `sort`, `sort_by`, `group_by`, `take`, `drop`, `slice`, `first`, `compact`, `uniq`, `flatten`, `reverse`

Selector-based helpers such as `map`, `filter`, `sort_by`, and `group_by` accept a simple dotted path string like `"author.name"` so templates can stay declarative without anonymous functions.

## Tooling

Stem can format template files with:

```sh
mix stem.format path/to/template.stem
mix stem.format --check-formatted path/to/template.stem
```

Compiler diagnostics are available with `warn_on_diagnostics: true` and currently cover constant block conditions and unused block parameters.

Pass `warn_on_falsy_coercion: true` to log when values such as `0`, `""`, `[]`, or `%{}` are coerced into false by Stem's Handlebars-style truthiness rules at render time.

## Configuration

### Project-Level Config with `.stem.config.json`

Create a `.stem.config.json` file in your project root to set default options for template compilation and evaluation. The CLI and runtime APIs automatically discover and apply these defaults.

```json
{
  "escape": "html",
  "warn_on_missing_assigns": false,
  "mode": "permissive"
}
```

**Supported options**:

* `escape` - Default escape mode: `none`, `html` (default), `xml`, `json`, `url`
* `warn_on_missing_assigns` - Print warnings for missing assigns: `true` or `false`
* `mode` - Template evaluation mode: `permissive` (default) or `safe`

**Config discovery**: Stem walks up the directory tree from the current working directory to find `.stem.config.json`. It stops at the project root (when `mix.exs` is found) or the filesystem root.

**Option precedence** (highest to lowest):

1. Explicit compile/eval options
2. CLI flags (via `--escape`, `--strict`)
3. Config file (`.stem.config.json`)
4. Defaults

Example with CLI override:

```bash
# Config file has escape: xml
# But CLI flag overrides it
bin/stem data.json template.stem --escape html
```

## Pipeline

Compilation flows through four stages:

```text
source -> Stem.Tokenizer -> Stem.Parser -> Stem.AST -> Stem.Compiler -> quoted Elixir
```

`Stem.Expression` translates the contents of each tag into Elixir during the compiler stage.
Pipeline expressions are represented in that expression AST and lowered into nested helper invocations during compilation.

## Security

Stem is secure-by-default: `{{...}}` output is **HTML escaped automatically** to prevent XSS attacks.
Use `{{{...}}}` for raw output when you know the content is safe.

### Configurable Escape Modes

You can override the default HTML escaping with the `:escape` option:

```elixir
# HTML escaping (default, recommended)
Stem.Unsafe.eval_string("{{name}}", assigns: [name: "<script>alert('xss')</script>"])
#=> "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"

# Raw output (use with caution)
Stem.Unsafe.eval_string("{{name}}", assigns: [name: "<b>bold</b>"], escape: :none)
#=> "<b>bold</b>"

# Other escape modes: :xml, :json, :url, or custom functions
Stem.Unsafe.eval_string("{{name}}", assigns: [name: "hello&world"], escape: :xml)

# Via CLI
bin/stem data.json template.stem --escape none
```

Built-in escape formatters: `:html` (default), `:xml`, `:json`, `:url`, `:none`.
Custom escape functions can be registered via `Stem.Escaping.register/2`.

## Command Line

Render a template file with Mustache-style input order using the `bin/stem` launcher:

```sh
# Using a data file
bin/stem data.json template.stem

# Using standard input
echo '{"name":"Nina"}' | bin/stem template.stem

# Output to a file
bin/stem data.json template.stem -o output.txt

# Disable HTML escaping
bin/stem data.json template.stem --escape none

# Use other escape modes: xml, json, url
bin/stem data.json template.stem --escape xml
```

Formatting and checking is performed via Mix tasks:

```sh
mix stem.format "lib/**/*.stem"
mix stem.format --check-formatted lib/my_template.stem
```

## Documentation

The repository includes an Antora documentation site under `docs/` with onboarding, manual, and arc42 architecture surfaces.
Design minutes and specifications live in `papers/`, and durable design notes live in `notes/`.

## License

Stem is released under the Apache-2.0 license.
See `LICENSE` for details.
