# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Bytecode.VM do
  @moduledoc """
  Reference interpreter for `Stem.Bytecode.Program`.

  The VM renders a compiled program against runtime bindings, producing the same
  output as the compiled backend for every program `Stem.Bytecode.compile/2` can
  emit. It is the Phase-1 reference implementation of the native backend: it
  reuses the existing runtime primitives — `Stem.Runtime.fetch_assign!/3`,
  `Stem.Transformers.invoke/3`, and `Stem.Escaping` — so assign resolution,
  transformer dispatch (including the secure Minimum-only capability default),
  and escaping are identical to `Stem.compile_string/2` by construction.

  ## Bindings

    * `:assigns` — a map or keyword list of template assigns (default `[]`).
    * `:transformers` — a map of loaded transformer groups and/or custom
      transformers (default `%{}`), exactly as passed to the compiled backend.
    * `:warn_on_missing_assigns` — when `true`, a missing assign warns instead of
      resolving to `nil` (default `false`).

  ## Example

      iex> ast = elem(Stem.Parser.parse_with_spans("Hello {{name}}"), 1)
      iex> program = Stem.Bytecode.compile(ast)
      iex> Stem.Bytecode.VM.render(program, assigns: [name: "Nina"])
      "Hello Nina"
  """

  alias Stem.Bytecode.Program

  @type bindings :: [
          {:assigns, map() | keyword()}
          | {:transformers, map()}
          | {:warn_on_missing_assigns, boolean()}
        ]

  @doc """
  Renders a `Stem.Bytecode.Program` against the given bindings.
  """
  @spec render(Program.t(), bindings()) :: binary()
  def render(%Program{instructions: instructions}, bindings \\ []) do
    context = %{
      assigns: Keyword.get(bindings, :assigns, []),
      transformers: Keyword.get(bindings, :transformers, %{}),
      warn: Keyword.get(bindings, :warn_on_missing_assigns, false)
    }

    instructions
    |> Enum.map(&exec(&1, context))
    |> IO.iodata_to_binary()
  end

  defp exec({:text, text}, _context), do: text

  defp exec({:emit, value_op, escape_mode}, context) do
    value_op
    |> eval(context)
    |> String.Chars.to_string()
    |> apply_escape(escape_mode)
  end

  defp eval({:lit, value}, _context), do: value

  defp eval({:assign, name}, context) do
    Stem.Runtime.fetch_assign!(context.assigns, name, context.warn)
  end

  defp eval({:get, base, segments}, context) do
    Enum.reduce(segments, eval(base, context), &get_field(&2, &1))
  end

  defp eval({:call, name, positional, keyword}, context) do
    args =
      Enum.map(positional, &eval(&1, context)) ++
        Enum.map(keyword, fn {key, value_op} -> {key, eval(value_op, context)} end)

    Stem.Transformers.invoke(
      String.to_atom(name),
      args,
      assigns: context.assigns,
      transformers: context.transformers
    )
  end

  # Mirror Elixir's `.` map access used by the compiled backend: an atom-keyed
  # fetch that raises on a missing key or a non-map value.
  defp get_field(value, key) when is_map(value), do: Map.fetch!(value, key)

  defp get_field(value, key) do
    raise ArgumentError,
          "cannot access field #{inspect(key)} on #{inspect(value)}: not a map"
  end

  defp apply_escape(string, :none), do: string
  defp apply_escape(string, escape_mode), do: Stem.Escaping.escape(string, escape_mode)
end
