# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Expression do
  @moduledoc false

  @type context :: %{in_each: boolean(), locals: %{optional(binary()) => binary()}}
  @type helper_arg_t :: expr_t() | {:kw, binary(), expr_t()}
  @type pipeline_stage_t :: {:stage, binary(), [helper_arg_t()]}
  @type expr_t ::
          {:literal, binary()}
          | {:identifier, binary()}
          | {:special, :index | :key | :this}
          | {:parent, binary()}
          | {:path, :implicit | :this, [binary()]}
          | {:helper, binary(), [helper_arg_t()]}
          | {:pipeline, expr_t(), [pipeline_stage_t()]}
          | {:elixir, binary()}

  @spec parse(binary()) :: {:ok, expr_t()} | {:error, binary()}
  def parse(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case parse_pipeline(trimmed) do
      {:ok, pipeline} ->
        {:ok, pipeline}

      {:error, _message} = error ->
        error

      :no_pipeline ->
        case structured_expression(trimmed) do
          {:ok, expr} -> {:ok, expr}
          :error -> {:ok, {:elixir, raw}}
        end
    end
  end

  @spec translate(binary(), context()) :: binary()
  def translate(raw, context) do
    raw
    |> parse!()
    |> to_source(context)
  end

  @spec to_source(expr_t(), context()) :: binary()
  def to_source({:literal, source}, _context), do: source

  def to_source({:special, :index}, context),
    do: if(context.in_each, do: "stem_index", else: "@index")

  def to_source({:special, :key}, context),
    do: if(context.in_each, do: "stem_key", else: "@key")

  def to_source({:special, :this}, context),
    do: if(context.in_each, do: "current", else: "this")

  def to_source({:identifier, name}, context) do
    case local_source(context, name) do
      {:ok, source} -> source
      :error -> if(context.in_each, do: "current.#{name}", else: "@#{name}")
    end
  end

  def to_source({:parent, name}, _context), do: "@#{name}"
  def to_source({:path, :this, segments}, _context), do: Enum.join(["this" | segments], ".")

  def to_source({:path, :implicit, [root | rest]}, context) do
    path = Enum.join([root | rest], ".")

    case local_source(context, root) do
      {:ok, source} -> Enum.join([source | rest], ".")
      :error -> if(context.in_each, do: "this.#{path}", else: "@#{path}")
    end
  end

  def to_source({:helper, name, args}, context) do
    helper_call_source(name, args, context)
  end

  def to_source({:pipeline, lhs, stages}, context) do
    initial = to_source(lhs, context)

    Enum.reduce(stages, initial, fn {:stage, name, args}, acc ->
      helper_call_source(name, [acc | args], context, true)
    end)
  end

  def to_source({:elixir, raw}, context), do: rewrite_assigns_in_expression(raw, context)

  @spec format(expr_t()) :: binary()
  def format({:literal, source}), do: source
  def format({:identifier, name}), do: name
  def format({:special, :index}), do: "@index"
  def format({:special, :key}), do: "@key"
  def format({:special, :this}), do: "this"
  def format({:parent, name}), do: "../#{name}"
  def format({:path, :this, segments}), do: Enum.join(["this" | segments], ".")
  def format({:path, :implicit, segments}), do: Enum.join(segments, ".")

  def format({:helper, name, args}) do
    formatted_args =
      Enum.map(args, fn
        {:kw, key, {:helper, _, _} = value} -> "#{key}=(#{format(value)})"
        {:kw, key, {:pipeline, _, _} = value} -> "#{key}=(#{format(value)})"
        {:kw, key, value} -> "#{key}=#{format(value)}"
        {:helper, _, _} = value -> "(#{format(value)})"
        {:pipeline, _, _} = value -> "(#{format(value)})"
        value -> format(value)
      end)

    Enum.join([name | formatted_args], " ")
  end

  def format({:pipeline, lhs, stages}) do
    segments =
      Enum.map(stages, fn {:stage, name, args} ->
        case args do
          [] ->
            name

          _ ->
            formatted_args =
              args
              |> Enum.map(&format_pipeline_arg/1)
              |> Enum.join(", ")

            "#{name}(#{formatted_args})"
        end
      end)

    Enum.join([format(lhs) | segments], " |> ")
  end

  def format({:elixir, raw}), do: String.trim(raw)

  @spec references_identifier?(expr_t(), binary()) :: boolean()
  def references_identifier?({:literal, _}, _name), do: false
  def references_identifier?({:special, _}, _name), do: false
  def references_identifier?({:parent, _}, _name), do: false
  def references_identifier?({:identifier, name}, name), do: true
  def references_identifier?({:identifier, _}, _name), do: false
  def references_identifier?({:path, _, [root | _]}, name), do: root == name

  def references_identifier?({:helper, _name, args}, name) do
    Enum.any?(args, fn
      {:kw, _key, value} -> references_identifier?(value, name)
      value -> references_identifier?(value, name)
    end)
  end

  def references_identifier?({:pipeline, lhs, stages}, name) do
    references_identifier?(lhs, name) or
      Enum.any?(stages, fn {:stage, _stage_name, args} ->
        Enum.any?(args, fn
          {:kw, _key, value} -> references_identifier?(value, name)
          value -> references_identifier?(value, name)
        end)
      end)
  end

  def references_identifier?({:elixir, raw}, name) do
    Regex.match?(~r/(^|[^@\w.])#{Regex.escape(name)}(?=$|[^\w.])/, raw)
  end

  defp parse!(raw) do
    case parse(raw) do
      {:ok, expr} -> expr
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp helper_call_source(name, args, context, precompiled \\ false) do
    compiled_args =
      args
      |> Enum.map(fn
        value when is_binary(value) and precompiled -> value
        {:kw, key, value} -> "#{key}: #{to_source(value, context)}"
        value -> to_source(value, context)
      end)
      |> Enum.join(", ")

    "Stem.Helpers.invoke(:#{name}, [#{compiled_args}], #{helper_context_expression(context)})"
  end

  defp format_pipeline_arg({:kw, key, value}), do: "#{key}=#{format(value)}"
  defp format_pipeline_arg(value), do: format(value)

  defp parse_pipeline(trimmed) do
    case split_top_level_pipe(trimmed) do
      [_single] ->
        :no_pipeline

      [head | stages] ->
        with {:ok, initial} <- parse_pipeline_input(head),
             {:ok, parsed_stages} <- parse_pipeline_stages(stages) do
          {:ok, {:pipeline, initial, parsed_stages}}
        end
    end
  end

  defp parse_pipeline_input(source) do
    source = String.trim(source)

    case strict_expression(source) do
      {:ok, expr} ->
        {:ok, expr}

      {:error, _message} = error ->
        error
    end
  end

  defp parse_pipeline_stages(stages) do
    stages
    |> Enum.reduce_while({:ok, []}, fn stage_source, {:ok, acc} ->
      case parse_pipeline_stage(stage_source) do
        {:ok, stage} -> {:cont, {:ok, [stage | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed_stages} -> {:ok, Enum.reverse(parsed_stages)}
      {:error, _message} = error -> error
    end
  end

  defp parse_pipeline_stage(source) do
    trimmed = String.trim(source)

    cond do
      trimmed == "" ->
        {:error, "pipeline stages cannot be empty"}

      helper_name?(trimmed) ->
        {:ok, {:stage, trimmed, []}}

      true ->
        case Regex.run(~r/^([a-z_][a-zA-Z0-9_]*)\((.*)\)$/s, trimmed, capture: :all_but_first) do
          [name, args_source] ->
            with :ok <- validate_pipeline_stage_source(trimmed),
                 {:ok, args} <- parse_pipeline_call_args(args_source) do
              {:ok, {:stage, name, args}}
            end

          _ ->
            {:error,
             "pipeline stages must be helper names or helper calls like trim or truncate(20)"}
        end
    end
  end

  defp validate_pipeline_stage_source(source) do
    if balanced_call_parentheses?(source) do
      :ok
    else
      {:error, "pipeline helper calls must use balanced parentheses"}
    end
  end

  defp parse_pipeline_call_args(args_source) do
    args_source
    |> split_top_level_by_char(?,)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
      case pipeline_argument_expression(token) do
        {:ok, expr} -> {:cont, {:ok, [expr | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, args} -> {:ok, Enum.reverse(args)}
      {:error, _message} = error -> error
    end
  end

  defp pipeline_argument_expression(token) do
    case keyword_argument_parts(token) do
      {:ok, key, value} ->
        with {:ok, parsed_value} <- strict_expression(String.trim(value)) do
          {:ok, {:kw, key, parsed_value}}
        end

      :no_keyword ->
        strict_expression(token)

      {:error, _message} = error ->
        error
    end
  end

  defp keyword_argument_parts(token) do
    token = String.trim(token)

    cond do
      token == "" ->
        {:error, "pipeline helper arguments cannot be empty"}

      true ->
        case split_top_level_once(token, ?=) || split_top_level_once(token, ?:) do
          [key, value] ->
            key = String.trim(key)

            cond do
              key == "" ->
                :no_keyword

              helper_name?(key) ->
                {:ok, key, value}

              true ->
                {:error, "pipeline keyword arguments must use simple identifier keys"}
            end

          nil ->
            :no_keyword

          _ ->
            {:error, "pipeline helper arguments must be expressions or keyword arguments"}
        end
    end
  end

  defp strict_expression(trimmed) do
    case parse_pipeline(trimmed) do
      {:ok, pipeline} ->
        {:ok, pipeline}

      {:error, _message} = error ->
        error

      :no_pipeline ->
        case structured_expression(trimmed) do
          {:ok, expr} -> {:ok, expr}
          :error -> {:error, "pipeline expressions only allow structured Stem syntax"}
        end
    end
  end

  defp structured_expression(trimmed) do
    cond do
      trimmed == "" ->
        {:ok, {:literal, ~s("")}}

      literal_source?(trimmed) ->
        {:ok, {:literal, trimmed}}

      trimmed == "@index" ->
        {:ok, {:special, :index}}

      trimmed == "@key" ->
        {:ok, {:special, :key}}

      trimmed == "this" ->
        {:ok, {:special, :this}}

      String.starts_with?(trimmed, "../") and valid_parent_identifier?(trimmed) ->
        {:ok, {:parent, strip_parent_segments(trimmed)}}

      path_expression?(trimmed) ->
        {:ok, parse_path(trimmed)}

      simple_identifier?(trimmed) ->
        {:ok, {:identifier, trimmed}}

      true ->
        helper_invocation_ast(trimmed)
    end
  end

  defp rewrite_assigns_in_expression(expr, context) do
    Regex.replace(~r/(?<![@\w.])([a-z_][a-zA-Z0-9_]*)(?![\w.])/, expr, fn token ->
      case token do
        keyword when keyword in ~w(and or not true false nil this) ->
          keyword

        _ ->
          case local_source(context, token) do
            {:ok, source} -> source
            :error -> if(context.in_each, do: "this.#{token}", else: "@#{token}")
          end
      end
    end)
  end

  defp local_source(context, name) do
    case Map.fetch(Map.get(context, :locals, %{}), name) do
      {:ok, source} -> {:ok, source}
      :error -> :error
    end
  end

  defp helper_invocation_ast(expr) do
    case split_top_level(expr) do
      [name | args] when args != [] ->
        if helper_name?(name) do
          with {:ok, parsed_args} <- parse_helper_args(args) do
            {:ok, {:helper, name, parsed_args}}
          end
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp helper_name?(name), do: String.match?(name, ~r/^[a-z_][a-zA-Z0-9_]*$/)

  defp parse_helper_args(args) do
    args
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
      case helper_argument_expression(token) do
        {:ok, expr} -> {:cont, {:ok, [expr | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed_args} -> {:ok, Enum.reverse(parsed_args)}
      :error -> :error
    end
  end

  defp helper_argument_expression(token) do
    case split_top_level_once(token, ?=) do
      [key, value] when key != "" ->
        if helper_name?(key) do
          with {:ok, value_expr} <- helper_value_expression(value) do
            {:ok, {:kw, key, value_expr}}
          end
        else
          :error
        end

      nil ->
        helper_value_expression(token)

      _ ->
        :error
    end
  end

  defp helper_value_expression(value) do
    trimmed = String.trim(value)

    cond do
      wrapped_subexpression?(trimmed) ->
        parse_subexpression(trimmed)

      literal_source?(trimmed) ->
        {:ok, {:literal, trimmed}}

      trimmed == "@index" ->
        {:ok, {:special, :index}}

      trimmed == "@key" ->
        {:ok, {:special, :key}}

      trimmed == "this" ->
        {:ok, {:special, :this}}

      String.starts_with?(trimmed, "../") and valid_parent_identifier?(trimmed) ->
        {:ok, {:parent, strip_parent_segments(trimmed)}}

      path_expression?(trimmed) ->
        {:ok, parse_path(trimmed)}

      simple_identifier?(trimmed) ->
        {:ok, {:identifier, trimmed}}

      true ->
        :error
    end
  end

  defp parse_subexpression(token) do
    token =
      token
      |> String.trim_leading("(")
      |> String.trim_trailing(")")

    case strict_expression(token) do
      {:ok, {:helper, _, _} = helper} -> {:ok, helper}
      {:ok, {:pipeline, _, _} = pipeline} -> {:ok, pipeline}
      _ -> :error
    end
  end

  defp path_expression?(expr) do
    String.match?(expr, ~r/^[a-z_][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+$/) or
      String.starts_with?(expr, "this.")
  end

  defp parse_path("this." <> rest), do: {:path, :this, String.split(rest, ".")}
  defp parse_path(expr), do: {:path, :implicit, String.split(expr, ".")}

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

  defp literal_source?(arg) do
    arg in ["true", "false", "nil"] or
      String.match?(arg, ~r/^-?\d+(\.\d+)?$/) or
      String.match?(arg, ~r/^"(?:\\.|[^"])*"$/) or
      String.match?(arg, ~r/^'(?:\\.|[^'])*'$/)
  end

  defp wrapped_subexpression?(token) do
    String.starts_with?(token, "(") and String.ends_with?(token, ")") and
      balanced_wrapped_parentheses?(token)
  end

  defp balanced_wrapped_parentheses?(token) do
    token_length = String.length(token)

    {depth, valid?} =
      token
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce_while({0, true}, fn {char, index}, {depth, _} ->
        cond do
          char == "(" -> {:cont, {depth + 1, true}}
          char == ")" and depth == 0 -> {:halt, {depth, false}}
          char == ")" and depth == 1 and index != token_length - 1 -> {:halt, {depth, false}}
          char == ")" -> {:cont, {depth - 1, true}}
          true -> {:cont, {depth, true}}
        end
      end)

    valid? and depth == 0
  end

  defp split_top_level_once(token, delimiter),
    do: split_top_level_once(token, delimiter, 0, nil, [])

  defp split_top_level_once(<<>>, _delimiter, _depth, _quote, _buffer), do: nil

  defp split_top_level_once(<<char::utf8, rest::binary>>, delimiter, depth, quote, buffer) do
    cond do
      not is_nil(quote) and char == ?\\ and rest != <<>> ->
        <<escaped::utf8, remaining::binary>> = rest

        split_top_level_once(remaining, delimiter, depth, quote, [
          buffer | <<char::utf8, escaped::utf8>>
        ])

      not is_nil(quote) and char == quote ->
        split_top_level_once(rest, delimiter, depth, nil, [buffer | <<char::utf8>>])

      not is_nil(quote) ->
        split_top_level_once(rest, delimiter, depth, quote, [buffer | <<char::utf8>>])

      char in [?", ?'] ->
        split_top_level_once(rest, delimiter, depth, char, [buffer | <<char::utf8>>])

      char == ?( ->
        split_top_level_once(rest, delimiter, depth + 1, quote, [buffer | <<char::utf8>>])

      char == ?) ->
        split_top_level_once(rest, delimiter, max(depth - 1, 0), quote, [buffer | <<char::utf8>>])

      char == delimiter and depth == 0 ->
        [IO.iodata_to_binary(buffer), rest]

      true ->
        split_top_level_once(rest, delimiter, depth, quote, [buffer | <<char::utf8>>])
    end
  end

  defp split_top_level(expr), do: split_top_level(expr, 0, nil, [], [])
  defp split_top_level(<<>>, _depth, _quote, [], acc), do: Enum.reverse(acc)

  defp split_top_level(<<>>, _depth, _quote, buffer, acc),
    do: Enum.reverse([IO.iodata_to_binary(buffer) | acc])

  defp split_top_level(<<char::utf8, rest::binary>>, depth, quote, buffer, acc) do
    cond do
      not is_nil(quote) and char == ?\\ and rest != <<>> ->
        <<escaped::utf8, remaining::binary>> = rest
        split_top_level(remaining, depth, quote, [buffer | <<char::utf8, escaped::utf8>>], acc)

      not is_nil(quote) and char == quote ->
        split_top_level(rest, depth, nil, [buffer | <<char::utf8>>], acc)

      not is_nil(quote) ->
        split_top_level(rest, depth, quote, [buffer | <<char::utf8>>], acc)

      char in [?", ?'] ->
        split_top_level(rest, depth, char, [buffer | <<char::utf8>>], acc)

      char == ?( ->
        split_top_level(rest, depth + 1, quote, [buffer | <<char::utf8>>], acc)

      char == ?) ->
        split_top_level(rest, max(depth - 1, 0), quote, [buffer | <<char::utf8>>], acc)

      depth == 0 and char in [32, ?\n, ?\t, ?\r] ->
        case IO.iodata_to_binary(buffer) do
          "" -> split_top_level(rest, depth, quote, [], acc)
          token -> split_top_level(rest, depth, quote, [], [token | acc])
        end

      true ->
        split_top_level(rest, depth, quote, [buffer | <<char::utf8>>], acc)
    end
  end

  defp split_top_level_pipe(expr), do: split_top_level_pipe(expr, 0, nil, [], [])

  defp split_top_level_pipe(<<>>, _depth, _quote, buffer, acc),
    do: Enum.reverse([iodata(buffer) | acc])

  defp split_top_level_pipe(<<char::utf8, rest::binary>>, depth, quote, buffer, acc) do
    cond do
      not is_nil(quote) and char == ?\\ and rest != <<>> ->
        <<escaped::utf8, remaining::binary>> = rest

        split_top_level_pipe(
          remaining,
          depth,
          quote,
          [buffer | <<char::utf8, escaped::utf8>>],
          acc
        )

      not is_nil(quote) and char == quote ->
        split_top_level_pipe(rest, depth, nil, [buffer | <<char::utf8>>], acc)

      not is_nil(quote) ->
        split_top_level_pipe(rest, depth, quote, [buffer | <<char::utf8>>], acc)

      char in [?", ?'] ->
        split_top_level_pipe(rest, depth, char, [buffer | <<char::utf8>>], acc)

      char == ?( ->
        split_top_level_pipe(rest, depth + 1, quote, [buffer | <<char::utf8>>], acc)

      char == ?) ->
        split_top_level_pipe(rest, max(depth - 1, 0), quote, [buffer | <<char::utf8>>], acc)

      depth == 0 and char == ?| and String.starts_with?(rest, ">") ->
        split_top_level_pipe(
          String.trim_leading(binary_part(rest, 1, byte_size(rest) - 1)),
          depth,
          quote,
          [],
          [iodata(buffer) | acc]
        )

      true ->
        split_top_level_pipe(rest, depth, quote, [buffer | <<char::utf8>>], acc)
    end
  end

  defp split_top_level_by_char(expr, delimiter),
    do: split_top_level_by_char(expr, delimiter, 0, nil, [], [])

  defp split_top_level_by_char(<<>>, _delimiter, _depth, _quote, buffer, acc),
    do: Enum.reverse([iodata(buffer) | acc])

  defp split_top_level_by_char(<<char::utf8, rest::binary>>, delimiter, depth, quote, buffer, acc) do
    cond do
      not is_nil(quote) and char == ?\\ and rest != <<>> ->
        <<escaped::utf8, remaining::binary>> = rest

        split_top_level_by_char(
          remaining,
          delimiter,
          depth,
          quote,
          [buffer | <<char::utf8, escaped::utf8>>],
          acc
        )

      not is_nil(quote) and char == quote ->
        split_top_level_by_char(rest, delimiter, depth, nil, [buffer | <<char::utf8>>], acc)

      not is_nil(quote) ->
        split_top_level_by_char(rest, delimiter, depth, quote, [buffer | <<char::utf8>>], acc)

      char in [?", ?'] ->
        split_top_level_by_char(rest, delimiter, depth, char, [buffer | <<char::utf8>>], acc)

      char == ?( ->
        split_top_level_by_char(rest, delimiter, depth + 1, quote, [buffer | <<char::utf8>>], acc)

      char == ?) ->
        split_top_level_by_char(
          rest,
          delimiter,
          max(depth - 1, 0),
          quote,
          [buffer | <<char::utf8>>],
          acc
        )

      depth == 0 and char == delimiter ->
        split_top_level_by_char(rest, delimiter, depth, quote, [], [iodata(buffer) | acc])

      true ->
        split_top_level_by_char(rest, delimiter, depth, quote, [buffer | <<char::utf8>>], acc)
    end
  end

  defp balanced_call_parentheses?(source) do
    String.ends_with?(source, ")") and
      String.contains?(source, "(") and
      balanced_wrapped_parentheses?(
        String.replace_prefix(source, hd(String.split(source, "(", parts: 2)), "")
      )
  end

  defp iodata([]), do: ""
  defp iodata(buffer), do: IO.iodata_to_binary(buffer)

  defp strip_parent_segments("../" <> rest), do: strip_parent_segments(rest)
  defp strip_parent_segments(rest), do: rest

  defp valid_parent_identifier?(expr) do
    expr
    |> strip_parent_segments()
    |> simple_identifier?()
  end
end
