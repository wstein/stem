# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

defmodule Stem.SmartEngine do
  @moduledoc """
  The default engine used by Stem.

  It includes assigns (like `@foo`) and possibly other
  conveniences in the future.

  ## Examples

      iex> Stem.eval_string("{{foo}}", assigns: [foo: 1])
      "1"

  In the example above, we can access the value `foo` under
  the binding `assigns` using `@foo`. This is useful because
  a template, after being compiled, can receive different
  assigns and would not require recompilation for each
  variable set.

  Assigns can also be used when compiled to a function:

      # sample.stem
      {{a}}

      # sample.ex
      defmodule Sample do
        require Stem
        Stem.function_from_file(:def, :sample, "sample.stem", [:assigns])
      end

      # iex
      Sample.sample(a: 1)
      #=> "1"

  Missing assigns return `nil` by default. Pass `warn_on_missing_assigns: true`
  to print a warning for missing values.

  """

  @behaviour Stem.Engine

  @impl true
  def init(opts) do
    Stem.Engine.init(opts)
    |> Map.put(:warn_on_missing_assigns, Keyword.get(opts, :warn_on_missing_assigns, false))
  end

  @impl true
  defdelegate handle_body(state), to: Stem.Engine

  @impl true
  defdelegate handle_begin(state), to: Stem.Engine

  @impl true
  defdelegate handle_end(state), to: Stem.Engine

  @impl true
  defdelegate handle_text(state, meta, text), to: Stem.Engine

  @impl true
  def handle_expr(state, marker, expr) do
    expr = Macro.prewalk(expr, &Stem.Engine.handle_assign(&1, state.warn_on_missing_assigns))
    Stem.Engine.handle_expr(state, marker, expr)
  end
end
