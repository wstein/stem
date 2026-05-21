# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Compiler do
  @moduledoc false

  # Lowers a `Stem.AST` into quoted Elixir that evaluates to a binary.
  #
  # Text becomes literal binaries and `{{ }}` expressions become string output;
  # blocks become `if`/`unless` expressions, `Stem.Builtins.each/3` loops, and
  # `{{#with}}` bindings. Parsed `Stem.Expression` nodes are lowered into
  # Elixir source and then quoted with assign rewrites applied.
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
      diagnostics: Keyword.get(opts, :warn_on_diagnostics, false),
      warn_falsy: Keyword.get(opts, :warn_on_falsy_coercion, false),
      escape: Keyword.get(opts, :escape, :html),
      in_each: false,
      locals: %{},
      mode: Keyword.get(opts, :mode, :permissive)
    }

    compile_nodes(nodes, state)
  end

  defp compile_nodes(nodes, state) do
    segments = Enum.map(nodes, &compile_node(&1, state))
    quote(do: IO.iodata_to_binary(unquote(segments)))
  end

  defp compile_node({:text, text}, _state), do: text

  defp compile_node({:expr, expr_ast, escape_mode, meta}, state) do
    expr = compile_expression(expr_ast, meta, state)
    escaped = quote(do: String.Chars.to_string(unquote(expr)))
    apply_escape(escaped, escape_mode, state)
  end

  defp compile_node({:if, expr_ast, body, else_body, meta}, state) do
    warn_on_constant_condition(:if, expr_ast, meta, state)
    condition = compile_truthy_expression(expr_ast, meta, :if, state)

    quote do
      if unquote(condition),
        do: unquote(compile_nodes(body, state)),
        else: unquote(compile_nodes(else_body, state))
    end
  end

  defp compile_node({:unless, expr_ast, body, else_body, meta}, state) do
    warn_on_constant_condition(:unless, expr_ast, meta, state)
    condition = compile_truthy_expression(expr_ast, meta, :unless, state)

    quote do
      if unquote(condition),
        do: unquote(compile_nodes(else_body, state)),
        else: unquote(compile_nodes(body, state))
    end
  end

  defp compile_node({:each, expr_ast, params, body, else_body, meta}, state) do
    collection = compile_expression(expr_ast, meta, state)
    warn_on_unused_block_params(:each, params, body, meta, state)

    body_state = %{
      state
      | in_each: true,
        locals: Map.merge(state.locals, block_param_locals(:each, params))
    }

    body_ast = compile_nodes(body, body_state)
    else_ast = compile_nodes(else_body, %{state | in_each: false})

    current = genvar(:current)
    stem_key = genvar(:stem_key)
    stem_index = genvar(:stem_index)

    quote do
      Stem.Builtins.each(
        Stem.Builtins.each_entries(
          Stem.Runtime.warn_on_falsy_coercion(
            unquote(collection),
            warn_on_falsy_coercion: unquote(state.warn_falsy),
            file: unquote(state.file),
            line: unquote(meta.line),
            context: :each
          )
        ),
        fn {unquote(current), unquote(stem_key)}, unquote(stem_index) ->
          unquote_splicing(block_param_assignments(:each, params, current, stem_index))
          unquote(body_ast)
        end,
        fn -> unquote(else_ast) end
      )
    end
  end

  defp compile_node({:with, expr_ast, params, body, else_body, meta}, state) do
    subject = compile_expression(expr_ast, meta, state)
    this = genvar(:this)
    warn_on_unused_block_params(:with, params, body, meta, state)
    body_state = %{state | locals: Map.merge(state.locals, block_param_locals(:with, params))}

    quote do
      unquote(this) = unquote(subject)

      if Stem.Runtime.is_truthy(
           unquote(this),
           warn_on_falsy_coercion: unquote(state.warn_falsy),
           file: unquote(state.file),
           line: unquote(meta.line),
           context: :with
         ),
         do:
           (
             unquote_splicing(block_param_assignments(:with, params, this, nil))
             unquote(compile_nodes(body, body_state))
           ),
         else: unquote(compile_nodes(else_body, state))
    end
  end

  defp compile_expression(expr_ast, meta, state) do
    if state.mode == :safe and match?({:elixir, _}, expr_ast) do
      raise CompileError,
        file: state.file,
        line: meta.line,
        description: "safe mode forbids arbitrary Elixir expressions in Stem tags"
    end

    source = Expression.to_source(expr_ast, %{in_each: state.in_each, locals: state.locals})

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

  defp compile_truthy_expression(expr_ast, meta, context, state) do
    value = compile_expression(expr_ast, meta, state)

    quote do
      Stem.Runtime.is_truthy(
        unquote(value),
        warn_on_falsy_coercion: unquote(state.warn_falsy),
        file: unquote(state.file),
        line: unquote(meta.line),
        context: unquote(context)
      )
    end
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

  defp block_param_locals(:each, []), do: %{}
  defp block_param_locals(:each, [item]), do: %{item => item}
  defp block_param_locals(:each, [item, index]), do: %{item => item, index => index}
  defp block_param_locals(:with, []), do: %{}
  defp block_param_locals(:with, [item]), do: %{item => item}

  defp block_param_assignments(:each, [], _current, _stem_index), do: []

  defp block_param_assignments(:each, [item], current, _stem_index) do
    [quote(do: unquote(local_var(item)) = unquote(current))]
  end

  defp block_param_assignments(:each, [item, index], current, stem_index) do
    [
      quote(do: unquote(local_var(item)) = unquote(current)),
      quote(do: unquote(local_var(index)) = unquote(stem_index))
    ]
  end

  defp block_param_assignments(:with, [], _this, _unused), do: []

  defp block_param_assignments(:with, [item], this, _unused) do
    [quote(do: unquote(local_var(item)) = unquote(this))]
  end

  defp local_var(name), do: {String.to_atom(name), [generated: true], nil}

  defp warn_on_constant_condition(kind, {:literal, source}, meta, state) do
    truthy = literal_truthy?(source)
    outcome = if kind == :unless, do: !truthy, else: truthy

    warn(
      "#{kind} condition is constant and will always evaluate #{if(outcome, do: "truthy", else: "falsy")}",
      meta,
      state
    )
  end

  defp warn_on_constant_condition(_kind, _expr_ast, _meta, _state), do: :ok

  defp literal_truthy?(source) do
    trimmed = String.trim(source)

    case Code.string_to_quoted(trimmed) do
      {:ok, value} ->
        case literal_value(value) do
          :unknown -> trimmed not in ["false", "nil"]
          literal -> Stem.Runtime.is_truthy(literal)
        end

      _ ->
        trimmed not in ["false", "nil"]
    end
  end

  defp literal_value(value) when is_boolean(value) or is_nil(value) or is_number(value), do: value
  defp literal_value(value) when is_binary(value) or is_list(value), do: value
  defp literal_value({:%{}, _, []}), do: %{}
  defp literal_value(_value), do: :unknown

  defp warn_on_unused_block_params(_kind, [], _body, _meta, _state), do: :ok

  defp warn_on_unused_block_params(kind, params, body, meta, state) do
    unused = Enum.reject(params, &body_references_identifier?(body, &1))

    if unused != [] do
      warn("unused #{kind} block parameter(s): #{Enum.join(unused, ", ")}", meta, state)
    end
  end

  defp body_references_identifier?(nodes, name) do
    Enum.any?(nodes, &node_references_identifier?(&1, name))
  end

  defp node_references_identifier?({:text, _text}, _name), do: false

  defp node_references_identifier?({:expr, expr_ast, _escape_mode, _meta}, name),
    do: Expression.references_identifier?(expr_ast, name)

  defp node_references_identifier?({:if, expr_ast, body, else_body, _meta}, name),
    do:
      Expression.references_identifier?(expr_ast, name) or body_references_identifier?(body, name) or
        body_references_identifier?(else_body, name)

  defp node_references_identifier?({:unless, expr_ast, body, else_body, _meta}, name),
    do:
      Expression.references_identifier?(expr_ast, name) or body_references_identifier?(body, name) or
        body_references_identifier?(else_body, name)

  defp node_references_identifier?({:each, expr_ast, _params, body, else_body, _meta}, name),
    do:
      Expression.references_identifier?(expr_ast, name) or body_references_identifier?(body, name) or
        body_references_identifier?(else_body, name)

  defp node_references_identifier?({:with, expr_ast, _params, body, else_body, _meta}, name),
    do:
      Expression.references_identifier?(expr_ast, name) or body_references_identifier?(body, name) or
        body_references_identifier?(else_body, name)

  defp apply_escape(value, :default, state) do
    case state.escape do
      :none -> value
      escape_mode -> apply_escape(value, escape_mode, state)
    end
  end

  defp apply_escape(value, :none, _state), do: value

  defp apply_escape(value, :escape_html, _state) do
    quote do
      Stem.Escaping.escape_html(unquote(value))
    end
  end

  defp apply_escape(value, escape_mode, _state) when is_atom(escape_mode) do
    quote do
      Stem.Escaping.escape(unquote(value), unquote(escape_mode))
    end
  end

  defp warn(message, meta, state) do
    if state.diagnostics do
      IO.warn("#{state.file}:#{meta.line}: #{message}")
    end
  end
end
