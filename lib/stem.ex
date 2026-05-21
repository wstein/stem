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
  Stem is the structural backbone for Handlebars templates in Elixir.

  Stem provides a robust DSL for generating dynamic content by allowing
  developers to embed Elixir logic securely using a familiar double-curly-brace
  syntax. By leveraging Elixir's powerful macro system, Stem translates
  Handlebars-compliant templates into efficient, compiled Elixir code.

      iex> Stem.eval_string("foo {{bar}}", assigns: [bar: "baz"])
      "foo baz"

  This module provides three main APIs for you to use:

    1. Evaluate a string (`eval_string/3`) or a file (`eval_file/3`)
       directly. This is the simplest API to use but also the
       slowest, since the code is evaluated at runtime and not precompiled.

    2. Define a function from a string (`function_from_string/5`)
       or a file (`function_from_file/5`). This allows you to embed
       the template as a function inside a module which will then
       be compiled. This is the preferred API if you have access
       to the template at compilation time.

    3. Compile a string (`compile_string/2`) or a file (`compile_file/2`)
       into Elixir syntax tree. This is the API used by both functions
       above and is available to you if you want to provide your own
       ways of handling the compiled template.

  The APIs above support several options, documented below. You may
  also pass an engine which customizes how the Stem code is compiled.

  ## Options

  All functions in this module, unless otherwise noted, accept Stem-related
  options. They are:

    * `:file` - the file to be used in the template. Defaults to the given
      file the template is read from or to `"nofile"` when compiling from a string.

    * `:line` - the line to be used as the template start. Defaults to `1`.

    * `:indentation` - (since v1.11.0) an integer added to the column after every
      new line. Defaults to `0`.

    * `:engine` - the Stem engine to be used for compilation. Defaults to `Stem.SmartEngine`.

    * `:trim` - if `true`, trims whitespace left and right of quotation as
      long as at least one newline is present. All subsequent newlines and
      spaces are removed but one newline is retained. Defaults to `false`.

    * `:parser_options` - (since: 1.13.0) allow customizing the parsed code
      that is generated. See `Code.string_to_quoted/2` for available options.
      Note that the options `:file`, `:line` and `:column` are ignored if
      passed in. Defaults to `Code.get_compiler_option(:parser_options)`
      (which defaults to `[]` if not set).

    * `:warn_on_missing_assigns` - when `true`, missing assigns print a
      warning instead of returning `nil` silently. Defaults to `false`.

  ## Syntax

  Stem supports multiple tags, declared below:

      {{expression}}: executes Elixir logic and prints result
      {{{{quotation}}}}: returns the contents inside the tag as is
      {{! comments }}: they are discarded from source

  Block conditionals follow Elixir truthiness. Only `false` and `nil` are
  treated as falsey; values such as `0`, "", and [] are truthy. For compound
  checks that should treat `0` as false, use `&&`, `||`, and parentheses in
  expressions such as `{{#if (render && render != 0) || fallback}}`.

  ## Engine

  Stem has the concept of engines which allows you to modify or
  transform the code extracted from the given string or file.

  By default, `Stem` uses the `Stem.SmartEngine` that provides some
  conveniences on top of the simple `Stem.Engine`.

  ### `Stem.SmartEngine`

  The smart engine uses Stem default rules and adds the `@` construct
  for reading template assigns:

      iex> Stem.eval_string("{{foo}}", assigns: [foo: 1])
      "1"

  In other words, `{{@foo}}` translates to:

      {{ {:ok, v} = Access.fetch(assigns, :foo); v }}

  The `assigns` extension is useful when the number of variables
  required by the template is not specified at compilation time.

  Missing assigns return `nil` by default. Pass `warn_on_missing_assigns: true`
  to print a warning for missing values.
  """

  @type line :: non_neg_integer
  @type column :: non_neg_integer
  @type marker :: [?=] | [?/] | [?|] | []
  @type metadata :: %{column: column, line: line}
  @type token ::
          {:comment, charlist, metadata}
          | {:text, charlist, metadata}
          | {:expr | :start_expr | :middle_expr | :end_expr, marker, charlist, metadata}
          | {:eof, metadata}

  @type tokenize_opt ::
          {:file, binary()}
          | {:line, line}
          | {:column, column}
          | {:indentation, non_neg_integer}
          | {:trim, boolean()}

  @type compile_opt ::
          tokenize_opt
          | {:engine, module()}
          | {:parser_options, Code.parser_opts()}
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
  Gets a string `source` and generates a quoted expression
  that can be evaluated by Elixir or compiled to a function.

  This is useful if you want to compile a Stem template into code and inject
  that code somewhere or evaluate it at runtime.

  The generated quoted code will use variables defined in the template that
  will be taken from the context where the code is evaluated. If you
  have a template such as `{{a}}`, then the returned quoted code
  will use the `a` and `b` variables in the context where it's evaluated. See
  examples below.

  The supported `options` are described [in the module docs](#module-options).

  ## Examples

      iex> quoted = Stem.compile_string("{{a}}")
      iex> {result, _bindings} = Code.eval_quoted(quoted, assigns: [a: 1])
      iex> result
      "1"

  """
  @spec compile_string(String.t(), [compile_opt]) :: Macro.t()
  def compile_string(source, options \\ []) when is_binary(source) and is_list(options) do
    _ = {source, options}
    raise Stem.SecurityError
  end

  @doc """
  Gets a `filename` and generates a quoted expression
  that can be evaluated by Elixir or compiled to a function.

  This is useful if you want to compile a Stem template into code and inject
  that code somewhere or evaluate it at runtime.

  The generated quoted code will use variables defined in the template that
  will be taken from the context where the code is evaluated. If you
  have a template such as `{{a}}`, then the returned quoted code
  will use the `a` and `b` variables in the context where it's evaluated. See
  examples below.

  The supported `options` are described [in the module docs](#module-options).

  ## Examples

      # sample.stem
      {{a}}

      # In code:
      quoted = Stem.compile_file("sample.stem")
      {result, _bindings} = Code.eval_quoted(quoted, assigns: [a: 1])
      result
      #=> "1"

  """
  @spec compile_file(Path.t(), [compile_opt]) :: Macro.t()
  def compile_file(filename, options \\ []) when is_list(options) do
    _ = {filename, options}
    raise Stem.SecurityError
  end

  @doc """
  Gets a string `source` and evaluate the values using the `bindings`.

  The supported `options` are described [in the module docs](#module-options).

  ## Examples

      iex> Stem.eval_string("foo {{bar}}", assigns: [bar: "baz"])
      "foo baz"

  """
  @spec eval_string(String.t(), keyword, [compile_opt]) :: term()
  def eval_string(source, bindings \\ [], options \\ [])
      when is_binary(source) and is_list(bindings) and is_list(options) do
    _ = {source, bindings, options}
    raise Stem.SecurityError
  end

  @doc """
  Gets a `filename` and evaluate the values using the `bindings`.

  The supported `options` are described [in the module docs](#module-options).

  ## Examples

      # sample.stem
      foo {{bar}}

      # IEx
      Stem.eval_file("sample.stem", assigns: [bar: "baz"])
      #=> "foo baz"

  """
  @spec eval_file(Path.t(), keyword, [compile_opt]) :: String.t()
  def eval_file(filename, bindings \\ [], options \\ [])
      when is_list(bindings) and is_list(options) do
    _ = {filename, bindings, options}
    raise Stem.SecurityError
  end

  @doc """
  Tokenize the given contents according to the given options.

  ## Options

    * `:line` - An integer to start as line. Default is 1.
    * `:column` - An integer to start as column. Default is 1.
    * `:indentation` - An integer that indicates the indentation. Default is 0.
    * `:trim` - Tells the tokenizer to either trim the content or not. Default is false.
    * `:file` - Can be either a file or a string "nofile".

  ## Examples

      iex> Stem.tokenize(~c"foo", line: 1, column: 1)
      {:ok, [{:text, ~c"foo", %{column: 1, line: 1}}, {:eof, %{column: 4, line: 1}}]}

  ## Result

  It returns `{:ok, [token]}` where a token is one of:

    * `{:text, content, %{column: column, line: line}}`
    * `{:expr, marker, content, %{column: column, line: line}}`
    * `{:start_expr, marker, content, %{column: column, line: line}}`
    * `{:middle_expr, marker, content, %{column: column, line: line}}`
    * `{:end_expr, marker, content, %{column: column, line: line}}`
    * `{:eof, %{column: column, line: line}}`

  Or `{:error, message, %{column: column, line: line}}` in case of errors.
  Note new tokens may be added in the future.
  """
  @doc since: "1.14.0"
  @spec tokenize([char()] | String.t(), [tokenize_opt]) ::
          {:ok, [token()]} | {:error, String.t(), metadata()}
  def tokenize(contents, opts \\ []) do
    Stem.Compiler.tokenize(contents, opts)
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

    with {:ok, preprocessed} <- Stem.Preprocessor.preprocess(source, options) do
      tokenize_opts = Keyword.take(options, [:file, :line, :column, :indentation, :trim])

      case tokenize(preprocessed, tokenize_opts) do
        {:ok, tokens} ->
          validate_unsupported_parent_traversal!(tokens, file)
          Stem.Compiler.compile(tokens, preprocessed, options)

        {:error, message, %{column: column, line: line}} ->
          raise Stem.SyntaxError, file: file, line: line, column: column, message: message
      end
    else
      {:error, message, %{column: column, line: line}} ->
        raise Stem.SyntaxError, file: file, line: line, column: column, message: message
    end
  end

  defp compile_file_internal(filename, options) do
    options = Keyword.merge([file: filename, line: 1], options)
    compile_string_internal(File.read!(filename), options)
  end

  defp validate_unsupported_parent_traversal!(tokens, file) do
    Enum.each(tokens, fn
      {token_kind, _marker, expr, %{line: line}}
      when token_kind in [:expr, :start_expr, :middle_expr, :end_expr] ->
        if String.contains?(List.to_string(expr), "../") do
          raise CompileError,
            file: file,
            line: line,
            description: "unsupported parent path traversal (`../`) in Stem expression"
        end

      _ ->
        :ok
    end)
  end
end
