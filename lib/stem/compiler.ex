# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Compiler do
  @moduledoc false

  # Lowers a `Stem.AST` into quoted Elixir that evaluates to a binary.
  #
  # Text becomes literal binaries and `{{ }}` expressions become string output;
  # blocks become `if`/`unless` expressions, `Stem.Builtins.each/3` loops, and
  # `{{#with}}` bindings. Embedded expressions are translated by
  # `Stem.Expression`, parsed with `Code.string_to_quoted!/2`, and have their
  # `@assign` references rewritten to `Stem.Runtime.fetch_assign!/3`.
  #
  # All template-introduced variables (`assigns`, `helpers`, `current`,
  # `stem_key`, `stem_index`, `this`) are emitted with a `nil` context so they
  # unify with the variables produced by parsing embedded expression source.

  alias Stem.Expression

  @spec compile(Stem.AST.t(), keyword()) :: Macro.t()
  def compile(nodes, opts \\ []) when is_list(nodes) and is_list(opts) do
    state = %{
      file: opts[:file] || "nofile",
      warn: Keyword.get(opts, :warn_on_missing_assigns, false),
      in_each: false
    }

    compile_nodes(nodes, state)
  end

  defp compile_nodes(nodes, state) do
    segments = Enum.map(nodes, &compile_node(&1, state))
    quote(do: IO.iodata_to_binary(unquote(segments)))
  end

  defp compile_node({:text, text}, _state), do: text

  defp compile_node({:expr, raw, meta}, state) do
    expr = compile_expression(raw, meta, state)
    quote(do: String.Chars.to_string(unquote(expr)))
  end

  defp compile_node({:if, raw, body, else_body, meta}, state) do
    condition = compile_expression(raw, meta, state)

    quote do
      if unquote(condition),
        do: unquote(compile_nodes(body, state)),
        else: unquote(compile_nodes(else_body, state))
    end
  end

  defp compile_node({:unless, raw, body, else_body, meta}, state) do
    condition = compile_expression(raw, meta, state)

    quote do
      if unquote(condition),
        do: unquote(compile_nodes(else_body, state)),
        else: unquote(compile_nodes(body, state))
    end
  end

  defp compile_node({:each, raw, body, else_body, meta}, state) do
    collection = compile_expression(raw, meta, state)
    body_ast = compile_nodes(body, %{state | in_each: true})
    else_ast = compile_nodes(else_body, %{state | in_each: false})

    current = genvar(:current)
    stem_key = genvar(:stem_key)
    stem_index = genvar(:stem_index)

    quote do
      Stem.Builtins.each(
        Stem.Builtins.each_entries(unquote(collection)),
        fn {unquote(current), unquote(stem_key)}, unquote(stem_index) -> unquote(body_ast) end,
        fn -> unquote(else_ast) end
      )
    end
  end

  defp compile_node({:with, raw, body, else_body, meta}, state) do
    subject = compile_expression(raw, meta, state)
    this = genvar(:this)

    quote do
      unquote(this) = unquote(subject)

      if unquote(this),
        do: unquote(compile_nodes(body, state)),
        else: unquote(compile_nodes(else_body, state))
    end
  end

  defp compile_expression(raw, meta, state) do
    source = Expression.translate(raw, %{in_each: state.in_each})

    if String.contains?(source, "../") do
      raise CompileError,
        file: state.file,
        line: meta.line,
        description: "unsupported parent path traversal (`../`) in Stem expression"
    end

    source
    |> Code.string_to_quoted!(file: state.file, line: meta.line, column: meta.column)
    |> Macro.prewalk(&rewrite_assign(&1, state.warn))
  end

  defp rewrite_assign({:@, meta, [{name, _name_meta, atom}]}, warn)
       when is_atom(name) and is_atom(atom) do
    line = meta[:line] || 0
    assigns = Macro.var(:assigns, nil)

    quote line: line do
      Stem.Runtime.fetch_assign!(unquote(assigns), unquote(name), unquote(warn))
    end
  end

  defp rewrite_assign(node, _warn), do: node

  # Variables introduced by the compiler. The `generated: true` flag keeps the
  # compiler from warning when a loop or `with` binding goes unused in a body.
  defp genvar(name), do: {name, [generated: true], nil}
end
