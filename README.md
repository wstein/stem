# Stem

Stem is a native template compiler for Elixir that fuses the familiar syntax of **Handlebars** with the attribute strictness of **StringTemplate** and the powerful transformation pipelines of **Jinja2**.
It compiles double-curly-brace templates directly into Elixir's abstract syntax tree.
There is no intermediate template language.

## Why Stem

* **Handlebars Syntax**: Remains approachable and compatible with standard frontend tooling.
* **StringTemplate Strictness**: Enforces clear separation of concerns with restricted expression evaluation by default.
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

# Allow arbitrary Elixir in a trusted template
echo '{"name":"Jim","id":123}' | bin/stem examples/templates/card.stem --allow-elixir-expressions
```

### Presentation-Only Static Dictionaries

When a view needs a small, trusted lookup table, use `defdictionary/2` with a
literal map or list of literals. These dictionaries are presentation data only:
they are validated at compile time, merged into assigns in declaration order,
and are not a general-purpose data-loading mechanism.

```elixir
defmodule StatusView do
  use Stem.DSL

  defdictionary :status_map, %{"1" => "Active", "2" => "Inactive"}
  defdictionary :priority_map, %{"high" => 1, "low" => 2}
  defdictionary_merge :all_statuses, [:status_map, :priority_map]

  deftemplate :render, "{{lookup status_map id}}", [:assigns]
end
```

Module attributes are allowed only when they expand to literals. Explicit
caller-supplied assigns still win at render time.

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
* `{{#each items as |item key|}}` and `{{#with story as |article|}}` introduce block parameters. For `{{#each}}` the second parameter is the iteration key — the map key when iterating a map, or the index for a list. `{{#each}}` also accepts a three-parameter form `as |item i0 i1|` binding the item, zero-based index, and one-based index.
* `{{~ ... ~}}`, `{{~ ...}}`, and `{{... ~}}` trim surrounding literal whitespace around a tag on both or one side.

Bare identifiers resolve to assigns, so `{{name}}` reads the `:name` assign.
Inside `{{#each}}`, `{{this}}` is the current item, `{{@index}}` the zero-based index, `{{@index1}}` the one-based index (mirroring StringTemplate's `i0`/`i`), and `{{@key}}` the key when iterating a map.
`{{../name}}` reaches the parent (top-level assign) scope.
The literals `true`, `false`, and `nil` are recognized; `null` is accepted as an alias for `nil` (and canonicalized to `nil` by the formatter) for Handlebars/JSON familiarity.
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
{result, _binding} = Code.eval_quoted(quoted, assigns: [name: "Nina"], transformers: %{})
#=> {"Hello Nina", ...}

Stem.Unsafe.eval_string("Hello {{name}}", assigns: [name: "Nina"])
#=> "Hello Nina"

Stem.Unsafe.eval_string("{{name}}", assigns: [name: "Nina"])
#=> "Nina"

Stem.Unsafe.eval_string("{{name}}", assigns: [name: "Nina"], contract: [required: [:name]])
#=> "Nina"

Stem.Unsafe.eval_string("{{a + b}}", [assigns: [a: 1, b: 2]], allow_elixir_expressions: true)
#=> "3"
```

### Execution Modes

Both `eval_string/3` and `eval_file/3` support two execution modes controlled by the `allow_elixir_expressions` flag:

* **`allow_elixir_expressions: false` (default)** — Restricts templates to structured Stem expressions, literals, helpers, and variable paths. Forbids arbitrary Elixir code. This is the recommended mode for all production templates and protects against Server-Side Template Injection (SSTI). Use this for:
  * User-generated or untrusted template sources
  * Production environments
  * Compliance-sensitive applications

* **`allow_elixir_expressions: true`** — Allows arbitrary Elixir expressions. Provides maximum flexibility but should only be used for development and local experiments when the template source is entirely trusted and controlled by your own team. Passing `allow_elixir_expressions: true` serves as a visible code-review flag during security review.

```elixir
# Restricted by default — use in production
Stem.Unsafe.eval_string("{{user.name |> trim |> upcase}}", assigns: [user: %{name: "nina"}])

# Explicit opt-in for arbitrary code — development only
Stem.Unsafe.eval_string("{{a + b}}", assigns: [a: 1, b: 2], allow_elixir_expressions: true)
```

Additional features:
- `contract:` lets templates declare required assigns at the call boundary
- Transformer pipelines are allowed by default because they lower to transformer invocations instead of arbitrary Elixir

## Transformer Capability Groups

Stem enforces **capability management** for transformers to reduce SSTI attack surface. Only a secure minimum of built-in transformers is available by default; complex operations require explicit opt-in via the `transformers:` map.

**Secure Minimum** (always available as built-ins):

* Output escaping: `escape_html`, `escape_json`, `json`, `inspect`
* Safe defaults: `default`
* Essential: `lookup`, `join`, `log`

**Optional Groups** (explicit opt-in):

* `Stem.Transformers.Strings` — Text manipulation (`trim`, `upcase`, `truncate`, etc.)
* `Stem.Transformers.Collections` — Data operations (`map`, `filter`, `sort_by`, `group_by`, etc.)
* `Stem.Transformers.Predicates` — Boolean tests (`contains`, `empty?`, `present?`)

Load groups at runtime by calling `.all()` and merging:

```elixir
Stem.Unsafe.eval_string(
  template,
  assigns: data,
  transformers: Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
)
```

Or pin defaults in `.stem.config.json`:

```json
{
  "transformers": "Stem.Transformers.Strings,Stem.Transformers.Collections"
}
```

Selector-based transformers such as `map`, `filter`, `sort_by`, and `group_by` accept a simple dotted path string like `"author.name"` so templates can stay declarative without anonymous functions.

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
  "allow_elixir_expressions": false
}
```

**Supported options**:

* `escape` - Default escape mode: `none`, `html` (default), `xml`, `json`, `url`
* `warn_on_missing_assigns` - Print warnings for missing assigns: `true` or `false`
* `allow_elixir_expressions` - Allow arbitrary Elixir expressions: `true` or `false` (default)

**Config discovery**: Stem walks up the directory tree from the current working directory to find `.stem.config.json`. It stops at the project root (when `mix.exs` is found) or the filesystem root.

**Option precedence** (highest to lowest):

1. Explicit compile/eval options
2. CLI flags (via `--escape`, `--strict`, `--permissive`)
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

## Testing

Run the full suite with:

```sh
mix test
```

Stem combines example-based unit tests with property-based fuzzing of the parse and compile pipeline (`test/stem/fuzz_test.exs`, powered by `StreamData`).
The fuzz generators produce random but structurally valid templates and assert that parsing and compilation never raise — they must return `{:ok, _}` or a structured `{:error, ...}` tuple — exercising edge cases such as nested blocks, recursive partial expansion, and pipeline-argument escaping.

## Documentation

The repository includes an Antora documentation site under `docs/` with onboarding, manual, and arc42 architecture surfaces.
Design minutes and specifications live in `papers/`, and durable design notes live in `notes/`.

## License

Stem is released under the Apache-2.0 license.
See `LICENSE` for details.
