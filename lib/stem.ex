# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

defmodule Stem.SyntaxError do
  defexception [:file, :line, :column, :snippet, message: "syntax error"]

  @impl true
  def message(exception) do
    %{file: file, line: line, column: column, message: message, snippet: snippet} = exception

    Exception.format_file_line_column(file && Path.relative_to_cwd(file), line, column, " ") <>
      message <> (snippet || "")
  end
end

defmodule Stem do
  @moduledoc ~S"""
  Stem is a native Handlebars-style template compiler for Elixir.

  Stem compiles double-curly-brace templates straight into Elixir's abstract
  syntax tree through its own tokenizer, parser, and compiler — there is no
  intermediate template language. Templates become efficient compiled
  functions, and templates can be compiled or evaluated both at compile time
  and at runtime.

  This module provides two compile-time APIs:

    1. Define a function from a string (`function_from_string/5`) or a file
       (`function_from_file/5`). The template is compiled into a function
       inside the surrounding module. This is the primary API.

    2. Compile a string (`compile_string/2`) or a file (`compile_file/2`)
       into an Elixir abstract syntax tree.

  Runtime APIs are also available for dynamic use cases:

    * `compile_string/2` and `compile_file/2` return quoted Elixir.
    * `eval_string/3` and `eval_file/3` compile and evaluate templates.

  ⚠️ **Security**: Runtime evaluation APIs (`eval_string`, `eval_file`) should
  only be used with **templates from trusted sources**. Use compile-time APIs
  (`function_from_string`, `compile_string`) for untrusted templates to prevent
  server-side template injection attacks. See `Stem.Unsafe` for runtime APIs.

  ## Pipeline

  Compilation flows through four stages:

      source -> Stem.Tokenizer -> Stem.Parser -> Stem.AST -> Stem.Compiler -> quoted Elixir

  `Stem.Expression` translates the contents of each tag into Elixir as part of
  the compiler stage.

  ## Options

  All functions in this module, unless otherwise noted, accept these options:

    * `:file` - the file used in the template, for error reporting. Defaults to
      the file the template is read from, or `"nofile"` when compiling from a
      string.

    * `:line` - the line used as the template start. Defaults to `1`.

    * `:column` - the column used as the template start. Defaults to `1`.

    * `:partials` - a map or keyword list of named partial templates that
      `{{> name}}` expands inline. Defaults to `%{}`.

    * `:warn_on_missing_assigns` - when `true`, missing assigns print a warning
      instead of returning `nil` silently. Defaults to `false`.

    * `:warn_on_diagnostics` - when `true`, Stem emits compiler warnings for
      constant block conditions and unused block parameters. Defaults to
      `false`.

    * `:warn_on_falsy_coercion` - when `true`, Stem warns at render time when
      values like `0`, `""`, `[]`, or `%{}` are coerced to false under
      Handlebars truthiness. Defaults to `false`.

    * `:lock_security` - when `true`, template frontmatter cannot override
      project-level `:escape` or `:mode` security settings. Defaults to
      `false`.

    * `:contract` - a keyword list like `[required: [:title], optional:
      [:subtitle]]` used to validate required assigns before rendering.

    * `:mode` - `:permissive` (default) keeps the current fallback to
      arbitrary Elixir expressions. `:safe` only allows structured Stem
      expressions, helpers, literals, and paths.

    * `:escape` - the default escape mode for `{{ }}` expressions. One of
      `:html` (default, recommended for security), `:none` (no escaping),
      `:xml`, `:json`, `:url`, or a custom escape function. Use `{{{ }}}`
      to override per expression and skip escaping.

  ## Syntax

  Stem supports the following tags:

    * `{{expression}}` - evaluates the expression and prints the
      string result without HTML escaping.
    * `{{! comment }}` and `{{!-- comment --}}` - discarded from the output.
    * `{{> partial}}` - expands a named partial.
    * `{{#if}}`, `{{#unless}}`, `{{#each}}`, `{{#with}}` with matching
      `{{/...}}` closing tags and an optional `{{else}}`.
    * `{{format (uppercase name)}}` style helper subexpressions.
    * `{{name |> trim |> upcase |> truncate(20)}}` helper pipelines.
    * `{{#each items as |item idx|}}` / `{{#with story as |article|}}`
      block parameters.
    * `{{~ ... ~}}` whitespace control around any tag.

  Bare identifiers resolve to assigns: `{{name}}` reads the `:name` assign.
  Inside `{{#each}}`, `{{this}}` is the current item, `{{@index}}` the
  zero-based index, and `{{@key}}` the key when iterating a map. `{{../name}}`
  reaches the parent (top-level assign) scope.

  Pipelines are restricted to helper stages so templates stay declarative.
  `{{lhs |> helper(a, b)}}` compiles as if the helper had been called with
  the pipeline value prepended: `helper(lhs, a, b)`.

  Stem ships built-in helpers for common text and collection transforms,
  including `trim`, `upcase`, `truncate`, `default`, `join`, `map`,
  `filter`, `sort_by`, `group_by`, `compact`, `uniq`, `json`, and `escape_html`.

      iex> defmodule Greeting do
      ...>   require Stem
      ...>   Stem.function_from_string(:def, :render, "Hello {{name}}", [:assigns])
      ...> end
      iex> Greeting.render(name: "Nina")
      "Hello Nina"

  Block conditionals follow Handlebars truthiness: `false`, `nil`, `0`, `""`,
  `[]`, and `%{}` are falsey. Pass `warn_on_falsy_coercion: true` to surface
  when native Elixir values are being coerced into that falsey set at render
  time.

  Missing assigns render as an empty string. Pass `warn_on_missing_assigns:
  true` to print a warning for missing values.

      iex> Stem.eval_string("{{name |> trim |> upcase}}", assigns: [name: "  nina  "])
      "NINA"
  """

  defmacro __using__(_opts) do
    quote do
      use Stem.DSL
    end
  end

  @type line :: non_neg_integer
  @type column :: non_neg_integer

  @type compile_opt ::
          {:file, binary()}
          | {:line, line}
          | {:column, column}
          | {:partials, map() | keyword()}
          | {:warn_on_missing_assigns, boolean()}
          | {:warn_on_falsy_coercion, boolean()}
          | {:lock_security, boolean()}
          | {:contract, keyword()}
          | {:mode, :permissive | :safe}
          | {atom(), term()}

  @doc """
  Generates a function definition from the given string.

  The first argument is the kind of the generated function (`:def` or `:defp`).
  The `name` argument is the name that the generated function will have.
  `template` is the string containing the Stem template. `args` is a list of arguments
  that the generated function will accept. They will be available inside the Stem
  template.

  The supported `options` are described [in the module docs](#module-options).
  Additional options are passed to the underlying engine.

  ## Examples

      iex> defmodule Sample do
      ...>   require Stem
      ...>   Stem.function_from_string(:def, :sample, "{{a}}", [:assigns])
      ...> end
      iex> Sample.sample([a: 3])
      "3"

  """
  defmacro function_from_string(kind, name, template, args \\ [], options \\ []) do
    quote bind_quoted: binding() do
      original_args = args

      if options[:contract] && :assigns not in original_args do
        raise ArgumentError, "Stem contracts require an :assigns argument"
      end

      info = Keyword.merge([file: __ENV__.file, line: __ENV__.line], options)
      args = Enum.map(original_args, fn arg -> {arg, [line: info[:line]], nil} end)
      compiled = Stem.__compile_string__(template, info)

      noops = []

      noops =
        if :assigns in original_args, do: [quote(do: _ = var!(assigns)) | noops], else: noops

      noops =
        if :helpers in original_args, do: [quote(do: _ = var!(helpers)) | noops], else: noops

      case kind do
        :def ->
          @compile {:nowarn_unused_vars, true}
          def unquote(name)(unquote_splicing(args)) do
            unquote_splicing(Enum.reverse(noops))
            unquote(compiled)
          end

        :defp ->
          @compile {:nowarn_unused_vars, true}
          defp unquote(name)(unquote_splicing(args)) do
            unquote_splicing(Enum.reverse(noops))
            unquote(compiled)
          end
      end
    end
  end

  @doc """
  Generates a function definition from the file contents.

  The first argument is the kind of the generated function (`:def` or `:defp`).
  The `name` argument is the name that the generated function will have.
  `file` is the path to the Stem template file. `args` is a list of arguments
  that the generated function will accept. They will be available inside the Stem
  template.

  This function is useful in case you have templates but
  you want to precompile inside a module for speed.

  The supported `options` are described [in the module docs](#module-options).

  ## Examples

      # sample.stem
      {{a}}

      # sample.ex
      defmodule Sample do
        require Stem
        Stem.function_from_file(:def, :sample, "sample.stem", [:assigns])
      end

      # iex
      Sample.sample([a: 3])
      #=> "3"

  """
  defmacro function_from_file(kind, name, file, args \\ [], options \\ []) do
    quote bind_quoted: binding() do
      original_args = args

      if options[:contract] && :assigns not in original_args do
        raise ArgumentError, "Stem contracts require an :assigns argument"
      end

      info = Keyword.merge([file: IO.chardata_to_string(file), line: 1], options)
      args = Enum.map(original_args, fn arg -> {arg, [line: 1], nil} end)
      compiled = Stem.__compile_file__(file, info)

      noops = []

      noops =
        if :assigns in original_args, do: [quote(do: _ = var!(assigns)) | noops], else: noops

      noops =
        if :helpers in original_args, do: [quote(do: _ = var!(helpers)) | noops], else: noops

      @external_resource file
      @file file
      case kind do
        :def ->
          @compile {:nowarn_unused_vars, true}
          def unquote(name)(unquote_splicing(args)) do
            unquote_splicing(Enum.reverse(noops))
            unquote(compiled)
          end

        :defp ->
          @compile {:nowarn_unused_vars, true}
          defp unquote(name)(unquote_splicing(args)) do
            unquote_splicing(Enum.reverse(noops))
            unquote(compiled)
          end
      end
    end
  end

  @doc """
  Compiles a template string into quoted Elixir.
  """
  @spec compile_string(String.t(), [compile_opt]) :: Macro.t()
  def compile_string(source, options \\ []) when is_binary(source) and is_list(options) do
    __compile_string__(source, options)
  end

  @doc """
  Compiles a template file into quoted Elixir.
  """
  @spec compile_file(Path.t(), [compile_opt]) :: Macro.t()
  def compile_file(filename, options \\ []) when is_list(options) do
    __compile_file__(filename, options)
  end

  @doc """
  Compiles and evaluates a template string using the provided bindings.

  ⚠️ **WARNING**: This function is only safe when templates come from a trusted source.
  For better security, use compile-time APIs like `function_from_string/5` instead.
  See `Stem.Unsafe` for more information.
  """
  @spec eval_string(String.t(), keyword, [compile_opt]) :: term()
  def eval_string(source, bindings \\ [], options \\ [])
      when is_binary(source) and is_list(bindings) and is_list(options) do
    bindings = normalize_runtime_bindings(bindings)
    merged_options = load_and_merge_config(options)
    quoted = __compile_string__(source, merged_options)
    {result, _} = Code.eval_quoted(quoted, bindings)
    result
  end

  @doc """
  Compiles and evaluates a template file using the provided bindings.

  ⚠️ **WARNING**: This function is only safe when the file path comes from a trusted source.
  For better security, use compile-time APIs like `function_from_file/5` instead.
  See `Stem.Unsafe` for more information.
  """
  @spec eval_file(Path.t(), keyword, [compile_opt]) :: String.t()
  def eval_file(filename, bindings \\ [], options \\ [])
      when is_list(bindings) and is_list(options) do
    bindings = normalize_runtime_bindings(bindings)
    merged_options = load_and_merge_config(options)
    quoted = __compile_file__(filename, merged_options)
    {result, _} = Code.eval_quoted(quoted, bindings)
    result
  end

  ### Helpers

  @doc false
  def __compile_string__(source) when is_binary(source) do
    __compile_string__(source, [])
  end

  @doc false
  def __compile_string__(source, options) when is_binary(source) and is_list(options) do
    compile_string_internal(source, options)
  end

  @doc false
  def __compile_file__(filename) do
    __compile_file__(filename, [])
  end

  @doc false
  def __compile_file__(filename, options) when is_list(options) do
    filename = IO.chardata_to_string(filename)
    compile_file_internal(filename, load_and_merge_config(options))
  end

  defp compile_string_internal(source, options) do
    file = options[:file] || "nofile"

    case Stem.Parser.parse(source, options) do
      {:ok, ast} ->
        ast
        |> Stem.Compiler.compile(options)
        |> maybe_apply_contract(options)

      {:error, message, %{line: line, column: column}} ->
        raise Stem.SyntaxError,
          file: file,
          line: line,
          column: column,
          message: message,
          snippet: code_snippet(source, line, column)
    end
  end

  defp compile_file_internal(filename, options) do
    source = File.read!(filename)

    case Stem.Frontmatter.parse(source) do
      {:ok, {frontmatter_opts, template_body}} ->
        merged_options =
          maybe_lock_frontmatter_security(frontmatter_opts, options)
          |> Keyword.merge(options)
          |> Keyword.merge([file: filename, line: 1])

        compile_string_internal(template_body, merged_options)

      {:error, reason} ->
        raise Stem.SyntaxError,
          file: filename,
          line: 1,
          column: 1,
          message: "invalid frontmatter: #{reason}",
          snippet: nil
    end
  end

  defp maybe_lock_frontmatter_security(frontmatter_opts, options) do
    if Keyword.get(options, :lock_security, false) do
      Keyword.drop(frontmatter_opts, [:escape, :mode])
    else
      frontmatter_opts
    end
  end

  defp normalize_runtime_bindings(bindings) do
    bindings
    |> Keyword.put_new(:assigns, [])
    |> Keyword.put_new(:helpers, [])
  end

  defp load_and_merge_config(options) do
    cwd = System.get_env("EXBAR_CWD") || File.cwd!()

    case Stem.Config.find_config(cwd) do
      {:ok, config_path} ->
        case Stem.Config.load_config(config_path) do
          {:ok, config} ->
            Keyword.merge(config, options)

          {:error, _reason} ->
            options
        end

      :not_found ->
        options
    end
  end

  defp maybe_apply_contract(quoted, options) do
    case Stem.Contract.normalize(options[:contract]) do
      nil ->
        quoted

      contract ->
        quote do
          Stem.Contract.validate!(
            Keyword.get(binding(), :assigns, []),
            unquote(Macro.escape(contract))
          )

          unquote(quoted)
        end
    end
  end

  defp code_snippet(source, line, column) do
    line_start = max(line - 2, 1)
    digits = line |> Integer.to_string() |> byte_size()
    padding = String.duplicate(" ", digits)

    source
    |> String.split(["\r\n", "\n"])
    |> Enum.slice((line_start - 1)..(line - 1))
    |> Enum.map_reduce(line_start, fn
      text, number when number == line ->
        arrow = String.duplicate(" ", max(column - 1, 0)) <> "^"
        {"#{number} | #{text}\n #{padding}| #{arrow}", number + 1}

      text, number ->
        {"#{String.pad_leading("#{number}", digits)} | #{text}", number + 1}
    end)
    |> case do
      {[], _} -> ""
      {lines, _} -> Enum.join(["\n #{padding}|" | lines], "\n")
    end
  end
end
