# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Expression do
  @moduledoc false

  import NimbleParsec

  escaped_char =
    string("\\")
    |> utf8_char([])
    |> reduce({List, :to_string, []})

  double_quoted_chunk =
    string("\"")
    |> repeat(
      choice([
        escaped_char,
        lookahead_not(string("\""))
        |> utf8_char([])
      ])
    )
    |> optional(string("\""))
    |> reduce({List, :to_string, []})

  single_quoted_chunk =
    string("'")
    |> repeat(
      choice([
        escaped_char,
        lookahead_not(string("'"))
        |> utf8_char([])
      ])
    )
    |> optional(string("'"))
    |> reduce({List, :to_string, []})

  defparsecp(
    :paren_chunk,
    string("(")
    |> repeat(
      choice([
        parsec(:paren_chunk),
        double_quoted_chunk,
        single_quoted_chunk,
        lookahead_not(choice([string("("), string(")"), string("\""), string("'")]))
        |> utf8_char([])
      ])
    )
    |> optional(string(")"))
    |> reduce({List, :to_string, []})
  )

  top_level_text_part =
    choice([
      parsec(:paren_chunk),
      double_quoted_chunk,
      single_quoted_chunk,
      lookahead_not(
        choice([
          string("|"),
          string(","),
          string("="),
          string(":"),
          ascii_char([9, 10, 13, 32]),
          string("\""),
          string("'"),
          string("("),
          string(")")
        ])
      )
      |> utf8_char([])
    ])

  top_level_text_token =
    top_level_text_part
    |> repeat(top_level_text_part)
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:text)

  defparsecp(
    :do_splitter_tokens,
    repeat(
      choice([
        string("|") |> unwrap_and_tag(:pipe),
        string(",") |> unwrap_and_tag(:comma),
        string("=") |> unwrap_and_tag(:eq),
        string(":") |> unwrap_and_tag(:colon),
        ascii_char([9, 10, 13, 32]) |> reduce({List, :to_string, []}) |> unwrap_and_tag(:ws),
        top_level_text_token
      ])
    )
  )

  @type context :: %{in_each: boolean(), locals: %{optional(binary()) => binary()}}
  @type helper_arg_t :: expr_t() | {:kw, binary(), expr_t()}
  @type pipeline_stage_t :: {:stage, binary(), [helper_arg_t()]}
  @type expr_t ::
          {:literal, binary()}
          | {:identifier, binary()}
          | {:special, :index | :index1 | :key | :this}
          | {:parent, binary()}
          | {:path, :implicit | :this, [binary()]}
          | {:transformer, binary(), [helper_arg_t()]}
          | {:pipeline, expr_t(), [pipeline_stage_t()]}

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
          {:ok, expr} ->
            {:ok, expr}

          :error ->
            {:error,
             "expression must be an assign, dotted path, literal, or transformer call " <>
               "(e.g. `name`, `user.email`, `\"text\"`, `upcase name`, or `name | upcase`)"}
        end
    end
  end

  @spec translate(binary(), context()) :: binary()
  def translate(raw, context) do
    raw
    |> parse!()
    |> to_source(context)
  end

  @doc """
  Parses partial arguments into an optional context expression and hash pairs.

  Accepts the raw argument string that follows a partial name in
  `{{> name context key=value ...}}`. Returns the leading positional argument as
  the context expression (or `nil` when absent) and the keyword arguments as a
  list of `{atom_key, expr_t()}` hash pairs evaluated against the caller scope.
  """
  @spec parse_partial_args(binary()) ::
          {:ok, expr_t() | nil, [{atom(), expr_t()}]} | {:error, binary()}
  def parse_partial_args(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        {:ok, nil, []}

      trimmed ->
        case parse_helper_args(split_top_level(trimmed)) do
          {:ok, args} ->
            classify_partial_args(args)

          :error ->
            {:error, "partial arguments must be assigns, paths, literals, or key=value pairs"}
        end
    end
  end

  defp classify_partial_args(args) do
    {positional, keyword} = Enum.split_with(args, &(not match?({:kw, _, _}, &1)))

    case positional do
      [] -> {:ok, nil, partial_hash(keyword)}
      [context] -> {:ok, context, partial_hash(keyword)}
      _ -> {:error, "partials accept at most one context argument before key=value pairs"}
    end
  end

  defp partial_hash(keyword) do
    Enum.map(keyword, fn {:kw, key, value} -> {String.to_atom(key), value} end)
  end

  @spec to_source(expr_t(), context()) :: binary()
  def to_source({:literal, "null"}, _context), do: "nil"
  def to_source({:literal, source}, _context), do: source

  def to_source({:special, :index}, context),
    do: if(context.in_each, do: "stem_index", else: "@index")

  def to_source({:special, :index1}, context),
    do: if(context.in_each, do: "stem_index + 1", else: "@index1")

  def to_source({:special, :key}, context),
    do: if(context.in_each, do: "stem_key", else: "@key")

  def to_source({:special, :this}, context),
    do: if(context.in_each, do: "current", else: "this")

  def to_source({:identifier, name}, context) do
    case local_source(context, name) do
      {:ok, source} -> source
      :error -> if(context.in_each, do: "current" <> dot_access(name), else: assign_marker(name))
    end
  end

  def to_source({:parent, name}, _context), do: "@#{name}"

  def to_source({:path, :this, segments}, context) do
    root = if context.in_each, do: "current", else: "this"
    root <> Enum.map_join(segments, &dot_access/1)
  end

  def to_source({:path, :implicit, [root | rest]}, context) do
    rest_source = Enum.map_join(rest, &dot_access/1)

    case local_source(context, root) do
      {:ok, source} ->
        source <> rest_source

      :error ->
        root_source =
          if(context.in_each, do: "current" <> dot_access(root), else: assign_marker(root))

        root_source <> rest_source
    end
  end

  def to_source({:transformer, name, args}, context) do
    helper_call_source(name, args, context)
  end

  def to_source({:pipeline, lhs, stages}, context) do
    initial = to_source(lhs, context)

    Enum.reduce(stages, initial, fn {:stage, name, args}, acc ->
      helper_call_source(name, [acc | args], context, true)
    end)
  end

  @spec format(expr_t()) :: binary()
  def format({:literal, source}), do: source
  def format({:identifier, name}), do: format_segment(name)
  def format({:special, :index}), do: "@index"
  def format({:special, :index1}), do: "@index1"
  def format({:special, :key}), do: "@key"
  def format({:special, :this}), do: "this"
  def format({:parent, name}), do: "../#{name}"

  def format({:path, :this, segments}),
    do: Enum.join(["this" | Enum.map(segments, &format_segment/1)], ".")

  def format({:path, :implicit, segments}),
    do: Enum.map_join(segments, ".", &format_segment/1)

  def format({:transformer, name, args}) do
    Enum.join([name | Enum.map(args, &format_call_arg/1)], " ")
  end

  def format({:pipeline, lhs, stages}) do
    segments =
      Enum.map(stages, fn {:stage, name, args} ->
        Enum.join([name | Enum.map(args, &format_call_arg/1)], " ")
      end)

    Enum.join([format(lhs) | segments], " | ")
  end

  @spec references_identifier?(expr_t(), binary()) :: boolean()
  def references_identifier?({:literal, _}, _name), do: false
  def references_identifier?({:special, _}, _name), do: false
  def references_identifier?({:parent, _}, _name), do: false
  def references_identifier?({:identifier, name}, name), do: true
  def references_identifier?({:identifier, _}, _name), do: false
  def references_identifier?({:path, _, [root | _]}, name), do: root == name

  def references_identifier?({:transformer, _name, args}, name) do
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

  defp parse!(raw) do
    case parse(raw) do
      {:ok, expr} -> expr
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp helper_call_source(name, args, context, precompiled \\ false) do
    # Emit positional args before keyword args so the generated Elixir list is
    # always valid (keywords must come last), regardless of source order. This
    # matches how the bytecode backend lowers calls.
    {positional, keyword} = Enum.split_with(args, &(not match?({:kw, _, _}, &1)))

    compiled_args =
      (positional ++ keyword)
      |> Enum.map(fn
        value when is_binary(value) and precompiled -> value
        {:kw, key, value} -> "#{key}: #{to_source(value, context)}"
        value -> to_source(value, context)
      end)
      |> Enum.join(", ")

    "Stem.Transformers.invoke(:#{name}, [#{compiled_args}], #{helper_context_expression(context)})"
  end

  defp format_call_arg({:kw, key, {:transformer, _, _} = value}), do: "#{key}=(#{format(value)})"
  defp format_call_arg({:kw, key, {:pipeline, _, _} = value}), do: "#{key}=(#{format(value)})"
  defp format_call_arg({:kw, key, value}), do: "#{key}=#{format(value)}"
  defp format_call_arg({:transformer, _, _} = value), do: "(#{format(value)})"
  defp format_call_arg({:pipeline, _, _} = value), do: "(#{format(value)})"
  defp format_call_arg(value), do: format(value)

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
        # Prefix-style stage `name arg arg..` (space-separated args), the same
        # call form as a standalone transformer. The piped value is prepended as
        # the implicit first positional argument during lowering.
        case split_top_level(trimmed) do
          [name | args] when args != [] ->
            if helper_name?(name) do
              with {:ok, parsed_args} <- parse_helper_args(args) do
                {:ok, {:stage, name, parsed_args}}
              end
            else
              {:error, "pipeline stage helper names must be simple identifiers"}
            end

          _ ->
            {:error,
             "pipeline stages must be a helper name followed by space-separated arguments"}
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

      trimmed == "nil" ->
        {:ok, {:literal, "null"}}

      literal_source?(trimmed) ->
        {:ok, {:literal, trimmed}}

      trimmed == "null" ->
        {:ok, {:literal, "null"}}

      trimmed == "@index" ->
        {:ok, {:special, :index}}

      trimmed == "@index1" ->
        {:ok, {:special, :index1}}

      trimmed == "@key" ->
        {:ok, {:special, :key}}

      trimmed in ["this", "."] ->
        {:ok, {:special, :this}}

      String.starts_with?(trimmed, "../") and valid_parent_identifier?(trimmed) ->
        {:ok, {:parent, strip_parent_segments(trimmed)}}

      true ->
        case reference_expression(trimmed) do
          {:ok, node} -> {:ok, node}
          :no_reference -> helper_invocation_ast(trimmed)
        end
    end
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
            {:ok, {:transformer, name, parsed_args}}
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

      trimmed == "nil" ->
        {:ok, {:literal, "null"}}

      literal_source?(trimmed) ->
        {:ok, {:literal, trimmed}}

      trimmed == "null" ->
        {:ok, {:literal, "null"}}

      trimmed == "@index" ->
        {:ok, {:special, :index}}

      trimmed == "@index1" ->
        {:ok, {:special, :index1}}

      trimmed == "@key" ->
        {:ok, {:special, :key}}

      trimmed in ["this", "."] ->
        {:ok, {:special, :this}}

      String.starts_with?(trimmed, "../") and valid_parent_identifier?(trimmed) ->
        {:ok, {:parent, strip_parent_segments(trimmed)}}

      true ->
        case reference_expression(trimmed) do
          {:ok, node} -> {:ok, node}
          :no_reference -> :error
        end
    end
  end

  defp parse_subexpression(token) do
    token =
      token
      |> String.trim_leading("(")
      |> String.trim_trailing(")")

    case strict_expression(token) do
      {:ok, {:transformer, _, _} = helper} -> {:ok, helper}
      {:ok, {:pipeline, _, _} = pipeline} -> {:ok, pipeline}
      _ -> :error
    end
  end

  # A reference is a dotted chain of segments, each either a bare identifier
  # (`name`, `Item1`) or a bracketed literal key (`[first-name]`, `[a.b]`).
  # Bracket segments escape characters a bare identifier cannot carry — dashes,
  # spaces, dots, leading digits, or reserved words like `this`.
  @reference_segment ~r/\[[^\]]+\]|[A-Za-z_][A-Za-z0-9_]*/

  defp reference_expression(trimmed) do
    segments = @reference_segment |> Regex.scan(trimmed) |> List.flatten()

    if segments != [] and Enum.join(segments, ".") == trimmed do
      build_reference(segments)
    else
      :no_reference
    end
  end

  defp build_reference([raw_root | _] = segments) do
    [root_key | rest_keys] = Enum.map(segments, &strip_segment/1)

    cond do
      segments == ["this"] ->
        :no_reference

      match?([_single], segments) ->
        {:ok, {:identifier, root_key}}

      raw_root == "this" ->
        {:ok, {:path, :this, rest_keys}}

      true ->
        {:ok, {:path, :implicit, [root_key | rest_keys]}}
    end
  end

  defp strip_segment("[" <> rest), do: binary_part(rest, 0, byte_size(rest) - 1)
  defp strip_segment(bare), do: bare

  # Emits a member access (`.name`), quoting any key that is not a bare Elixir
  # identifier so dashes/spaces/leading digits survive the source round-trip.
  defp dot_access(name) do
    if simple_identifier?(name), do: ".#{name}", else: "." <> inspect(name)
  end

  # Emits an assign read. A bare key keeps the familiar `@name` marker; a literal
  # key becomes `@(:"key")` so `Stem.Compiler.rewrite_assign/2` still recognizes
  # it without the key having to be a valid identifier.
  defp assign_marker(name) do
    if simple_identifier?(name),
      do: "@#{name}",
      else: "@(" <> inspect(String.to_atom(name)) <> ")"
  end

  defp format_segment(name) do
    if binding_name?(name), do: name, else: "[#{name}]"
  end

  defp binding_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp helper_context_expression(context) do
    base = ["assigns: assigns", "transformers: transformers"]

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
    arg in ["true", "false", "nil", "null"] or
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

  defp split_top_level_once(token, delimiter) do
    token
    |> splitter_tokens()
    |> split_once_tokens(delimiter)
  end

  defp split_top_level(expr) do
    expr
    |> splitter_tokens()
    |> split_whitespace_tokens()
  end

  defp split_top_level_pipe(expr) do
    expr
    |> splitter_tokens()
    |> split_by_token(:pipe)
  end

  defp splitter_tokens(source) do
    case do_splitter_tokens(source) do
      {:ok, tokens, "", _, _, _} -> tokens
      _ -> [{:text, source}]
    end
  end

  defp split_whitespace_tokens(tokens) do
    {current, acc} =
      Enum.reduce(tokens, {"", []}, fn
        {:ws, _}, {"", acc} ->
          {"", acc}

        {:ws, _}, {current, acc} ->
          {"", [current | acc]}

        token, {current, acc} ->
          {current <> token_value(token), acc}
      end)

    acc = if current == "", do: acc, else: [current | acc]
    Enum.reverse(acc)
  end

  defp split_by_token(tokens, delimiter_token) do
    {current, acc} =
      Enum.reduce(tokens, {"", []}, fn
        {^delimiter_token, _}, {current, acc} ->
          {"", [current | acc]}

        token, {current, acc} ->
          {current <> token_value(token), acc}
      end)

    Enum.reverse([current | acc])
  end

  defp split_once_tokens(tokens, delimiter) do
    delimiter_token = delimiter_token(delimiter)

    Enum.reduce_while(tokens, {:searching, "", []}, fn
      {^delimiter_token, _}, {:searching, current, _acc} ->
        {:halt, [current, tokens_to_binary(tl_after_current(tokens, delimiter_token, current))]}

      token, {:searching, current, acc} ->
        {:cont, {:searching, current <> token_value(token), [token | acc]}}
    end)
    |> case do
      [left, right] -> [left, right]
      _ -> nil
    end
  end

  defp tl_after_current(tokens, delimiter_token, current) do
    current_size = byte_size(current)
    {_before, rest} = rebuild_split(tokens, delimiter_token, current_size, "")
    rest
  end

  defp rebuild_split([{token_kind, value} | rest], delimiter_token, current_size, built)
       when token_kind == delimiter_token do
    if byte_size(built) == current_size do
      {built, rest}
    else
      rebuild_split(rest, delimiter_token, current_size, built <> value)
    end
  end

  defp rebuild_split([token | rest], delimiter_token, current_size, built) do
    rebuild_split(rest, delimiter_token, current_size, built <> token_value(token))
  end

  defp rebuild_split([], _delimiter_token, _current_size, built), do: {built, []}

  defp tokens_to_binary(tokens), do: Enum.map_join(tokens, &token_value/1)

  defp delimiter_token(?,), do: :comma
  defp delimiter_token(?=), do: :eq
  defp delimiter_token(?:), do: :colon

  defp token_value({_kind, value}), do: value

  defp strip_parent_segments("../" <> rest), do: strip_parent_segments(rest)
  defp strip_parent_segments(rest), do: rest

  defp valid_parent_identifier?(expr) do
    expr
    |> strip_parent_segments()
    |> simple_identifier?()
  end
end
