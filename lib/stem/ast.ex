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

  @type meta :: %{line: pos_integer(), column: pos_integer()}

  @type node_t ::
          {:text, binary()}
          | {:expr, Stem.Expression.expr_t(), atom(), meta()}
          | {:if, Stem.Expression.expr_t(), [node_t()], [node_t()], meta()}
          | {:unless, Stem.Expression.expr_t(), [node_t()], [node_t()], meta()}
          | {:each, Stem.Expression.expr_t(), [binary()], [node_t()], [node_t()], meta()}
          | {:with, Stem.Expression.expr_t(), [binary()], [node_t()], [node_t()], meta()}

  @type t :: [node_t()]
end
