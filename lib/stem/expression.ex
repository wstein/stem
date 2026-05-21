# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Expression do
  @moduledoc false

  # Translates the contents of a `{{ ... }}` tag into Elixir source.
  #
  # This is where Handlebars conventions become Elixir: bare identifiers resolve
  # to assigns (`@name`) at the top level or to the current item (`current.name`)
  # inside `{{#each}}`; `this`, `@index`, and `@key` map to the loop bindings;
  # helper invocations expand to `Stem.Helpers.invoke/3`; and `../name` reaches
  # the parent (top-level assign) scope. The resulting string is parsed into
  # quoted Elixir by `Stem.Compiler`.

  @type context :: %{in_each: boolean()}

  @doc "Translates a raw expression into Elixir source for the given context."
  @spec translate(binary(), context()) :: binary()
  def translate(raw, context) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        "\"\""

      trimmed in ["true", "false", "nil"] ->
        trimmed

      trimmed == "@index" ->
        if context.in_each, do: "stem_index", else: trimmed

      trimmed == "@key" ->
        if context.in_each, do: "stem_key", else: trimmed

      trimmed == "this" ->
        if context.in_each, do: "current", else: trimmed

      helper_invocation(trimmed, context) ->
        {:ok, name, args} = helper_invocation(trimmed, context)
        parsed_args = Enum.join(args, ", ")
        "Stem.Helpers.invoke(:#{name}, [#{parsed_args}], #{helper_context_expression(context)})"

      String.starts_with?(trimmed, "../") and valid_parent_identifier?(trimmed) ->
        "@#{strip_parent_segments(trimmed)}"

      path_expression?(trimmed) ->
        prefix_path_expression(trimmed, context)

      simple_identifier?(trimmed) ->
        if context.in_each, do: "current.#{trimmed}", else: "@#{trimmed}"

      true ->
        rewrite_assigns_in_expression(raw, context)
    end
  end

  defp rewrite_assigns_in_expression(expr, context) do
    Regex.replace(~r/(?<![@\w.])([a-z_][a-zA-Z0-9_]*)(?![\w.])/, expr, fn token ->
      case token do
        keyword when keyword in ~w(and or not true false nil this) ->
          keyword

        _ ->
          if context.in_each, do: "this.#{token}", else: "@#{token}"
      end
    end)
  end

  defp helper_invocation(expr, context) do
    case helper_tokens(expr) do
      [name | args] when args != [] ->
        if helper_name?(name) do
          case parse_helper_args(args, context) do
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
    ~r/"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^\s]+/s
    |> Regex.scan(expr)
    |> List.flatten()
  end

  defp parse_helper_args(args, context) do
    args
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
      case helper_argument_expression(token, context) do
        {:ok, expr} -> {:cont, {:ok, [expr | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed_args} -> {:ok, Enum.reverse(parsed_args)}
      :error -> :error
    end
  end

  defp helper_argument_expression(token, context) do
    if String.contains?(token, "=") do
      case String.split(token, "=", parts: 2) do
        [key, value] when key != "" ->
          if helper_name?(key) do
            with {:ok, value_expr} <- helper_value_expression(value, context) do
              {:ok, "#{key}: #{value_expr}"}
            end
          else
            :error
          end

        _ ->
          :error
      end
    else
      helper_value_expression(token, context)
    end
  end

  defp helper_value_expression("this", context),
    do: {:ok, if(context.in_each, do: "current", else: "this")}

  defp helper_value_expression("@index", context),
    do: {:ok, if(context.in_each, do: "stem_index", else: "@index")}

  defp helper_value_expression("@key", context),
    do: {:ok, if(context.in_each, do: "stem_key", else: "@key")}

  defp helper_value_expression(value, _context) when value in ["true", "false", "nil"],
    do: {:ok, value}

  defp helper_value_expression(value, context) do
    cond do
      String.match?(value, ~r/^-?\d+(\.\d+)?$/) ->
        {:ok, value}

      quoted_literal?(value) ->
        {:ok, value}

      String.starts_with?(value, "../") and valid_parent_identifier?(value) ->
        {:ok, "@#{strip_parent_segments(value)}"}

      path_expression?(value) ->
        {:ok, prefix_path_expression(value, context)}

      simple_identifier?(value) ->
        {:ok, if(context.in_each, do: "this.#{value}", else: "@#{value}")}

      true ->
        :error
    end
  end

  defp path_expression?(expr) do
    String.match?(expr, ~r/^[a-z_][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+$/) or
      String.starts_with?(expr, "this.")
  end

  defp prefix_path_expression("this." <> _ = expr, _context), do: expr

  defp prefix_path_expression(expr, context) do
    if context.in_each, do: "this.#{expr}", else: "@#{expr}"
  end

  defp helper_context_expression(context) do
    base = ["assigns: assigns", "helpers: helpers"]

    entries =
      if context.in_each do
        ["this: current", "key: stem_key" | base]
      else
        base
      end

    "[#{Enum.join(entries, ", ")}]"
  end

  defp simple_identifier?(expr), do: String.match?(expr, ~r/^[a-z_][a-zA-Z0-9_]*$/)

  defp quoted_literal?(arg),
    do: String.match?(arg, ~r/^".*"$/) or String.match?(arg, ~r/^'.*'$/)

  defp strip_parent_segments("../" <> rest), do: strip_parent_segments(rest)
  defp strip_parent_segments(rest), do: rest

  defp valid_parent_identifier?(expr) do
    expr
    |> strip_parent_segments()
    |> simple_identifier?()
  end
end
