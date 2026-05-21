# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Preprocessor do
  @moduledoc false

  @type metadata :: %{line: pos_integer(), column: pos_integer()}

  @spec preprocess(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t(), metadata()}
  def preprocess(source, options \\ []) when is_binary(source) and is_list(options) do
    partials = options |> Keyword.get(:partials, %{}) |> normalize_partials()
    do_preprocess(source, 1, 1, [], partials, [], [])
  end

  defp do_preprocess(<<"{{{{", rest::binary>>, line, column, acc, partials, stack, ctx) do
    with {:ok, quoted, tail, consumed} <- take_until(rest, "}}}}") do
      {line, column} = advance("{{{{" <> consumed, line, column)
      do_preprocess(tail, line, column, [acc, quoted], partials, stack, ctx)
    else
      :error ->
        {:error, "expected closing '}}}}' for Stem quotation", %{line: line, column: column}}
    end
  end

  defp do_preprocess(<<"{{!--", rest::binary>>, line, column, acc, partials, stack, ctx) do
    with {:ok, comment, tail, consumed} <- take_until(rest, "--}}") do
      {line, column} = advance("{{!--" <> consumed, line, column)
      do_preprocess(tail, line, column, [acc, "<%!--", comment, "--%>"], partials, stack, ctx)
    else
      :error ->
        {:error, "expected closing '--}}' for Stem comment", %{line: line, column: column}}
    end
  end

  defp do_preprocess(<<"{{{", rest::binary>>, line, column, acc, partials, stack, ctx) do
    with {:ok, expr, tail, consumed} <- take_until(rest, "}}}") do
      {line, column} = advance("{{{" <> consumed, line, column)
      expr = inline_expression(expr, ctx)
      do_preprocess(tail, line, column, [acc, "<%=", expr, "%>"], partials, stack, ctx)
    else
      :error ->
        {:error, "expected closing '}}}' for Stem expression", %{line: line, column: column}}
    end
  end

  defp do_preprocess(<<"{{!", rest::binary>>, line, column, acc, partials, stack, ctx) do
    with {:ok, comment, tail, consumed} <- take_until(rest, "}}") do
      {line, column} = advance("{{!" <> consumed, line, column)
      do_preprocess(tail, line, column, [acc, "<%!--", comment, "--%>"], partials, stack, ctx)
    else
      :error ->
        {:error, "expected closing '}}' for Stem comment", %{line: line, column: column}}
    end
  end

  defp do_preprocess(<<"{{", rest::binary>>, line, column, acc, partials, stack, ctx) do
    with {:ok, raw_tag, tail, consumed} <- take_until(rest, "}}"),
         {:ok, translated, new_ctx} <- translate_tag(raw_tag, partials, stack, ctx, line, column) do
      {line, column} = advance("{{" <> consumed, line, column)
      do_preprocess(tail, line, column, [acc, translated], partials, stack, new_ctx)
    else
      :error ->
        {:error, "expected closing '}}' for Stem expression", %{line: line, column: column}}

      {:error, _message, _meta} = error ->
        error
    end
  end

  defp do_preprocess(<<char::utf8, rest::binary>>, line, column, acc, partials, stack, ctx) do
    {line, column} = advance(<<char::utf8>>, line, column)
    do_preprocess(rest, line, column, [acc, <<char::utf8>>], partials, stack, ctx)
  end

  defp do_preprocess(<<>>, _line, _column, acc, _partials, _stack, _ctx) do
    {:ok, IO.iodata_to_binary(acc)}
  end

  defp translate_tag(raw_tag, partials, stack, ctx, line, column) do
    tag = String.trim(raw_tag)

    cond do
      tag == "" ->
        {:ok, "<%|\"\"%>", ctx}

      String.starts_with?(tag, "#if ") ->
        expr = parse_block_condition(tag, "#if")

        {:ok, "<%=value = #{inline_expression(expr, ctx)}; if value do %>", ctx}

      String.starts_with?(tag, "#unless ") ->
        expr = parse_block_condition(tag, "#unless")

        {:ok, "<%=value = #{inline_expression(expr, ctx)}; unless value do %>", ctx}

      String.starts_with?(tag, "#each ") ->
        expr = tag |> String.trim_leading("#each") |> inline_expression(ctx)

        {:ok,
         "<%=Stem.Builtins.each(Stem.Builtins.each_entries(#{expr}), fn {current, stem_key}, stem_index -> %><% _ = current %><% _ = stem_index %><% _ = stem_key %>",
         [:each_do | ctx]}

      String.starts_with?(tag, "#with ") ->
        expr = parse_block_condition(tag, "#with")

        {:ok, "<%=this = #{inline_expression(expr, ctx)}; if this do %>", [:with | ctx]}

      tag == "else" ->
        translate_else(ctx, line, column)

      tag == "/if" or tag == "/unless" or tag == "/each" or tag == "/with" ->
        {:ok, close_block(tag, ctx), pop_ctx(ctx, tag)}

      String.starts_with?(tag, "/") ->
        {:error, "unsupported Stem closing tag '{{#{tag}}}'", %{line: line, column: column}}

      String.starts_with?(tag, ">") ->
        partial_name = tag |> String.trim_leading(">") |> String.trim()
        resolve_partial(partial_name, partials, stack, ctx, line, column)

      true ->
        {:ok, "<%|#{inline_expression(tag, ctx)}%>", ctx}
    end
  end

  defp resolve_partial("", _partials, _stack, _ctx, line, column) do
    {:error, "partial name is required in '{{> ...}}'", %{line: line, column: column}}
  end

  defp resolve_partial(name, partials, stack, ctx, line, column) do
    if name in stack do
      {:error, "partial recursion detected for '#{name}'", %{line: line, column: column}}
    else
      case Map.fetch(partials, name) do
        {:ok, content} ->
          with {:ok, translated} <-
                 do_preprocess(content, 1, 1, [], partials, [name | stack], ctx) do
            {:ok, translated, ctx}
          end

        :error ->
          {:error, "unknown partial '#{name}'", %{line: line, column: column}}
      end
    end
  end

  defp translate_else([:each_do | ctx], _line, _column), do: {:ok, "<% end, fn -> %>", [:each_else | ctx]}

  defp translate_else([:each_else | _], line, column),
    do: {:error, "multiple '{{else}}' blocks are not supported inside '{{#each}}'", %{line: line, column: column}}

  defp translate_else(ctx, _line, _column), do: {:ok, "<% else %>", ctx}

  defp close_block("/each", [:each_do | _]), do: "<% end) %>"
  defp close_block("/each", [:each_else | _]), do: "<% end) %>"
  defp close_block(_tag, _ctx), do: "<% end %>"

  defp inline_expression(expr, ctx) do
    trimmed = String.trim(expr)

    cond do
      trimmed == "" ->
        "\"\""

      trimmed in ["true", "false", "nil"] ->
        trimmed

      trimmed == "@index" ->
        if in_each_context?(ctx), do: "stem_index", else: trimmed

      trimmed == "@key" ->
        if in_each_context?(ctx), do: "stem_key", else: trimmed

      trimmed == "this" ->
        if in_each_context?(ctx), do: "current", else: trimmed

      helper_invocation(trimmed, ctx) ->
        {:ok, name, args} = helper_invocation(trimmed, ctx)
        parsed_args = Enum.map_join(args, ", ", & &1)
        "Stem.Helpers.invoke(:#{name}, [#{parsed_args}], #{helper_context_expression(ctx)})"

      String.starts_with?(trimmed, "../") and valid_parent_identifier?(trimmed) ->
        stripped = strip_parent_segments(trimmed)
        "@#{stripped}"

      path_expression?(trimmed) ->
        prefix_path_expression(trimmed, ctx)

      simple_identifier?(trimmed) and trimmed != "this" ->
        if in_each_context?(ctx) do
          "current.#{trimmed}"
        else
          "@#{trimmed}"
        end

      true ->
        rewrite_assigns_in_expression(expr, ctx)
    end
  end

  defp rewrite_assigns_in_expression(expr, ctx) do
    Regex.replace(~r/(?<![@\w.])([a-z_][a-zA-Z0-9_]*)(?![\w.])/, expr, fn token ->
      case token do
        "and" -> token
        "or" -> token
        "not" -> token
        "true" -> token
        "false" -> token
        "nil" -> token
        "this" -> token

        _ ->
          if in_each_context?(ctx) do
            "this.#{token}"
          else
            "@#{token}"
          end
      end
    end)
  end
  defp in_each_context?(ctx), do: Enum.any?(ctx, &(&1 == :each_do))

  defp strip_parent_segments("../" <> rest), do: strip_parent_segments(rest)
  defp strip_parent_segments(rest), do: rest

  defp valid_parent_identifier?(expr) do
    expr
    |> strip_parent_segments()
    |> simple_identifier?()
  end

  defp pop_ctx(ctx, "/each"), do: pop_ctx(ctx, :each_do) |> pop_ctx(:each_else)
  defp pop_ctx(ctx, "/with"), do: pop_ctx(ctx, :with)
  defp pop_ctx([level | rest], level), do: rest
  defp pop_ctx(ctx, _), do: ctx

  defp helper_invocation(expr, ctx) do
    case helper_tokens(expr) do
      [name | args] when args != [] ->
        if helper_name?(name) do
          case parse_helper_args(args, ctx) do
            {:ok, parsed_args} -> {:ok, name, parsed_args}
            :error -> false
          end
        else
          false
        end

      _ ->
        false
    end
  end

  defp helper_name?(name), do: String.match?(name, ~r/^[a-z_][a-zA-Z0-9_]*$/)

  defp helper_tokens(expr) when is_binary(expr) do
    Regex.scan(~r/"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^\s]+/s, expr)
    |> List.flatten()
  end

  defp parse_helper_args(args, ctx) do
    Enum.reduce_while(args, {:ok, []}, fn token, {:ok, acc} ->
      case helper_argument_expression(token, ctx) do
        {:ok, expr} -> {:cont, {:ok, [expr | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed_args} -> {:ok, Enum.reverse(parsed_args)}
      :error -> :error
    end
  end

  defp helper_argument_expression(token, ctx) do
    cond do
      String.contains?(token, "=") ->
        case String.split(token, "=", parts: 2) do
          [key, value] ->
            if key != "" and helper_name?(key) do
              with {:ok, value_expr} <- helper_value_expression(value, ctx) do
                {:ok, "#{key}: #{value_expr}"}
              end
            else
              :error
            end

          _ ->
            :error
        end

      true ->
        helper_value_expression(token, ctx)
    end
  end

  defp helper_value_expression("this", ctx),
    do: {:ok, if(in_each_context?(ctx), do: "current", else: "this")}

  defp helper_value_expression("@index", ctx),
    do: {:ok, if(in_each_context?(ctx), do: "stem_index", else: "@index")}

  defp helper_value_expression("@key", ctx),
    do: {:ok, if(in_each_context?(ctx), do: "stem_key", else: "@key")}

  defp helper_value_expression(value, _ctx) when value in ["true", "false", "nil"],
    do: {:ok, value}

  defp helper_value_expression(value, ctx) do
    cond do
      String.match?(value, ~r/^-?\d+(\.\d+)?$/) ->
        {:ok, value}

      quoted_literal?(value) ->
        {:ok, value}

      String.starts_with?(value, "../") and valid_parent_identifier?(value) ->
        {:ok, "@#{strip_parent_segments(value)}"}

      path_expression?(value) ->
        {:ok, prefix_path_expression(value, ctx)}

      simple_identifier?(value) ->
        {:ok, if(in_each_context?(ctx), do: "this.#{value}", else: "@#{value}")}

      true ->
        :error
    end
  end

  defp path_expression?(expr) do
    String.match?(expr, ~r/^[a-z_][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+$/) or
      String.starts_with?(expr, "this.")
  end

  defp prefix_path_expression("this." <> _ = expr, _ctx), do: expr

  defp prefix_path_expression(expr, ctx) do
    if in_each_context?(ctx), do: "this.#{expr}", else: "@#{expr}"
  end

  defp helper_context_expression(ctx) do
    base = ["assigns: assigns", "helpers: helpers"]

    context =
      if in_each_context?(ctx) do
        ["this: current", "key: stem_key" | base]
      else
        base
      end

    "[#{Enum.join(context, ", ")}]"
  end

  defp simple_identifier?(expr), do: String.match?(expr, ~r/^[a-z_][a-zA-Z0-9_]*$/)
  defp quoted_literal?(arg), do: String.match?(arg, ~r/^".*"$/) or String.match?(arg, ~r/^'.*'$/)

  defp normalize_partials(partials) when is_map(partials) do
    Map.new(partials, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_partials(partials) when is_list(partials) do
    partials
    |> Enum.into(%{})
    |> normalize_partials()
  end

  defp parse_block_condition(tag, prefix) do
    remainder = tag |> String.trim_leading(prefix) |> String.trim()
    String.split(remainder) |> Enum.join(" ")
  end

  defp take_until(source, delimiter) do
    case :binary.match(source, delimiter) do
      {index, _len} ->
        delimiter_size = byte_size(delimiter)
        <<inner::binary-size(^index), _::binary-size(^delimiter_size), rest::binary>> = source
        {:ok, inner, rest, inner <> delimiter}

      :nomatch ->
        :error
    end
  end

  defp advance(segment, line, column) do
    do_advance(segment, line, column)
  end

  defp do_advance(<<"\r\n", rest::binary>>, line, _column), do: do_advance(rest, line + 1, 1)
  defp do_advance(<<"\n", rest::binary>>, line, _column), do: do_advance(rest, line + 1, 1)

  defp do_advance(<<_char::utf8, rest::binary>>, line, column),
    do: do_advance(rest, line, column + 1)

  defp do_advance(<<>>, line, column), do: {line, column}
end
