# SPDX-License-Identifier: Apache-2.0

defmodule Stem.AST do
  @moduledoc false

  # The Stem abstract syntax tree.
  #
  # `Stem.Parser` produces a list of these nodes from a token stream and
  # `Stem.Compiler` lowers them into quoted Elixir. Block bodies (`body` and
  # `else_body`) are themselves node lists, so the tree is fully recursive.
  #
  # Expression contents (`raw`, `cond`, `coll`, `subject`) are kept as raw
  # strings here; `Stem.Expression` translates them into Elixir AST during
  # compilation so that the parser stays independent of expression semantics.

  @type meta :: %{line: pos_integer(), column: pos_integer()}

  @type node_t ::
          {:text, binary()}
          | {:expr, binary(), meta()}
          | {:raw, binary(), meta()}
          | {:if, binary(), [node_t()], [node_t()], meta()}
          | {:unless, binary(), [node_t()], [node_t()], meta()}
          | {:each, binary(), [node_t()], [node_t()], meta()}
          | {:with, binary(), [node_t()], [node_t()], meta()}

  @type t :: [node_t()]
end
