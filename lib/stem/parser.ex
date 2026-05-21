# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Parser do
  @moduledoc false

  # Builds a `Stem.AST` from Stem source.
  #
  # The parser drives `Stem.Tokenizer`, matches block open/else/close tokens
  # into nested nodes, expands partials inline (with a recursion guard), and
  # reports structural errors such as mismatched or unclosed blocks. Expression
  # contents are left as raw strings for `Stem.Expression` to interpret later.

  alias Stem.Tokenizer

  @kind_tags %{if: "if", unless: "unless", each: "each", with: "with"}

  @spec parse(binary(), keyword()) :: {:ok, Stem.AST.t()} | {:error, binary(), Tokenizer.meta()}
  def parse(source, opts \\ []) when is_binary(source) do
    partials = opts |> Keyword.get(:partials, %{}) |> normalize_partials()

    with {:ok, tokens} <- Tokenizer.tokenize(source, opts) do
      parse_stream(tokens, partials, [])
    end
  end

  # Tokenizes and parses a nested source (used for partials).
  defp parse_source(source, partials, stack) do
    with {:ok, tokens} <- Tokenizer.tokenize(source) do
      parse_stream(tokens, partials, stack)
    end
  end

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

  defp collect([{:expr, raw, meta} | rest], partials, stack, acc) do
    collect(rest, partials, stack, [{:expr, raw, meta} | acc])
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
    case collect(tokens, partials, stack, []) do
      {:ok, body, {:else, _else_meta}, rest} ->
        parse_else(kind, args, body, meta, rest, partials, stack)

      {:ok, body, {:close, ^kind, _close_meta}, rest} ->
        {:ok, {kind, args, body, [], meta}, rest}

      {:ok, _body, {:close, other, close_meta}, _rest} ->
        {:error, mismatched_close(kind, other), close_meta}

      {:ok, _body, {:eof, _eof_meta}, _rest} ->
        {:error, unclosed_block(kind), meta}

      {:error, _message, _meta} = error ->
        error
    end
  end

  defp parse_else(kind, args, body, meta, tokens, partials, stack) do
    case collect(tokens, partials, stack, []) do
      {:ok, else_body, {:close, ^kind, _close_meta}, rest} ->
        {:ok, {kind, args, body, else_body, meta}, rest}

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
end
