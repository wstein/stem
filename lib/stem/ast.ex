# SPDX-License-Identifier: Apache-2.0

defmodule Stem.AST do
  @moduledoc false

  # The Stem abstract syntax tree.
  #
  # `Stem.Parser` produces a list of these nodes from a token stream and
  # `Stem.Compiler` lowers them into quoted Elixir. Block bodies (`body` and
  # `else_body`) are themselves node lists, so the tree is fully recursive.
  #
  # Expression contents are parsed into `Stem.Expression` nodes here so later
  # compiler phases can analyze and transform them without re-tokenizing raw
  # text.

  alias Stem.Bytecode

  @type meta :: %{line: pos_integer(), column: pos_integer()}

  @type node_t ::
          {:text, binary()}
          | {:expr, Stem.Expression.expr_t(), atom(), meta()}
          | {:yield, binary(), meta()}
          | {:region, binary(), [node_t()], meta()}
          | {:if, Stem.Expression.expr_t(), [node_t()], [node_t()], meta()}
          | {:unless, Stem.Expression.expr_t(), [node_t()], [node_t()], meta()}
          | {:each, Stem.Expression.expr_t(), [binary()], [node_t()], [node_t()], meta()}
          | {:with, Stem.Expression.expr_t(), [binary()], [node_t()], [node_t()], meta()}
          | {:partial_scope, Stem.Expression.expr_t() | nil, [{atom(), Stem.Expression.expr_t()}],
             [node_t()], meta()}
          | {:partial, binary(), Stem.Expression.expr_t() | nil,
             [{atom(), Stem.Expression.expr_t()}], meta()}

  @type t :: [node_t()]

  # The pre-expansion AST wire shape (mirrors the Rust `parse_ast` export). It is
  # the conceptual contract between the two backends: node kinds and expression
  # kinds match, while `src` is backend-native provenance — line/column here,
  # byte spans in Rust (exact byte parity is not required, conceptual parity is).
  @ast_version "stem-ast/v1"

  @doc """
  Serializes a pre-expansion AST (from `Stem.Parser.parse_ast/2`) to the
  `stem-ast/v1` wire map `%{"version" => ..., "nodes" => [...]}`.

  Keeps `{{> name}}` as `partial` nodes and renders expressions in their written
  syntactic form, so the playground can draw the partial dependency graph and the
  per-file AST view.
  """
  @spec to_wire(t()) :: map()
  def to_wire(nodes) when is_list(nodes) do
    %{"version" => @ast_version, "nodes" => Enum.map(nodes, &wire_node/1)}
  end

  defp wire_node({:text, text}), do: %{"t" => "text", "text" => text}

  defp wire_node({:expr, expr, escape, meta}) do
    %{"t" => "emit", "expr" => wire_expr(expr), "escape" => Atom.to_string(escape)}
    |> put_src(meta)
  end

  defp wire_node({:yield, name, meta}) do
    put_src(%{"t" => "yield", "name" => name}, meta)
  end

  defp wire_node({:region, name, body, meta}) do
    put_src(%{"t" => "region", "name" => name, "body" => Enum.map(body, &wire_node/1)}, meta)
  end

  defp wire_node({:if, cond, body, else_body, meta}) do
    wire_conditional("if", cond, body, else_body, meta)
  end

  defp wire_node({:unless, cond, body, else_body, meta}) do
    wire_conditional("unless", cond, body, else_body, meta)
  end

  defp wire_node({:each, subject, params, body, else_body, meta}) do
    wire_loop("each", subject, params, body, else_body, meta)
  end

  defp wire_node({:with, subject, params, body, else_body, meta}) do
    wire_loop("with", subject, params, body, else_body, meta)
  end

  defp wire_node({:partial_scope, context, hash, body, meta}) do
    %{
      "t" => "partial_scope",
      "context" => wire_optional_expr(context),
      "hash" => wire_hash(hash),
      "body" => Enum.map(body, &wire_node/1)
    }
    |> put_src(meta)
  end

  defp wire_node({:partial, name, context, hash, meta}) do
    %{
      "t" => "partial",
      "name" => name,
      "context" => wire_optional_expr(context),
      "hash" => wire_hash(hash)
    }
    |> put_src(meta)
  end

  defp wire_conditional(tag, cond, body, else_body, meta) do
    put_src(
      %{
        "t" => tag,
        "cond" => wire_expr(cond),
        "then" => Enum.map(body, &wire_node/1),
        "else" => Enum.map(else_body, &wire_node/1)
      },
      meta
    )
  end

  defp wire_loop(tag, subject, params, body, else_body, meta) do
    put_src(
      %{
        "t" => tag,
        "subject" => wire_expr(subject),
        "params" => params,
        "body" => Enum.map(body, &wire_node/1),
        "else" => Enum.map(else_body, &wire_node/1)
      },
      meta
    )
  end

  defp put_src(node, %{line: line, column: column}) do
    Map.put(node, "src", %{"line" => line, "column" => column})
  end

  defp wire_hash(hash) do
    Map.new(hash, fn {key, value} -> {Atom.to_string(key), wire_expr(value)} end)
  end

  defp wire_optional_expr(nil), do: nil
  defp wire_optional_expr(expr), do: wire_expr(expr)

  # Render an expression in its written syntactic form (not the scope-aware
  # value op the bytecode lowers to), matching the Rust AST serializer.
  defp wire_expr({:literal, source}) do
    value =
      case Bytecode.literal_value(source) do
        {:ok, resolved} -> resolved
        :error -> source
      end

    %{"t" => "lit", "value" => value}
  end

  defp wire_expr({:identifier, name}), do: %{"t" => "identifier", "name" => name}

  defp wire_expr({:special, kind}), do: %{"t" => Atom.to_string(kind)}

  defp wire_expr({:path, :implicit, segments}), do: %{"t" => "path", "segments" => segments}

  defp wire_expr({:path, kind, segments}) when kind in [:this, :parent, :root] do
    %{"t" => "context", "kind" => Atom.to_string(kind), "path" => segments}
  end

  defp wire_expr({:transformer, name, args}) do
    %{"t" => "call", "name" => name, "args" => Enum.map(args, &wire_arg/1)}
  end

  defp wire_expr({:pipeline, lhs, stages}) do
    %{"t" => "pipeline", "lhs" => wire_expr(lhs), "stages" => Enum.map(stages, &wire_stage/1)}
  end

  defp wire_stage({:stage, name, args}) do
    %{"name" => name, "args" => Enum.map(args, &wire_arg/1)}
  end

  defp wire_arg({:kw, key, value}) do
    %{"kind" => "keyword", "key" => key, "value" => wire_expr(value)}
  end

  defp wire_arg(expr), do: %{"kind" => "positional", "value" => wire_expr(expr)}
end
