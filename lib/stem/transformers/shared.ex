# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Transformers.Shared do
  @moduledoc false

  # Single source of truth for transformer implementations and helpers used by
  # more than one capability group. The `Stem.Transformers.*` group modules
  # reference these instead of carrying their own copies.

  @type transformer :: ([term()], map() -> term())

  # ── Transformers shared by Strings and Collections ─────────────────────────

  @spec take([term()], map()) :: term()
  def take([value, count], _ctx), do: take_impl(value, count)

  def take(args, _ctx) do
    raise ArgumentError, "take expects 2 arguments, got: #{length(args)}"
  end

  @spec drop([term()], map()) :: term()
  def drop([value, count], _ctx), do: drop_impl(value, count)

  def drop(args, _ctx) do
    raise ArgumentError, "drop expects 2 arguments, got: #{length(args)}"
  end

  @spec slice([term()], map()) :: term()
  def slice([value, start, length], _ctx), do: slice_impl(value, start, length)

  def slice(args, _ctx) do
    raise ArgumentError, "slice expects 3 arguments, got: #{length(args)}"
  end

  @spec first([term()], map()) :: term()
  def first([value], _ctx), do: first_impl(value)

  def first(args, _ctx) do
    raise ArgumentError, "first expects 1 argument, got: #{length(args)}"
  end

  @spec reverse([term()], map()) :: term()
  def reverse([value], _ctx), do: reverse_impl(value)

  def reverse(args, _ctx) do
    raise ArgumentError, "reverse expects 1 argument, got: #{length(args)}"
  end

  # ── Pure helpers ───────────────────────────────────────────────────────────

  @spec enumerable_list(term()) :: list()
  def enumerable_list(value) when is_list(value), do: value
  def enumerable_list(value) when is_map(value), do: Map.values(value)
  def enumerable_list(nil), do: []
  def enumerable_list(value), do: List.wrap(value)

  @spec normalize_integer(term(), String.t()) :: integer()
  def normalize_integer(value, _helper) when is_integer(value), do: value

  def normalize_integer(value, helper) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> raise ArgumentError, "#{helper} expects integer arguments"
    end
  end

  def normalize_integer(value, helper) do
    raise ArgumentError, "#{helper} expects integer arguments, got: #{inspect(value)}"
  end

  @spec empty?(term()) :: boolean()
  def empty?(value) when value in [nil, "", []], do: true
  def empty?(value) when is_map(value), do: map_size(value) == 0
  def empty?(value) when is_list(value), do: value == []
  def empty?(value) when is_binary(value), do: value == ""
  def empty?(_value), do: false

  @spec present?(term()) :: boolean()
  def present?(value), do: not empty?(value)

  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: value not in [false, nil, 0, "", [], %{}]

  @spec select_value(term(), term()) :: term()
  def select_value(value, selector) do
    selector
    |> selector_segments()
    |> Enum.reduce(value, fn segment, acc -> lookup_segment(acc, segment) end)
  end

  # ── Private impl ───────────────────────────────────────────────────────────

  defp take_impl(value, count) when is_binary(value) do
    String.slice(value, 0, normalize_integer(count, "take"))
  end

  defp take_impl(value, count) do
    value |> enumerable_list() |> Enum.take(normalize_integer(count, "take"))
  end

  defp drop_impl(value, count) when is_binary(value) do
    String.slice(value, normalize_integer(count, "drop")..-1//1)
  end

  defp drop_impl(value, count) do
    value |> enumerable_list() |> Enum.drop(normalize_integer(count, "drop"))
  end

  defp slice_impl(value, start, length) when is_binary(value) do
    String.slice(value, normalize_integer(start, "slice"), normalize_integer(length, "slice"))
  end

  defp slice_impl(value, start, length) do
    value
    |> enumerable_list()
    |> Enum.slice(normalize_integer(start, "slice"), normalize_integer(length, "slice"))
  end

  defp first_impl(value) when is_binary(value), do: String.first(value)
  defp first_impl(value), do: value |> enumerable_list() |> List.first()

  defp reverse_impl(value) when is_binary(value) do
    value |> String.graphemes() |> Enum.reverse() |> Enum.join()
  end

  defp reverse_impl(value), do: value |> enumerable_list() |> Enum.reverse()

  defp selector_segments(selector) when is_binary(selector),
    do: String.split(selector, ".", trim: true)

  defp selector_segments(selector) when is_atom(selector), do: [Atom.to_string(selector)]
  defp selector_segments(selector) when is_integer(selector), do: [selector]

  defp lookup_segment(value, segment) when is_map(value) and is_integer(segment),
    do: Map.get(value, segment)

  defp lookup_segment(value, segment) when is_map(value) do
    case Map.fetch(value, segment) do
      {:ok, item} ->
        item

      :error ->
        case Enum.find(value, fn
               {key, _item} when is_atom(key) -> Atom.to_string(key) == segment
               _entry -> false
             end) do
          {_, item} -> item
          nil -> nil
        end
    end
  end

  defp lookup_segment(value, segment) when is_list(value) and is_integer(segment),
    do: Enum.at(value, segment)

  defp lookup_segment(value, segment) when is_list(value) and is_binary(segment) do
    case Integer.parse(segment) do
      {index, ""} -> Enum.at(value, index)
      _ -> nil
    end
  end

  defp lookup_segment(_value, _segment), do: nil
end
