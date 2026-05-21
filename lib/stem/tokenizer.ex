# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Tokenizer do
  @moduledoc false

  # Scans Stem source into a flat list of structural tokens.
  #
  # The tokenizer is purely lexical: it recognizes the `{{ }}` family of
  # constructs and classifies tag prefixes (`#`, `/`, `>`, `else`), but it does
  # not match blocks or interpret expression contents. Block nesting is the
  # parser's job; expression semantics belong to `Stem.Expression`.

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

  @spec tokenize(binary(), keyword()) :: {:ok, [token()]} | {:error, binary(), meta()}
  def tokenize(source, opts \\ []) when is_binary(source) do
    line = Keyword.get(opts, :line, 1)
    column = Keyword.get(opts, :column, 1)

    scan(source, line, column, [], nil, [])
  end

  # `buffer` accumulates literal text as reverse iodata; `buffer_meta` records
  # where the current text run started so the flushed `:text` token is anchored.

  defp scan(<<"{{!--", rest::binary>>, line, column, buffer, buffer_meta, acc) do
    meta = %{line: line, column: column}

    case take_until(rest, "--}}") do
      {:ok, comment, tail} ->
        {line, column} = advance(["{{!--", comment, "--}}"], line, column)
        scan(tail, line, column, buffer, buffer_meta, acc)

      :error ->
        {:error, "expected closing '--}}' for Stem comment", meta}
    end
  end

  defp scan(<<"{{!", rest::binary>>, line, column, buffer, buffer_meta, acc) do
    meta = %{line: line, column: column}

    case take_until(rest, "}}") do
      {:ok, comment, tail} ->
        {line, column} = advance(["{{!", comment, "}}"], line, column)
        scan(tail, line, column, buffer, buffer_meta, acc)

      :error ->
        {:error, "expected closing '}}' for Stem comment", meta}
    end
  end

  defp scan(<<"{{{", rest::binary>>, line, column, buffer, buffer_meta, acc) do
    meta = %{line: line, column: column}

    case take_until(rest, "}}}") do
      {:ok, inner, tail} ->
        {line, column} = advance(["{{{", inner, "}}}"], line, column)
        {inner, trim_left, trim_right} = extract_trim_markers(inner)
        {buffer, buffer_meta} = maybe_trim_buffer(buffer, buffer_meta, trim_left)
        {tail, line, column} = maybe_trim_leading_tail(tail, line, column, trim_right)

        case classify_raw_expr(inner, meta) do
          {:ok, token} ->
            acc = flush(buffer, buffer_meta, acc)
            scan(tail, line, column, [], nil, [token | acc])

          :skip ->
            scan(tail, line, column, buffer, buffer_meta, acc)

          {:error, _message, _meta} = error ->
            error
        end

      :error ->
        {:error, "expected closing '}}}' for raw Stem expression", meta}
    end
  end

  defp scan(<<"{{", rest::binary>>, line, column, buffer, buffer_meta, acc) do
    meta = %{line: line, column: column}

    case take_until(rest, "}}") do
      {:ok, inner, tail} ->
        {line, column} = advance(["{{", inner, "}}"], line, column)
        {inner, trim_left, trim_right} = extract_trim_markers(inner)
        {buffer, buffer_meta} = maybe_trim_buffer(buffer, buffer_meta, trim_left)
        {tail, line, column} = maybe_trim_leading_tail(tail, line, column, trim_right)

        case classify(inner, meta) do
          {:ok, token} ->
            acc = flush(buffer, buffer_meta, acc)
            scan(tail, line, column, [], nil, [token | acc])

          :skip ->
            scan(tail, line, column, buffer, buffer_meta, acc)

          {:error, _message, _meta} = error ->
            error
        end

      :error ->
        {:error, "expected closing '}}' for Stem expression", meta}
    end
  end

  defp scan(<<char::utf8, rest::binary>>, line, column, buffer, buffer_meta, acc) do
    buffer_meta = buffer_meta || %{line: line, column: column}
    {line, column} = advance_char(char, line, column)
    scan(rest, line, column, [buffer | <<char::utf8>>], buffer_meta, acc)
  end

  defp scan(<<>>, line, column, buffer, buffer_meta, acc) do
    acc = flush(buffer, buffer_meta, acc)
    eof = {:eof, %{line: line, column: column}}
    {:ok, Enum.reverse([eof | acc])}
  end

  # Classifies the contents of a `{{ ... }}` tag into a structural token.
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

  defp maybe_trim_buffer(buffer, buffer_meta, false), do: {buffer, buffer_meta}

  defp maybe_trim_buffer(buffer, buffer_meta, true) do
    trimmed = buffer |> IO.iodata_to_binary() |> String.replace(~r/[\s]+$/u, "")

    case trimmed do
      "" -> {[], nil}
      _ -> {[trimmed], buffer_meta}
    end
  end

  defp maybe_trim_leading_tail(tail, line, column, false), do: {tail, line, column}

  defp maybe_trim_leading_tail(tail, line, column, true) do
    trimmed_tail = String.replace(tail, ~r/^[\s]+/u, "")
    removed_size = byte_size(tail) - byte_size(trimmed_tail)
    <<removed::binary-size(^removed_size), _::binary>> = tail
    {line, column} = advance(removed, line, column)
    {trimmed_tail, line, column}
  end

  defp flush([], _buffer_meta, acc), do: acc

  defp flush(buffer, buffer_meta, acc),
    do: [{:text, IO.iodata_to_binary(buffer), buffer_meta} | acc]

  defp take_until(source, delimiter) do
    case :binary.match(source, delimiter) do
      {index, _length} ->
        delimiter_size = byte_size(delimiter)
        <<inner::binary-size(^index), _::binary-size(^delimiter_size), rest::binary>> = source
        {:ok, inner, rest}

      :nomatch ->
        :error
    end
  end

  defp advance(iodata, line, column) do
    iodata
    |> IO.iodata_to_binary()
    |> advance_binary(line, column)
  end

  defp advance_binary(<<"\r\n", rest::binary>>, line, _column),
    do: advance_binary(rest, line + 1, 1)

  defp advance_binary(<<"\n", rest::binary>>, line, _column),
    do: advance_binary(rest, line + 1, 1)

  defp advance_binary(<<_char::utf8, rest::binary>>, line, column),
    do: advance_binary(rest, line, column + 1)

  defp advance_binary(<<>>, line, column), do: {line, column}

  defp advance_char(?\n, line, _column), do: {line + 1, 1}
  defp advance_char(_char, line, column), do: {line, column + 1}
end
