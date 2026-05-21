# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

defmodule Stem.Engine do
  @moduledoc ~S"""
  Basic Stem engine that ships with Elixir.

  An engine needs to implement all callbacks below.

  This module also ships with a default engine implementation
  you can delegate to. See `Stem.SmartEngine` as an example.
  """

  @type state :: term

  @doc """
  Called at the beginning of every template.

  It receives the options during compilation, including the
  ones managed by Stem, such as `:line` and `:file`, as well
  as custom engine options.

  It must return the initial state.
  """
  @callback init(opts :: keyword) :: state

  @doc """
  Called at the end of every template.

  It must return Elixir's quoted expressions for the template.
  """
  @callback handle_body(state) :: Macro.t()

  @doc """
  Called for the text/static parts of a template.

  It must return the updated state.
  """
  @callback handle_text(state, [line: pos_integer, column: pos_integer], text :: String.t()) ::
              state

  @doc """
  Called for the dynamic/code parts of a template.

  The marker is what follows exactly after `<%`. For example,
  `<% foo %>` has an empty marker, but `<%= foo %>` has `"="`
  as marker. The allowed markers so far are:

    * `""`
    * `"="`
    * `"/"`
    * `"|"`

  Markers `"/"` and `"|"` are only for use in custom Stem engines
  and are not implemented by default. Using them without an
  appropriate implementation raises `Stem.SyntaxError`.

  It must return the updated state.
  """
  @callback handle_expr(state, marker :: String.t(), expr :: Macro.t()) :: state

  @doc """
  Invoked at the beginning of every nesting.

  It must return a new state that is used only inside the nesting.
  Once the nesting terminates, the current `state` is resumed.
  """
  @callback handle_begin(state) :: state

  @doc """
  Invokes at the end of a nesting.

  It must return Elixir's quoted expressions for the nesting.
  """
  @callback handle_end(state) :: Macro.t()

  @doc false
  @deprecated "Use explicit delegation to Stem.Engine instead"
  defmacro __using__(_) do
    quote do
      @behaviour Stem.Engine

      def init(opts) do
        Stem.Engine.init(opts)
      end

      def handle_body(state) do
        Stem.Engine.handle_body(state)
      end

      def handle_begin(state) do
        Stem.Engine.handle_begin(state)
      end

      def handle_end(state) do
        Stem.Engine.handle_end(state)
      end

      def handle_text(state, text) do
        Stem.Engine.handle_text(state, [], text)
      end

      def handle_expr(state, marker, expr) do
        Stem.Engine.handle_expr(state, marker, expr)
      end

      defoverridable Stem.Engine
    end
  end

  @doc """
  Handles assigns in quoted expressions.

  By default missing assigns return `nil` without warning.
  Set `:warn_on_missing_assigns` to `true` to print a warning.

  This can be added to any custom engine by invoking
  `handle_assign/2` with `Macro.prewalk/2`:

      def handle_expr(state, token, expr) do
        expr = Macro.prewalk(expr, &Stem.Engine.handle_assign(&1, false))
        super(state, token, expr)
      end

  """
  @spec handle_assign(Macro.t()) :: Macro.t()
  def handle_assign(assign), do: handle_assign(assign, false)

  @spec handle_assign(Macro.t(), boolean()) :: Macro.t()
  def handle_assign({:@, meta, [{name, _, atom}]}, warn_on_missing_assigns)
      when is_atom(name) and is_atom(atom) do
    line = meta[:line] || 0

    quote(
      line: line,
      do:
        Stem.Engine.fetch_assign!(
          var!(assigns),
          unquote(name),
          unquote(warn_on_missing_assigns)
        )
    )
  end

  def handle_assign(arg, _warn_on_missing_assigns) do
    arg
  end

  @doc false
  @spec fetch_assign!(Access.t(), Access.key(), boolean()) :: term | nil
  def fetch_assign!(assigns, key, warn_on_missing_assigns \\ false) do
    case Access.fetch(assigns, key) do
      {:ok, val} ->
        val

      :error ->
        if warn_on_missing_assigns do
          keys = Enum.map(assigns, &elem(&1, 0))

          IO.warn(
            "assign @#{key} not available in Stem template. " <>
              "Please ensure all assigns are given as options. " <>
              "Available assigns: #{inspect(keys)}"
          )
        end

        nil
    end
  end

  @doc "Default implementation for `c:init/1`."
  def init(_opts) do
    %{
      binary: [],
      dynamic: [],
      vars_count: 0
    }
  end

  @doc "Default implementation for `c:handle_begin/1`."
  def handle_begin(state) do
    check_state!(state)
    %{state | binary: [], dynamic: []}
  end

  @doc "Default implementation for `c:handle_end/1`."
  def handle_end(quoted) do
    handle_body(quoted)
  end

  @doc "Default implementation for `c:handle_body/1`."
  def handle_body(state) do
    check_state!(state)
    %{binary: binary, dynamic: dynamic} = state
    binary = {:<<>>, [], Enum.reverse(binary)}
    dynamic = [binary | dynamic]
    {:__block__, [], Enum.reverse(dynamic)}
  end

  @doc "Default implementation for `c:handle_text/3`."
  def handle_text(state, _meta, text) do
    check_state!(state)
    %{binary: binary} = state
    %{state | binary: [text | binary]}
  end

  @doc "Default implementation for `c:handle_expr/3`."
  def handle_expr(state, "=", ast) do
    append_expression(state, ast)
  end

  def handle_expr(state, "|", ast) do
    escaped =
      quote do
        Stem.HTML.escape_to_string(unquote(ast))
      end

    append_expression(state, escaped)
  end

  def handle_expr(state, "", ast) do
    %{dynamic: dynamic} = state
    %{state | dynamic: [ast | dynamic]}
  end

  def handle_expr(_state, marker, _ast) when marker in ["/"] do
    raise Stem.SyntaxError,
          "unsupported Stem syntax <%#{marker} %> (the syntax is valid but not supported by the current Stem engine)"
  end

  defp append_expression(state, ast) do
    check_state!(state)
    %{binary: binary, dynamic: dynamic, vars_count: vars_count} = state
    var = Macro.var(:"arg#{vars_count}", __MODULE__)

    ast =
      quote do
        unquote(var) = String.Chars.to_string(unquote(ast))
      end

    segment =
      quote do
        unquote(var) :: binary
      end

    %{state | dynamic: [ast | dynamic], binary: [segment | binary], vars_count: vars_count + 1}
  end

  defp check_state!(%{binary: _, dynamic: _, vars_count: _}), do: :ok

  defp check_state!(state) do
    raise "unexpected Stem.Engine state: #{inspect(state)}. " <>
            "This typically means a bug or an outdated Stem.Engine or tool"
  end
end
