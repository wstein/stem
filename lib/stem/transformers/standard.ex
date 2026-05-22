# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Transformers.Standard do
  @moduledoc """
  Standard transformer bundle: the secure minimum plus string formatting.

  `Stem.Transformers.Standard` pre-merges `Stem.Transformers.Minimum` and
  `Stem.Transformers.Strings` so the most common presentation toolkit can be
  loaded with a single `.all()` call instead of a manual `Map.merge/2`:

      # Instead of:
      Map.merge(Stem.Transformers.Minimum.all(), Stem.Transformers.Strings.all())

      # Use:
      Stem.Transformers.Standard.all()

  ## Security boundary

  `Stem.Transformers.Collections` (`map`, `filter`, `group_by`, `sort_by`, …)
  is **deliberately excluded**. Those data-manipulation transformers widen the
  SSTI gadget chain available to an attacker, so they must remain an explicit,
  separate opt-in. Loading `Standard` therefore stays safe for templates that
  only need escaping, defaults, lookups, and text formatting.

  ## Example

      Stem.Unsafe.eval_string(
        "{{name |> trim |> upcase}}",
        assigns: [name: "nina"],
        transformers: Stem.Transformers.Standard.all()
      )
  """

  @type transformer :: ([term()], map() -> term())

  @doc """
  Return the standard transformer bundle (Minimum + Strings) as a map keyed by name.

  Collections transformers are intentionally not included.
  """
  @spec all() :: %{String.t() => transformer()}
  def all do
    Map.merge(Stem.Transformers.Minimum.all(), Stem.Transformers.Strings.all())
  end
end
