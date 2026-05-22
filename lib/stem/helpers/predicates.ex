# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Helpers.Predicates do
  @moduledoc """
  Predicate helpers: boolean tests for conditionals and filtering.

  Load this capability group when templates use predicates in block conditions or
  filter operations beyond what built-in Handlebars truthiness provides:
  - Presence tests: `contains`, `empty?`, `present?`

  These helpers are commonly used inside `{{#if}}` blocks and the `filter` helper.

  ## Example

      Stem.Unsafe.eval_string(
        template,
        assigns: data,
        helper_groups: [Stem.Helpers.Predicates]
      )
  """

  @type helper :: ([term()], map() -> term())

  @doc "Return all predicate helpers as a map keyed by name."
  @spec all() :: %{String.t() => helper()}
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
    empty_impl(value)
  end

  defp empty_q(args, _ctx) do
    raise ArgumentError, "empty? expects 1 argument, got: #{length(args)}"
  end

  defp empty_impl(value) when value in [nil, "", []], do: true
  defp empty_impl(value) when is_map(value), do: map_size(value) == 0
  defp empty_impl(value) when is_list(value), do: value == []
  defp empty_impl(value) when is_binary(value), do: value == ""
  defp empty_impl(_value), do: false

  defp present_q([value], _ctx) do
    not empty_impl(value)
  end

  defp present_q(args, _ctx) do
    raise ArgumentError, "present? expects 1 argument, got: #{length(args)}"
  end
end
