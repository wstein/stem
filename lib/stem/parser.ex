# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Parser do
  @moduledoc false

  # Lexes and parses Stem source into a `Stem.AST`.
  #
  # This module combines lexing and structural parsing into a single stage.
  # NimbleParsec combinators recognise the `{{ }}` family of constructs and
  # attach line/column metadata via `post_traverse` hooks, eliminating manual
  # byte iteration for position tracking.  Elixir recursive-descent functions
  # then fold the flat token stream into the nested AST that `Stem.Compiler`
  # consumes.
  #
  # Partial expansion happens inline during the structural parse: each
  # `{{> name}}` token is replaced by recursively parsing the partial's source
  # with a recursion guard in the call stack.

  import NimbleParsec
  alias Stem.Expression

  # ---------------------------------------------------------------------------
  # Types (kept public so callers can reference them without Stem.Tokenizer)
  # ---------------------------------------------------------------------------

  @type meta :: %{
          required(:line) => pos_integer(),
          required(:column) => pos_integer(),
          optional(:end_line) => pos_integer(),
          optional(:end_column) => pos_integer()
        }
  @type kind :: :if | :unless | :each | :with | :region

  @type token ::
          {:text, binary(), meta()}
          | {:expr, binary(), atom(), meta()}
          | {:block_open, kind(), binary(), meta()}
          | {:block_else, meta()}
          | {:block_close, kind(), meta()}
          | {:yield, binary(), meta()}
          | {:partial, binary(), meta()}
          | {:eof, meta()}

  @block_kinds %{
    "if" => :if,
    "unless" => :unless,
    "each" => :each,
    "with" => :with,
    "region" => :region
  }

  @kind_tags %{if: "if", unless: "unless", each: "each", with: "with", region: "region"}

  # ---------------------------------------------------------------------------
  # NimbleParsec – position-capture callback
  # ---------------------------------------------------------------------------

  # Called by `post_traverse` hooks on each combinator.  Prepends
  # `{:end_pos, line, col}` to the accumulated args so that
  # `assemble_tokens/5` can read the end position of each raw token directly
  # from the tagged tuple without byte iteration.
  @doc false
  def inject_end_pos(rest, args, context, {line, line_offset}, byte_offset) do
    col = byte_offset - line_offset + 1
    # args is in reversed stack order; appending here means {:end_pos, ...}
    # appears FIRST after tag/1 reverses the accumulation.
    {rest, args ++ [{:end_pos, line, col}], context}
  end

  # ---------------------------------------------------------------------------
  # NimbleParsec combinators (compile-time)
  # ---------------------------------------------------------------------------

  # Matches any sequence of characters that does not start a `{{` tag.
  text_chunk =
    lookahead_not(string("{{"))
    |> utf8_char([])
    |> repeat(
      lookahead_not(string("{{"))
      |> utf8_char([])
    )
    |> reduce({List, :to_string, []})
    |> post_traverse({__MODULE__, :inject_end_pos, []})
    |> tag(:text_chunk)

  # Matches `{{!-- ... --}}` block comments.
  block_comment =
    ignore(string("{{!--"))
    |> repeat(
      lookahead_not(string("--}}"))
      |> utf8_char([])
    )
    |> ignore(string("--}}"))
    |> post_traverse({__MODULE__, :inject_end_pos, []})
    |> tag(:block_comment)

  # Matches `{{! ... }}` inline comments.
  inline_comment =
    ignore(string("{{!"))
    |> repeat(
      lookahead_not(string("}}"))
      |> utf8_char([])
    )
    |> ignore(string("}}"))
    |> post_traverse({__MODULE__, :inject_end_pos, []})
    |> tag(:inline_comment)

  # Matches `{{{ ... }}}` raw (no-escape) output.
  raw_tag =
    ignore(string("{{{"))
    |> repeat(
      lookahead_not(string("}}}"))
      |> utf8_char([])
    )
    |> ignore(string("}}}"))
    |> reduce({List, :to_string, []})
    |> post_traverse({__MODULE__, :inject_end_pos, []})
    |> tag(:raw_tag)

  # Matches `{{ ... }}` standard tags.
  standard_tag =
    ignore(string("{{"))
    |> repeat(
      lookahead_not(string("}}"))
      |> utf8_char([])
    )
    |> ignore(string("}}"))
    |> reduce({List, :to_string, []})
    |> post_traverse({__MODULE__, :inject_end_pos, []})
    |> tag(:standard_tag)

  defparsec(
    :do_lex,
    repeat(
      choice([
        block_comment,
        inline_comment,
        raw_tag,
        standard_tag,
        text_chunk
      ])
    )
  )

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec parse(binary(), keyword()) :: {:ok, Stem.AST.t()} | {:error, binary(), meta()}
  def parse(source, opts \\ []) when is_binary(source) do
    case parse_with_spans(source, opts) do
      {:ok, ast} -> {:ok, strip_ast_spans(ast)}
      {:error, message, meta} -> {:error, message, strip_meta_spans(meta)}
    end
  end

  @doc false
  @spec parse_with_spans(binary(), keyword()) :: {:ok, Stem.AST.t()} | {:error, binary(), meta()}
  def parse_with_spans(source, opts \\ []) when is_binary(source) do
    partials = opts |> Keyword.get(:partials, %{}) |> normalize_partials()

    with {:ok, tokens} <- tokenize_with_spans(source, opts) do
      parse_stream(tokens, partials, [])
    end
  end

  # Exposed for lexer-level tests (position tracking, trim markers, error
  # messages).  Not part of the stable public API.
  @doc false
  @spec tokenize(binary(), keyword()) :: {:ok, [token()]} | {:error, binary(), meta()}
  def tokenize(source, opts \\ []) when is_binary(source) do
    case tokenize_with_spans(source, opts) do
      {:ok, tokens} -> {:ok, Enum.map(tokens, &strip_token_spans/1)}
      {:error, message, meta} -> {:error, message, strip_meta_spans(meta)}
    end
  end

  defp tokenize_with_spans(source, opts) when is_binary(source) do
    line = Keyword.get(opts, :line, 1)
    column = Keyword.get(opts, :column, 1)

    case do_lex(source) do
      {:ok, raw_tokens, "", _ctx, _pos, _offset} ->
        assemble_tokens(raw_tokens, line, column, [], false)

      {:ok, _raw, rest, _ctx, {err_line, err_line_offset}, err_byte} ->
        err_col = err_byte - err_line_offset + 1

        {:error, unterminated_error(rest),
         %{line: err_line, column: err_col, end_line: err_line, end_column: err_col}}
    end
  end

  # ---------------------------------------------------------------------------
  # Token assembly
  # ---------------------------------------------------------------------------

  # Folds the flat list emitted by `do_lex/1` into the `[token()]` list
  # consumed by the structural parser.  Each raw token carries
  # `{:end_pos, end_line, end_col}` as its first element (injected by
  # `inject_end_pos/5`).  `{line, col}` is the START position of the current
  # token (equal to the end position of the previous token).

  defp assemble_tokens([], line, col, acc, _trim_next) do
    {:ok, Enum.reverse([{:eof, span_meta(line, col, line, col)} | acc])}
  end

  defp assemble_tokens(
         [{:text_chunk, [{:end_pos, end_line, end_col}, text]} | rest],
         line,
         col,
         acc,
         trim_next
       ) do
    {text_line, text_col, trimmed} =
      if trim_next do
        remaining = String.replace(text, ~r/\A[\s]+/u, "")
        stripped = binary_part(text, 0, byte_size(text) - byte_size(remaining))
        {new_line, new_col} = advance_through(stripped, line, col)
        {new_line, new_col, remaining}
      else
        {line, col, text}
      end

    acc2 =
      case {trimmed, acc} do
        {"", _} ->
          acc

        {_, [{:text, prev_text, prev_meta} | rest_acc]} ->
          [{:text, prev_text <> trimmed, prev_meta} | rest_acc]

        {_, _} ->
          [{:text, trimmed, span_meta(text_line, text_col, end_line, end_col)} | acc]
      end

    assemble_tokens(rest, end_line, end_col, acc2, false)
  end

  defp assemble_tokens(
         [{:block_comment, [{:end_pos, end_line, end_col} | _chars]} | rest],
         _line,
         _col,
         acc,
         trim_next
       ) do
    assemble_tokens(rest, end_line, end_col, acc, trim_next)
  end

  defp assemble_tokens(
         [{:inline_comment, [{:end_pos, end_line, end_col} | _chars]} | rest],
         _line,
         _col,
         acc,
         trim_next
       ) do
    assemble_tokens(rest, end_line, end_col, acc, trim_next)
  end

  defp assemble_tokens(
         [{:raw_tag, [{:end_pos, end_line, end_col}, inner]} | rest],
         line,
         col,
         acc,
         _trim_next
       ) do
    meta = span_meta(line, col, end_line, end_col)
    {inner2, trim_left, trim_right} = extract_trim_markers(inner)
    acc2 = maybe_trim_last_text(acc, trim_left)

    case classify_raw_expr(inner2, meta) do
      {:ok, token} -> assemble_tokens(rest, end_line, end_col, [token | acc2], trim_right)
      :skip -> assemble_tokens(rest, end_line, end_col, acc2, trim_right)
      {:error, message, emeta} -> {:error, message, emeta}
    end
  end

  defp assemble_tokens(
         [{:standard_tag, [{:end_pos, end_line, end_col}, inner]} | rest],
         line,
         col,
         acc,
         _trim_next
       ) do
    meta = span_meta(line, col, end_line, end_col)
    {inner2, trim_left, trim_right} = extract_trim_markers(inner)
    acc2 = maybe_trim_last_text(acc, trim_left)

    case classify(inner2, meta) do
      {:ok, token} -> assemble_tokens(rest, end_line, end_col, [token | acc2], trim_right)
      :skip -> assemble_tokens(rest, end_line, end_col, acc2, trim_right)
      {:error, message, emeta} -> {:error, message, emeta}
    end
  end

  defp maybe_trim_last_text(acc, false), do: acc

  defp maybe_trim_last_text([{:text, text, meta} | rest], true) do
    trimmed = String.replace(text, ~r/[\s]+\z/u, "")
    if trimmed == "", do: rest, else: [{:text, trimmed, meta} | rest]
  end

  defp maybe_trim_last_text(acc, true), do: acc

  # ---------------------------------------------------------------------------
  # Tag classification
  # ---------------------------------------------------------------------------

  defp classify(inner, meta) do
    tag = String.trim(inner)

    cond do
      String.contains?(tag, "{") or String.contains?(tag, "}") ->
        {:error, "nested braces are not supported in Stem expressions", meta}

      tag == "" ->
        :skip

      tag == "else" ->
        {:ok, {:block_else, meta}}

      first_word(tag) == "yield" ->
        classify_yield(tag, meta)

      String.starts_with?(tag, "#") ->
        classify_open(tag, meta)

      String.starts_with?(tag, "/") ->
        classify_close(tag, meta)

      String.starts_with?(tag, ">") ->
        name = tag |> binary_part(1, byte_size(tag) - 1) |> String.trim()
        {:ok, {:partial, name, meta}}

      true ->
        {:ok, {:expr, tag, :default, meta}}
    end
  end

  defp classify_raw_expr(inner, meta) do
    tag = String.trim(inner)

    cond do
      String.contains?(tag, "{") or String.contains?(tag, "}") ->
        {:error, "nested braces are not supported in Stem expressions", meta}

      tag == "" ->
        :skip

      true ->
        {:ok, {:expr, tag, :none, meta}}
    end
  end

  defp classify_open(tag, meta) do
    {name, args} =
      tag
      |> binary_part(1, byte_size(tag) - 1)
      |> split_first_word()

    case Map.fetch(@block_kinds, name) do
      {:ok, kind} -> {:ok, {:block_open, kind, args, meta}}
      :error -> {:error, "unsupported Stem block helper '{{##{name}}}'", meta}
    end
  end

  defp classify_yield(tag, meta) do
    {_yield, args} = split_first_word(tag)
    {:ok, {:yield, args, meta}}
  end

  defp classify_close(tag, meta) do
    name = binary_part(tag, 1, byte_size(tag) - 1) |> String.trim()

    case Map.fetch(@block_kinds, name) do
      {:ok, kind} -> {:ok, {:block_close, kind, meta}}
      :error -> {:error, "unsupported Stem closing tag '{{#{tag}}}'", meta}
    end
  end

  defp split_first_word(string) do
    case String.split(String.trim_leading(string), ~r/\s+/, parts: 2) do
      [word] -> {word, ""}
      [word, rest] -> {word, String.trim(rest)}
    end
  end

  defp first_word(string) do
    string
    |> split_first_word()
    |> elem(0)
  end

  defp extract_trim_markers(inner) do
    trimmed = String.trim(inner)
    trim_left = String.starts_with?(trimmed, "~")
    trim_right = String.ends_with?(trimmed, "~")

    normalized =
      trimmed
      |> maybe_trim_leading_marker(trim_left)
      |> maybe_trim_trailing_marker(trim_right)
      |> String.trim()

    {normalized, trim_left, trim_right}
  end

  defp maybe_trim_leading_marker(inner, true), do: String.trim_leading(inner, "~")
  defp maybe_trim_leading_marker(inner, false), do: inner

  defp maybe_trim_trailing_marker(inner, true), do: String.trim_trailing(inner, "~")
  defp maybe_trim_trailing_marker(inner, false), do: inner

  defp span_meta(line, column, end_line, end_column) do
    %{line: line, column: column, end_line: end_line, end_column: end_column}
  end

  # ---------------------------------------------------------------------------
  # Error messages (lexer level)
  # ---------------------------------------------------------------------------

  defp unterminated_error(<<"{{!--", _::binary>>),
    do: "expected closing '--}}' for Stem comment"

  defp unterminated_error(<<"{{!", _::binary>>),
    do: "expected closing '}}' for Stem comment"

  defp unterminated_error(<<"{{{", _::binary>>),
    do: "expected closing '}}}' for raw Stem expression"

  defp unterminated_error(<<"{{", _::binary>>),
    do: "expected closing '}}' for Stem expression"

  # ---------------------------------------------------------------------------
  # Position tracking (trim-next prefix only)
  # ---------------------------------------------------------------------------

  # Advances {line, col} through `binary`, computing the position of the first
  # character that follows it.  Used only when a right-trim marker strips
  # leading whitespace from the next text chunk and the chunk's start position
  # must be updated accordingly.
  #
  # Unlike the former `advance_binary/3`, this function is non-recursive: it
  # splits on newline boundaries once and computes the result with arithmetic.
  defp advance_through("", line, col), do: {line, col}

  defp advance_through(binary, line, col) do
    case :binary.split(binary, ["\r\n", "\n"], [:global]) do
      [only] ->
        {line, col + String.length(only)}

      parts ->
        {line + length(parts) - 1, String.length(List.last(parts)) + 1}
    end
  end

  # ---------------------------------------------------------------------------
  # Structural parser helpers
  # ---------------------------------------------------------------------------

  # Tokenises and parses a nested source (used for partial expansion).
  defp parse_source(source, partials, stack) do
    with {:ok, tokens} <- tokenize_with_spans(source, []) do
      parse_stream(tokens, partials, stack)
    end
  end

  defp strip_ast_spans(nodes), do: Enum.map(nodes, &strip_node_spans/1)

  defp strip_node_spans({:text, text}), do: {:text, text}
  defp strip_node_spans({:yield, name, meta}), do: {:yield, name, strip_meta_spans(meta)}

  defp strip_node_spans({:expr, expr, escape_mode, meta}) do
    {:expr, expr, escape_mode, strip_meta_spans(meta)}
  end

  defp strip_node_spans({:if, expr, body, else_body, meta}) do
    {:if, expr, strip_ast_spans(body), strip_ast_spans(else_body), strip_meta_spans(meta)}
  end

  defp strip_node_spans({:unless, expr, body, else_body, meta}) do
    {:unless, expr, strip_ast_spans(body), strip_ast_spans(else_body), strip_meta_spans(meta)}
  end

  defp strip_node_spans({:each, expr, params, body, else_body, meta}) do
    {:each, expr, params, strip_ast_spans(body), strip_ast_spans(else_body),
     strip_meta_spans(meta)}
  end

  defp strip_node_spans({:with, expr, params, body, else_body, meta}) do
    {:with, expr, params, strip_ast_spans(body), strip_ast_spans(else_body),
     strip_meta_spans(meta)}
  end

  defp strip_node_spans({:region, name, body, meta}) do
    {:region, name, strip_ast_spans(body), strip_meta_spans(meta)}
  end

  defp strip_meta_spans(%{line: line, column: column}), do: %{line: line, column: column}

  defp strip_token_spans({:text, text, meta}), do: {:text, text, strip_meta_spans(meta)}

  defp strip_token_spans({:expr, raw, escape_mode, meta}),
    do: {:expr, raw, escape_mode, strip_meta_spans(meta)}

  defp strip_token_spans({:block_open, kind, args, meta}),
    do: {:block_open, kind, args, strip_meta_spans(meta)}

  defp strip_token_spans({:block_else, meta}), do: {:block_else, strip_meta_spans(meta)}

  defp strip_token_spans({:block_close, kind, meta}),
    do: {:block_close, kind, strip_meta_spans(meta)}

  defp strip_token_spans({:yield, name, meta}), do: {:yield, name, strip_meta_spans(meta)}
  defp strip_token_spans({:partial, name, meta}), do: {:partial, name, strip_meta_spans(meta)}
  defp strip_token_spans({:eof, meta}), do: {:eof, strip_meta_spans(meta)}

  defp parse_stream(tokens, partials, stack) do
    case collect(tokens, partials, stack, []) do
      {:ok, nodes, {:eof, _meta}, []} ->
        {:ok, nodes}

      {:ok, _nodes, {:else, meta}, _rest} ->
        {:error, "unexpected '{{else}}' outside of a block", meta}

      {:ok, _nodes, {:close, kind, meta}, _rest} ->
        {:error, "unexpected closing tag '{{/#{@kind_tags[kind]}}}'", meta}

      {:error, _message, _meta} = error ->
        error
    end
  end

  # Collects nodes until a stop token (`{{else}}`, a block close, or eof).
  # Returns `{:ok, nodes, stop, rest}` or `{:error, message, meta}`.
  defp collect([{:text, text, _meta} | rest], partials, stack, acc) do
    collect(rest, partials, stack, [{:text, text} | acc])
  end

  defp collect([{:expr, raw, escape_mode, meta} | rest], partials, stack, acc) do
    case Expression.parse(raw) do
      {:ok, expr} -> collect(rest, partials, stack, [{:expr, expr, escape_mode, meta} | acc])
      {:error, message} -> {:error, message, meta}
    end
  end

  defp collect([{:yield, raw_name, meta} | rest], partials, stack, acc) do
    with :ok <- validate_region_name(raw_name) do
      collect(rest, partials, stack, [{:yield, raw_name, meta} | acc])
    else
      {:error, message} -> {:error, message, meta}
    end
  end

  defp collect([{:partial, name, meta} | rest], partials, stack, acc) do
    case expand_partial(name, meta, partials, stack) do
      {:ok, nodes} -> collect(rest, partials, stack, Enum.reverse(nodes, acc))
      {:error, _message, _meta} = error -> error
    end
  end

  defp collect([{:block_open, kind, args, meta} | rest], partials, stack, acc) do
    case parse_block(kind, args, meta, rest, partials, stack) do
      {:ok, node, rest} -> collect(rest, partials, stack, [node | acc])
      {:error, _message, _meta} = error -> error
    end
  end

  defp collect([{:block_else, meta} | rest], _partials, _stack, acc) do
    {:ok, Enum.reverse(acc), {:else, meta}, rest}
  end

  defp collect([{:block_close, kind, meta} | rest], _partials, _stack, acc) do
    {:ok, Enum.reverse(acc), {:close, kind, meta}, rest}
  end

  defp collect([{:eof, meta}], _partials, _stack, acc) do
    {:ok, Enum.reverse(acc), {:eof, meta}, []}
  end

  defp parse_block(kind, args, meta, tokens, partials, stack) do
    with {:ok, expr, params} <- parse_block_expression(kind, args) do
      case collect(tokens, partials, stack, []) do
        {:ok, _body, {:else, else_meta}, _rest} when kind == :region ->
          {:error, "unexpected '{{else}}' inside '{{#region}}'", else_meta}

        {:ok, body, {:else, _else_meta}, rest} ->
          parse_else(kind, expr, params, body, meta, rest, partials, stack)

        {:ok, body, {:close, ^kind, _close_meta}, rest} ->
          {:ok, block_node(kind, expr, params, body, [], meta), rest}

        {:ok, _body, {:close, other, close_meta}, _rest} ->
          {:error, mismatched_close(kind, other), close_meta}

        {:ok, _body, {:eof, _eof_meta}, _rest} ->
          {:error, unclosed_block(kind), meta}

        {:error, _message, _meta} = error ->
          error
      end
    else
      {:error, message} -> {:error, message, meta}
    end
  end

  defp parse_else(kind, expr, params, body, meta, tokens, partials, stack) do
    case collect(tokens, partials, stack, []) do
      {:ok, else_body, {:close, ^kind, _close_meta}, rest} ->
        {:ok, block_node(kind, expr, params, body, else_body, meta), rest}

      {:ok, _else_body, {:else, else_meta}, _rest} ->
        {:error, "unexpected second '{{else}}' inside '{{##{@kind_tags[kind]}}}'", else_meta}

      {:ok, _else_body, {:close, other, close_meta}, _rest} ->
        {:error, mismatched_close(kind, other), close_meta}

      {:ok, _else_body, {:eof, _eof_meta}, _rest} ->
        {:error, unclosed_block(kind), meta}

      {:error, _message, _meta} = error ->
        error
    end
  end

  defp parse_block_expression(kind, args) when kind in [:if, :unless] do
    case Expression.parse(args) do
      {:ok, expr} -> {:ok, expr, []}
      {:error, _message} = error -> error
    end
  end

  defp parse_block_expression(kind, args) when kind in [:each, :with] do
    case split_block_params(args) do
      {:ok, expr_source, params} ->
        with :ok <- validate_block_params(kind, params),
             {:ok, expr} <- Expression.parse(expr_source) do
          {:ok, expr, params}
        end
    end
  end

  defp parse_block_expression(:region, args) do
    name = String.trim(args)

    with :ok <- validate_region_name(name) do
      {:ok, name, []}
    end
  end

  defp split_block_params(args) do
    case Regex.run(~r/^(.*?)(?:\s+as\s+\|([^|]+)\|)?\s*$/s, args, capture: :all_but_first) do
      [expr_source] ->
        {:ok, String.trim(expr_source), []}

      [expr_source, params_source] ->
        params = params_source |> String.split(~r/\s+/, trim: true)
        {:ok, String.trim(expr_source), params}
    end
  end

  defp validate_block_params(:with, []), do: :ok
  defp validate_block_params(:with, [_param]), do: :ok

  defp validate_block_params(:with, _params),
    do: {:error, "{{#with}} accepts at most one block parameter"}

  defp validate_block_params(:each, params) when length(params) <= 3,
    do: validate_identifier_list(params)

  defp validate_block_params(:each, _params),
    do: {:error, "{{#each}} accepts at most three block parameters"}

  defp validate_identifier_list(params) do
    cond do
      Enum.any?(params, &(not String.match?(&1, ~r/^[A-Za-z_][A-Za-z0-9_]*$/))) ->
        {:error, "block parameters must be simple identifiers"}

      length(params) != length(Enum.uniq(params)) ->
        {:error, "block parameters must be unique"}

      true ->
        :ok
    end
  end

  defp block_node(:each, expr, params, body, else_body, meta),
    do: {:each, expr, params, body, else_body, meta}

  defp block_node(:with, expr, params, body, else_body, meta),
    do: {:with, expr, params, body, else_body, meta}

  defp block_node(:region, name, _params, body, _else_body, meta),
    do: {:region, name, body, meta}

  defp block_node(kind, expr, _params, body, else_body, meta),
    do: {kind, expr, body, else_body, meta}

  defp mismatched_close(open_kind, close_kind) do
    "unexpected closing tag '{{/#{@kind_tags[close_kind]}}}'; " <>
      "expected '{{/#{@kind_tags[open_kind]}}}'"
  end

  defp unclosed_block(kind) do
    "expected a closing '{{/#{@kind_tags[kind]}}}' for block expression in Stem"
  end

  defp expand_partial("", meta, _partials, _stack) do
    {:error, "partial name is required in '{{> ...}}'", meta}
  end

  defp expand_partial(name, meta, partials, stack) do
    cond do
      name in stack ->
        {:error, "partial recursion detected for '#{name}'", meta}

      true ->
        case Map.fetch(partials, name) do
          {:ok, content} -> parse_source(content, partials, [name | stack])
          :error -> {:error, "unknown partial '#{name}'", meta}
        end
    end
  end

  defp normalize_partials(partials) when is_map(partials) do
    Map.new(partials, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_partials(partials) when is_list(partials) do
    partials |> Enum.into(%{}) |> normalize_partials()
  end

  defp validate_region_name(name) do
    cond do
      name == "" ->
        {:error, "region name is required"}

      String.match?(name, ~r/^[a-z_][a-zA-Z0-9_]*$/) ->
        :ok

      true ->
        {:error, "region names must be simple identifiers"}
    end
  end
end
