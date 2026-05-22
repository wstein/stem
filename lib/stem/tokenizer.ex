# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Tokenizer do
  @moduledoc false

  # Scans Stem source into a flat list of structural tokens.
  #
  # The tokenizer is purely lexical: it recognizes the `{{ }}` family of
  # constructs and classifies tag prefixes (`#`, `/`, `>`, `else`), but it does
  # not match blocks or interpret expression contents. Block nesting is the
  # parser's job; expression semantics belong to `Stem.Expression`.
  #
  # The lexer is implemented with `nimble_parsec` combinators. The public
  # `tokenize/2` interface and the `[token()]` output format are unchanged so
  # that `Stem.Parser` requires no modifications.

  import NimbleParsec

  @type meta :: %{line: pos_integer(), column: pos_integer()}
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

  # Matches `{{!-- ... --}}` block comments. Retains char codepoints so
  # `build_tokens/5` can reconstruct the raw text for position tracking.
  block_comment =
    ignore(string("{{!--"))
    |> repeat(
      lookahead_not(string("--}}"))
      |> utf8_char([])
    )
    |> ignore(string("--}}"))
    |> tag(:block_comment)

  # Matches `{{! ... }}` inline comments.
  inline_comment =
    ignore(string("{{!"))
    |> repeat(
      lookahead_not(string("}}"))
      |> utf8_char([])
    )
    |> ignore(string("}}"))
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
    |> tag(:standard_tag)

  defparsec(
    :do_tokenize,
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

  @spec tokenize(binary(), keyword()) :: {:ok, [token()]} | {:error, binary(), meta()}
  def tokenize(source, opts \\ []) when is_binary(source) do
    line = Keyword.get(opts, :line, 1)
    column = Keyword.get(opts, :column, 1)

    case do_tokenize(source) do
      {:ok, raw_tokens, "", _context, {end_line, end_line_offset}, end_byte} ->
        end_col = end_byte - end_line_offset + 1
        build_tokens(raw_tokens, line, column, end_line, end_col)

      {:ok, _raw_tokens, rest, _context, {err_line, err_line_offset}, err_byte} ->
        err_col = err_byte - err_line_offset + 1
        {:error, unterminated_error(rest), %{line: err_line, column: err_col}}
    end
  end

  # ---------------------------------------------------------------------------
  # Token assembly
  # ---------------------------------------------------------------------------

  # Converts the flat list emitted by `do_tokenize/1` into the structured
  # `[token()]` list consumed by `Stem.Parser`, applying whitespace trim markers
  # and line/column tracking along the way.
  #
  # State threaded through the reduce:
  #   `{:ok, acc, line, col, trim_next}`
  #   - `acc` is a reversed token list (head = most recently added token)
  #   - `trim_next` is true when the previous tag carried a right-trim marker
  #
  # Text merging: consecutive text runs (surrounding a skipped/comment token)
  # are merged into the first run's token so the output matches the original
  # scan/6 behaviour.
  defp build_tokens(raw_tokens, start_line, start_col, _end_line, _end_col) do
    result =
      Enum.reduce_while(
        raw_tokens,
        {:ok, [], start_line, start_col, false},
        fn raw, {:ok, acc, line, col, trim_next} ->
          case raw do
            text when is_binary(text) ->
              # Advance past any whitespace stripped by a preceding right-trim marker.
              {stripped_len, trimmed_text} =
                if trim_next do
                  remaining = String.replace(text, ~r/\A[\s]+/u, "")
                  {byte_size(text) - byte_size(remaining), remaining}
                else
                  {0, text}
                end

              stripped_prefix = binary_part(text, 0, stripped_len)
              {text_line, text_col} = advance_binary(stripped_prefix, line, col)
              {line2, col2} = advance_binary(trimmed_text, text_line, text_col)

              # Merge with immediately preceding :text token (handles skipped tags
              # and comments between two text runs).
              acc2 =
                case {trimmed_text, acc} do
                  {"", _} ->
                    acc

                  {_, [{:text, prev_text, prev_meta} | rest_acc]} ->
                    [{:text, prev_text <> trimmed_text, prev_meta} | rest_acc]

                  {_, _} ->
                    [{:text, trimmed_text, %{line: text_line, column: text_col}} | acc]
                end

              {:cont, {:ok, acc2, line2, col2, false}}

            {:block_comment, chars} ->
              inner = List.to_string(chars)
              {line2, col2} = advance_binary("{{!--" <> inner <> "--}}", line, col)
              {:cont, {:ok, acc, line2, col2, trim_next}}

            {:inline_comment, chars} ->
              inner = List.to_string(chars)
              {line2, col2} = advance_binary("{{!" <> inner <> "}}", line, col)
              {:cont, {:ok, acc, line2, col2, trim_next}}

            {:raw_tag, [inner]} ->
              meta = %{line: line, column: col}
              {line2, col2} = advance_binary("{{{" <> inner <> "}}}", line, col)
              {inner2, trim_left, trim_right} = extract_trim_markers(inner)
              acc2 = maybe_trim_last_text(acc, trim_left)

              case classify_raw_expr(inner2, meta) do
                {:ok, token} -> {:cont, {:ok, [token | acc2], line2, col2, trim_right}}
                :skip -> {:cont, {:ok, acc2, line2, col2, trim_right}}
                {:error, message, emeta} -> {:halt, {:error, message, emeta}}
              end

            {:standard_tag, [inner]} ->
              meta = %{line: line, column: col}
              {line2, col2} = advance_binary("{{" <> inner <> "}}", line, col)
              {inner2, trim_left, trim_right} = extract_trim_markers(inner)
              acc2 = maybe_trim_last_text(acc, trim_left)

              case classify(inner2, meta) do
                {:ok, token} -> {:cont, {:ok, [token | acc2], line2, col2, trim_right}}
                :skip -> {:cont, {:ok, acc2, line2, col2, trim_right}}
                {:error, message, emeta} -> {:halt, {:error, message, emeta}}
              end
          end
        end
      )

    case result do
      {:ok, acc, final_line, final_col, _trim_next} ->
        eof = {:eof, %{line: final_line, column: final_col}}
        {:ok, Enum.reverse([eof | acc])}

      {:error, _message, _meta} = error ->
        error
    end
  end

  # Strip trailing whitespace from the most-recent :text token in `acc`.
  defp maybe_trim_last_text(acc, false), do: acc

  defp maybe_trim_last_text([{:text, text, meta} | rest], true) do
    trimmed = String.replace(text, ~r/[\s]+\z/u, "")
    if trimmed == "", do: rest, else: [{:text, trimmed, meta} | rest]
  end

  defp maybe_trim_last_text(acc, true), do: acc

  # ---------------------------------------------------------------------------
  # Tag classification (identical logic to the original scan/6 helpers)
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

  # ---------------------------------------------------------------------------
  # Error message helpers
  # ---------------------------------------------------------------------------

  # Maps the unparsed rest to the descriptive error message that the old
  # hand-written scanner produced.
  defp unterminated_error(<<"{{!--", _::binary>>),
    do: "expected closing '--}}' for Stem comment"

  defp unterminated_error(<<"{{!", _::binary>>),
    do: "expected closing '}}' for Stem comment"

  defp unterminated_error(<<"{{{", _::binary>>),
    do: "expected closing '}}}' for raw Stem expression"

  defp unterminated_error(<<"{{", _::binary>>),
    do: "expected closing '}}' for Stem expression"

  # ---------------------------------------------------------------------------
  # Position tracking
  # ---------------------------------------------------------------------------

  defp advance_binary(<<"\r\n", rest::binary>>, line, _column),
    do: advance_binary(rest, line + 1, 1)

  defp advance_binary(<<"\n", rest::binary>>, line, _column),
    do: advance_binary(rest, line + 1, 1)

  defp advance_binary(<<_char::utf8, rest::binary>>, line, column),
    do: advance_binary(rest, line, column + 1)

  defp advance_binary(<<>>, line, column), do: {line, column}
end
