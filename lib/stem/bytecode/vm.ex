# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Bytecode.VM do
  @moduledoc """
  Reference interpreter for `Stem.Bytecode.Program`.

  The VM renders a compiled program against runtime bindings, producing the same
  output as the compiled backend for every program `Stem.Bytecode.compile/2` can
  emit. It is the Phase-1 reference implementation of the native backend: it
  reuses the existing runtime primitives — `Stem.Runtime.fetch_assign!/3`,
  `Stem.Runtime.truthy?/1`, `Stem.Builtins.each/3`, `Stem.Transformers.invoke/3`,
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
    assigns = Keyword.get(bindings, :assigns, [])

    context = %{
      assigns: assigns,
      transformers: Keyword.get(bindings, :transformers, %{}),
      warn: Keyword.get(bindings, :warn_on_missing_assigns, false),
      # The root context: `@this`/`@root` resolve to the render assigns; there is
      # no enclosing context and no active iteration.
      this: assigns,
      root: assigns,
      parent: nil,
      index: nil,
      key: nil,
      first: nil,
      last: nil,
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
    if Stem.Runtime.truthy?(eval(cond_op, context)) do
      render_instructions(then_branch, context)
    else
      render_instructions(else_branch, context)
    end
  end

  defp exec({:each, collection_op, params, body, else_branch}, context) do
    Stem.Builtins.each(
      Stem.Builtins.each_entries(eval(collection_op, context)),
      fn {current, key}, index, first, last ->
        render_instructions(
          body,
          each_context(context, params, current, key, index, first, last)
        )
      end,
      fn -> render_instructions(else_branch, %{context | in_each: false}) end
    )
  end

  defp exec({:with, subject_op, params, body, else_branch}, context) do
    subject = eval(subject_op, context)

    if Stem.Runtime.truthy?(subject) do
      render_instructions(body, with_context(context, params, subject))
    else
      render_instructions(else_branch, context)
    end
  end

  defp exec({:scope, base_op, hash, body}, context) do
    base = eval(base_op, context)
    hash_map = Map.new(hash, fn {key, value_op} -> {key, eval(value_op, context)} end)
    render_instructions(body, scope_context(context, Stem.Runtime.partial_scope(base, hash_map)))
  end

  # Block parameters mirror the compiled backend's bindings:
  #   |item|              -> item
  #   |item key|          -> item, key (the map key, or the index for lists)
  #   |item index0 index1| -> item, zero-based index, one-based index
  defp each_context(context, params, current, key, index, first, last) do
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

    %{
      context
      | this: current,
        parent: context.this,
        key: key,
        index: index,
        first: first,
        last: last,
        in_each: true,
        locals: locals
    }
  end

  defp with_context(context, params, subject) do
    locals =
      case params do
        [] -> context.locals
        [item] -> Map.put(context.locals, item, subject)
      end

    %{context | this: subject, parent: context.this, locals: locals}
  end

  # A partial scope rebinds the assigns to the merged scope map and resets the
  # block-scoped state, mirroring the compiled backend's fresh non-each scope.
  defp scope_context(context, assigns) do
    %{
      context
      | assigns: assigns,
        this: assigns,
        root: assigns,
        parent: nil,
        index: nil,
        key: nil,
        first: nil,
        last: nil,
        in_each: false,
        locals: %{}
    }
  end

  defp eval({:lit, value}, _context), do: value

  defp eval({:assign, name}, context) do
    Stem.Runtime.fetch_assign!(context.assigns, name, context.warn)
  end

  defp eval({:assigns}, context), do: context.assigns

  defp eval({:local, name}, context), do: Map.fetch!(context.locals, name)
  defp eval({:this}, context), do: context.this
  defp eval({:parent}, context), do: context.parent
  defp eval({:root}, context), do: context.root
  defp eval({:index}, context), do: context.index
  defp eval({:index1}, context), do: context.index + 1
  defp eval({:key}, context), do: context.key
  defp eval({:first}, context), do: context.first
  defp eval({:last}, context), do: context.last

  defp eval({:get, base, segments}, context) do
    Enum.reduce(segments, eval(base, context), fn segment, acc ->
      Stem.Runtime.get_field(acc, segment)
    end)
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

  defp apply_escape(string, :none), do: string
  defp apply_escape(string, escape_mode), do: Stem.Escaping.escape(string, escape_mode)
end
