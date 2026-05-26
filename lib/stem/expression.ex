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

  # A bracketed literal key (`[first-name]`, `[my name]`). Like the quoted
  # chunks, it is atomic at the top level, so characters that would otherwise
  # split a token — spaces, commas, `=`, `:` — are part of the key, not
  # delimiters. Brackets do not nest and carry no escapes (content runs to the
  # first `]`), matching `reference_segments/strip_segment`.
  bracket_chunk =
    string("[")
    |> repeat(
      lookahead_not(string("]"))
      |> utf8_char([])
    )
    |> optional(string("]"))
    |> reduce({List, :to_string, []})

  defparsecp(
    :paren_chunk,
    string("(")
    |> repeat(
      choice([
        parsec(:paren_chunk),
        double_quoted_chunk,
        single_quoted_chunk,
        bracket_chunk,
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
      bracket_chunk,
      lookahead_not(
        choice([
          string("|"),
          string("&&"),
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
        # Reserved boolean operators, matched before `|` so `||` never splits
        # into pipe stages (maximal munch); the parser rejects them.
        string("||") |> unwrap_and_tag(:reserved),
        string("&&") |> unwrap_and_tag(:reserved),
        string("|") |> unwrap_and_tag(:pipe),
        string(",") |> unwrap_and_tag(:comma),
        string("=") |> unwrap_and_tag(:eq),
        string(":") |> unwrap_and_tag(:colon),
        ascii_char([9, 10, 13, 32]) |> reduce({List, :to_string, []}) |> unwrap_and_tag(:ws),
        top_level_text_token
      ])
    )
  )

  @type context :: %{
          :in_each => boolean(),
          :locals => %{optional(binary()) => binary()},
          optional(:this_var) => binary(),
          optional(:parent_var) => binary() | nil,
          optional(:root_var) => binary()
        }
  @type helper_arg_t :: expr_t() | {:kw, binary(), expr_t()}
  @type pipeline_stage_t :: {:stage, binary(), [helper_arg_t()]}
  @type expr_t ::
          {:literal, binary()}
          | {:identifier, binary()}
          | {:special, :index | :index1 | :key | :first | :last}
          | {:path, :implicit | :this | :parent | :root, [binary()]}
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

  def to_source({:special, :index}, context), do: iteration_var(context, "stem_index")
  def to_source({:special, :index1}, context), do: iteration_var(context, "stem_index") <> " + 1"
  def to_source({:special, :key}, context), do: iteration_var(context, "stem_key")
  def to_source({:special, :first}, context), do: iteration_var(context, "stem_first")
  def to_source({:special, :last}, context), do: iteration_var(context, "stem_last")

  def to_source({:identifier, name}, context) do
    case local_source(context, name) do
      {:ok, source} -> source
      :error -> implicit_source(context, name, [])
    end
  end

  def to_source({:path, :implicit, [root | rest]}, context) do
    case local_source(context, root) do
      {:ok, source} -> field_chain(source, rest)
      :error -> implicit_source(context, root, rest)
    end
  end

  def to_source({:path, :this, segments}, context),
    do: context_source(this_var(context), segments)

  def to_source({:path, :root, segments}, _context),
    do: context_source(:root, segments)

  def to_source({:path, :parent, segments}, context) do
    case parent_var(context) do
      nil -> raise ArgumentError, "@parent is only available inside a block (#each / #with)"
      resolved -> context_source(resolved, segments)
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
  def format({:special, :first}), do: "@first"
  def format({:special, :last}), do: "@last"

  def format({:path, kind, segments}) when kind in [:this, :parent, :root],
    do: Enum.join(["@#{kind}" | Enum.map(segments, &format_segment/1)], ".")

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
  def references_identifier?({:identifier, name}, name), do: true
  def references_identifier?({:identifier, _}, _name), do: false
  # The contextual roots (@this/@parent/@root) never reference a block param.
  def references_identifier?({:path, kind, _}, _name) when kind in [:this, :parent, :root],
    do: false

  def references_identifier?({:path, :implicit, [root | _]}, name), do: root == name

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
    case reserved_operator(trimmed) do
      nil ->
        case split_top_level_pipe(trimmed) do
          [_single] ->
            :no_pipeline

          [head | stages] ->
            with {:ok, initial} <- parse_pipeline_input(head),
                 {:ok, parsed_stages} <- parse_pipeline_stages(stages) do
              {:ok, {:pipeline, initial, parsed_stages}}
            end
        end

      op ->
        {:error, "the '#{op}' operator is not supported"}
    end
  end

  # The first reserved boolean operator (`||`, `&&`) in the expression, if any.
  # Lexed by maximal munch so it never masquerades as a `|` pipe.
  defp reserved_operator(source) do
    source
    |> splitter_tokens()
    |> Enum.find_value(fn
      {:reserved, op} -> op
      _ -> nil
    end)
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
              case parse_helper_args(args) do
                {:ok, parsed_args} ->
                  {:ok, {:stage, name, parsed_args}}

                :error ->
                  {:error,
                   "pipeline stage arguments must be assigns, paths, literals, or key=value pairs"}
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
        {:ok, {:literal, normalize_literal_source(trimmed)}}

      trimmed == "null" ->
        {:ok, {:literal, "null"}}

      special = iteration_special(trimmed) ->
        {:ok, {:special, special}}

      result = context_path(trimmed) ->
        result

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
        {:ok, {:literal, normalize_literal_source(trimmed)}}

      trimmed == "null" ->
        {:ok, {:literal, "null"}}

      special = iteration_special(trimmed) ->
        {:ok, {:special, special}}

      result = context_path(trimmed) ->
        result

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

  defp build_reference(segments) do
    case Enum.map(segments, &strip_segment/1) do
      [single] -> {:ok, {:identifier, single}}
      keys -> {:ok, {:path, :implicit, keys}}
    end
  end

  # The iteration-only data variables (`@index`/`@index1`/`@key`/`@first`/
  # `@last`); `nil` for anything else. Their use outside an `#each` is rejected
  # during lowering, not parsing.
  defp iteration_special("@index"), do: :index
  defp iteration_special("@index1"), do: :index1
  defp iteration_special("@key"), do: :key
  defp iteration_special("@first"), do: :first
  defp iteration_special("@last"), do: :last
  defp iteration_special(_), do: nil

  # The contextual references `@this`/`@parent`/`@root`, optionally followed by a
  # dotted path. Returns `{:ok, {:path, kind, segments}}`, `:error` for a
  # malformed path after the context word, or `nil` when not a context reference.
  defp context_path(trimmed) do
    case context_split(trimmed) do
      nil ->
        nil

      {kind, ""} ->
        {:ok, {:path, kind, []}}

      {kind, rest} ->
        segments = @reference_segment |> Regex.scan(rest) |> List.flatten()

        if segments != [] and Enum.join(segments, ".") == rest do
          {:ok, {:path, kind, Enum.map(segments, &strip_segment/1)}}
        else
          :error
        end
    end
  end

  defp context_split("@this." <> rest), do: {:this, rest}
  defp context_split("@this"), do: {:this, ""}
  defp context_split("@parent." <> rest), do: {:parent, rest}
  defp context_split("@parent"), do: {:parent, ""}
  defp context_split("@root." <> rest), do: {:root, rest}
  defp context_split("@root"), do: {:root, ""}
  defp context_split(_), do: nil

  defp strip_segment("[" <> rest), do: binary_part(rest, 0, byte_size(rest) - 1)
  defp strip_segment(bare), do: bare

  defp this_var(context), do: Map.get(context, :this_var, :root)
  defp parent_var(context), do: Map.get(context, :parent_var, nil)

  # Iteration data variables exist only inside an `#each`; reject them elsewhere.
  defp iteration_var(%{in_each: true}, var), do: var

  defp iteration_var(_context, _var) do
    raise ArgumentError, "iteration variables (@index/@index1/@key/@first/@last) require an #each"
  end

  # A bare identifier or the root of an implicit path, resolved against the
  # current context: a field of the current item inside `#each`, otherwise a
  # top-level assign (preserving `#with`'s assign-based bare lookups).
  defp implicit_source(%{in_each: true} = context, root, rest),
    do: field_chain(this_var(context), [root | rest])

  defp implicit_source(_context, root, rest),
    do: field_chain(assign_marker(root), rest)

  # Lower a contextual reference (@this/@parent/@root) plus its path. When the
  # context resolves to the render root, the first segment is an assign read so
  # `@this.name`/`@root.name` are identical to `{{name}}`; otherwise it is a
  # field chain rooted at the context binding.
  defp context_source(:root, []), do: "assigns"
  defp context_source(:root, [root | rest]), do: field_chain(assign_marker(root), rest)
  defp context_source(var, segments) when is_binary(var), do: field_chain(var, segments)

  # Fold member access through the tolerant runtime accessor so missing keys and
  # out-of-range list indices render empty instead of raising.
  defp field_chain(base, segments) do
    Enum.reduce(segments, base, fn segment, acc ->
      "Stem.Runtime.get_field(#{acc}, #{segment_key(segment)})"
    end)
  end

  # A numeric segment lowers to an integer list index; any other segment to an
  # atom map key.
  defp segment_key(segment) do
    case Integer.parse(segment) do
      {index, ""} -> Integer.to_string(index)
      _ -> inspect(String.to_atom(segment))
    end
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
        ["this: #{this_var(context)}", "key: stem_key" | base]
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

  # Single- and double-quoted literals both denote string values. Rewrite a
  # single-quoted source to its double-quoted equivalent so lowering treats it
  # as a binary, not a charlist (which Elixir's parser deprecates). Other literal
  # sources pass through unchanged.
  defp normalize_literal_source(<<?', rest::binary>>) do
    inner = binary_part(rest, 0, byte_size(rest) - 1)
    ~s(") <> requote(inner, "") <> ~s(")
  end

  defp normalize_literal_source(source), do: source

  # Re-escape single-quoted content for a double-quoted context: drop the
  # backslash before an escaped single quote, escape bare double quotes, and
  # preserve every other escape so Elixir resolves it identically.
  defp requote(<<>>, acc), do: acc
  defp requote(<<?\\, ?', rest::binary>>, acc), do: requote(rest, acc <> "'")
  defp requote(<<?\\, c::utf8, rest::binary>>, acc), do: requote(rest, acc <> <<?\\, c::utf8>>)
  defp requote(<<?", rest::binary>>, acc), do: requote(rest, acc <> "\\\"")
  defp requote(<<c::utf8, rest::binary>>, acc), do: requote(rest, acc <> <<c::utf8>>)

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
end
