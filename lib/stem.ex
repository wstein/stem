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

defmodule Stem.SecurityError do
  defexception message:
                 "runtime template compilation is disabled; use Stem.function_from_string/5 or Stem.function_from_file/5 at compile time"
end

defmodule Stem do
  @moduledoc ~S"""
  Stem is a native Handlebars-style template compiler for Elixir.

  Stem compiles double-curly-brace templates straight into Elixir's abstract
  syntax tree through its own tokenizer, parser, and compiler — there is no
  intermediate template language. Templates become efficient compiled
  functions, and template source is never evaluated at runtime.

  This module provides two compile-time APIs:

    1. Define a function from a string (`function_from_string/5`) or a file
       (`function_from_file/5`). The template is compiled into a function
       inside the surrounding module. This is the primary API.

    2. Compile a string (`compile_string/2`) or a file (`compile_file/2`)
       into an Elixir abstract syntax tree.

  For security, the runtime entry points (`eval_string/3`, `eval_file/3`,
  `compile_string/2`, and `compile_file/2`) raise `Stem.SecurityError`: Stem
  never compiles untrusted template source at runtime. Use the compile-time
  macros instead.

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

  ## Syntax

  Stem supports the following tags:

    * `{{expression}}` - evaluates the expression and prints the
      string result without HTML escaping.
    * `{{! comment }}` and `{{!-- comment --}}` - discarded from the output.
    * `{{> partial}}` - expands a named partial.
    * `{{#if}}`, `{{#unless}}`, `{{#each}}`, `{{#with}}` with matching
      `{{/...}}` closing tags and an optional `{{else}}`.

  Bare identifiers resolve to assigns: `{{name}}` reads the `:name` assign.
  Inside `{{#each}}`, `{{this}}` is the current item, `{{@index}}` the
  zero-based index, and `{{@key}}` the key when iterating a map. `{{../name}}`
  reaches the parent (top-level assign) scope.

      iex> defmodule Greeting do
      ...>   require Stem
      ...>   Stem.function_from_string(:def, :render, "Hello {{name}}", [:assigns])
      ...> end
      iex> Greeting.render(name: "Nina")
      "Hello Nina"

  Block conditionals follow Elixir truthiness: only `false` and `nil` are
  falsey, while `0`, `""`, and `[]` are truthy. For checks that should treat
  `0` as false, use `&&`, `||`, and parentheses, as in
  `{{#if (render && render != 0) || fallback}}`.

  Missing assigns render as an empty string. Pass `warn_on_missing_assigns:
  true` to print a warning for missing values.
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
  Disabled: raises `Stem.SecurityError`.

  Stem does not compile template source at runtime. Use the compile-time
  macros `function_from_string/5` and `function_from_file/5` instead.
  """
  @spec compile_string(String.t(), [compile_opt]) :: Macro.t()
  def compile_string(source, options \\ []) when is_binary(source) and is_list(options) do
    _ = {source, options}
    raise Stem.SecurityError
  end

  @doc """
  Disabled: raises `Stem.SecurityError`.

  Stem does not compile template source at runtime. Use the compile-time
  macros `function_from_string/5` and `function_from_file/5` instead.
  """
  @spec compile_file(Path.t(), [compile_opt]) :: Macro.t()
  def compile_file(filename, options \\ []) when is_list(options) do
    _ = {filename, options}
    raise Stem.SecurityError
  end

  @doc """
  Disabled: raises `Stem.SecurityError`.

  Stem does not evaluate template source at runtime. Use the compile-time
  macros `function_from_string/5` and `function_from_file/5` instead.
  """
  @spec eval_string(String.t(), keyword, [compile_opt]) :: term()
  def eval_string(source, bindings \\ [], options \\ [])
      when is_binary(source) and is_list(bindings) and is_list(options) do
    _ = {source, bindings, options}
    raise Stem.SecurityError
  end

  @doc """
  Disabled: raises `Stem.SecurityError`.

  Stem does not evaluate template source at runtime. Use the compile-time
  macros `function_from_string/5` and `function_from_file/5` instead.
  """
  @spec eval_file(Path.t(), keyword, [compile_opt]) :: String.t()
  def eval_file(filename, bindings \\ [], options \\ [])
      when is_list(bindings) and is_list(options) do
    _ = {filename, bindings, options}
    raise Stem.SecurityError
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
    compile_file_internal(filename, options)
  end

  defp compile_string_internal(source, options) do
    file = options[:file] || "nofile"

    case Stem.Parser.parse(source, options) do
      {:ok, ast} ->
        Stem.Compiler.compile(ast, options)

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
    options = Keyword.merge([file: filename, line: 1], options)
    compile_string_internal(File.read!(filename), options)
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
