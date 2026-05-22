# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Transformers.Predicates do
  @moduledoc """
  Predicate transformers: boolean tests for conditionals and filtering.

  Load this capability group when templates use predicates in block conditions or
  filter operations beyond what built-in Handlebars truthiness provides:
  - Presence tests: `contains`, `empty?`, `present?`

  These helpers are commonly used inside `{{#if}}` blocks and the `filter` helper.

  ## Example

      Stem.Unsafe.eval_string(
        template,
        assigns: data,
        transformers: Stem.Transformers.Predicates.all()
      )
  """

  alias Stem.Transformers.Shared

  @type transformer :: ([term()], map() -> term())

  @doc "Return all predicate transformers as a map keyed by name."
  @spec all() :: %{String.t() => transformer()}
  def all do
    %{
      "contains" => &contains/2,
      "empty?" => &empty_q/2,
      "present?" => &present_q/2
    }
  end

  # Helpers

  defp contains([collection, needle], _ctx) do
    contains_impl(collection, needle)
  end

  defp contains(args, _ctx) do
    raise ArgumentError, "contains expects 2 arguments, got: #{length(args)}"
  end

  defp contains_impl(collection, needle) when is_binary(collection) do
    String.contains?(collection, to_string(needle))
  end

  defp contains_impl(collection, needle) when is_map(collection) do
    Map.has_key?(collection, needle) or Map.has_key?(collection, to_string(needle))
  end

  defp contains_impl(collection, needle) when is_list(collection) do
    Enum.member?(collection, needle)
  end

  defp contains_impl(_collection, _needle), do: false

  defp empty_q([value], _ctx) do
    Shared.empty?(value)
  end

  defp empty_q(args, _ctx) do
    raise ArgumentError, "empty? expects 1 argument, got: #{length(args)}"
  end

  defp present_q([value], _ctx) do
    Shared.present?(value)
  end

  defp present_q(args, _ctx) do
    raise ArgumentError, "present? expects 1 argument, got: #{length(args)}"
  end
end
