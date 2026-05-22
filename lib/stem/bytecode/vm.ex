# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Bytecode.VM do
  @moduledoc """
  Reference interpreter for `Stem.Bytecode.Program`.

  The VM renders a compiled program against runtime bindings, producing the same
  output as the compiled backend for every program `Stem.Bytecode.compile/2` can
  emit. It is the Phase-1 reference implementation of the native backend: it
  reuses the existing runtime primitives — `Stem.Runtime.fetch_assign!/3`,
  `Stem.Runtime.is_truthy/1`, `Stem.Builtins.each/3`, `Stem.Transformers.invoke/3`,
  and `Stem.Escaping` — so assign resolution, block semantics, transformer
  dispatch (including the secure Minimum-only capability default), and escaping
  are identical to `Stem.compile_string/2` by construction.

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
      warn: Keyword.get(bindings, :warn_on_missing_assigns, false),
      this: nil,
      index: nil,
      key: nil,
      in_each: false,
      locals: %{}
    }

    render_instructions(instructions, context)
  end

  defp render_instructions(instructions, context) do
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

  defp exec({:if, cond_op, then_branch, else_branch}, context) do
    if Stem.Runtime.is_truthy(eval(cond_op, context)) do
      render_instructions(then_branch, context)
    else
      render_instructions(else_branch, context)
    end
  end

  defp exec({:each, collection_op, params, body, else_branch}, context) do
    Stem.Builtins.each(
      Stem.Builtins.each_entries(eval(collection_op, context)),
      fn {current, key}, index ->
        render_instructions(body, each_context(context, params, current, key, index))
      end,
      fn -> render_instructions(else_branch, %{context | in_each: false}) end
    )
  end

  defp exec({:with, subject_op, params, body, else_branch}, context) do
    subject = eval(subject_op, context)

    if Stem.Runtime.is_truthy(subject) do
      render_instructions(body, with_context(context, params, subject))
    else
      render_instructions(else_branch, context)
    end
  end

  # Block parameters mirror the compiled backend's bindings:
  #   |item|              -> item
  #   |item key|          -> item, key (the map key, or the index for lists)
  #   |item index0 index1| -> item, zero-based index, one-based index
  defp each_context(context, params, current, key, index) do
    locals =
      case params do
        [] ->
          context.locals

        [item] ->
          Map.put(context.locals, item, current)

        [item, key_name] ->
          context.locals |> Map.put(item, current) |> Map.put(key_name, key || index)

        [item, index0, index1] ->
          context.locals
          |> Map.put(item, current)
          |> Map.put(index0, index)
          |> Map.put(index1, index + 1)
      end

    %{context | this: current, key: key, index: index, in_each: true, locals: locals}
  end

  defp with_context(context, params, subject) do
    locals =
      case params do
        [] -> context.locals
        [item] -> Map.put(context.locals, item, subject)
      end

    %{context | this: subject, locals: locals}
  end

  defp eval({:lit, value}, _context), do: value

  defp eval({:assign, name}, context) do
    Stem.Runtime.fetch_assign!(context.assigns, name, context.warn)
  end

  defp eval({:local, name}, context), do: Map.fetch!(context.locals, name)
  defp eval({:this}, context), do: context.this
  defp eval({:index}, context), do: context.index
  defp eval({:index1}, context), do: context.index + 1
  defp eval({:key}, context), do: context.key

  defp eval({:get, base, segments}, context) do
    Enum.reduce(segments, eval(base, context), &get_field(&2, &1))
  end

  defp eval({:call, name, positional, keyword}, context) do
    args =
      Enum.map(positional, &eval(&1, context)) ++
        Enum.map(keyword, fn {key, value_op} -> {key, eval(value_op, context)} end)

    Stem.Transformers.invoke(String.to_atom(name), args, invoke_bindings(context))
  end

  # Mirror the compiled backend's transformer context: inside an each loop the
  # current item and key are passed so context-aware transformers can read them.
  defp invoke_bindings(%{in_each: true} = context) do
    [
      this: context.this,
      key: context.key,
      assigns: context.assigns,
      transformers: context.transformers
    ]
  end

  defp invoke_bindings(context) do
    [assigns: context.assigns, transformers: context.transformers]
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
