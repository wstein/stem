# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Helpers.Strings do
  @moduledoc """
  String manipulation helpers: case conversion, trimming, truncation, replacement, and pattern matching.

  Load this capability group when templates need to perform text transformations:
  - Case conversion: `trim`, `upcase`, `downcase`, `capitalize`
  - Text shaping: `truncate`, `replace`, `take`, `drop`, `slice`, `first`, `reverse`
  - Pattern matching: `starts_with`, `ends_with`

  ## Example

      Stem.Unsafe.eval_string(
        template,
        assigns: data,
        helper_groups: [Stem.Helpers.Strings]
      )
  """

  @type helper :: ([term()], map() -> term())

  @doc "Return all string helpers as a map keyed by name."
  @spec all() :: %{String.t() => helper()}
  def all do
    %{
      "trim" => &trim/2,
      "upcase" => &upcase/2,
      "downcase" => &downcase/2,
      "capitalize" => &capitalize/2,
      "truncate" => &truncate/2,
      "replace" => &replace/2,
      "starts_with" => &starts_with/2,
      "ends_with" => &ends_with/2,
      "take" => &take/2,
      "drop" => &drop/2,
      "slice" => &slice/2,
      "first" => &first/2,
      "reverse" => &reverse/2
    }
  end

  # Helpers

  defp trim([value], _ctx) do
    value |> to_string() |> String.trim()
  end

  defp trim(args, _ctx) do
    raise ArgumentError, "trim expects 1 argument, got: #{length(args)}"
  end

  defp upcase([value], _ctx) do
    value |> to_string() |> String.upcase()
  end

  defp upcase(args, _ctx) do
    raise ArgumentError, "upcase expects 1 argument, got: #{length(args)}"
  end

  defp downcase([value], _ctx) do
    value |> to_string() |> String.downcase()
  end

  defp downcase(args, _ctx) do
    raise ArgumentError, "downcase expects 1 argument, got: #{length(args)}"
  end

  defp capitalize([value], _ctx) do
    value |> to_string() |> String.capitalize()
  end

  defp capitalize(args, _ctx) do
    raise ArgumentError, "capitalize expects 1 argument, got: #{length(args)}"
  end

  defp truncate([value, count], _ctx) do
    truncate_impl(value, count, "")
  end

  defp truncate([value, count, omission], _ctx) do
    truncate_impl(value, count, to_string(omission))
  end

  defp truncate(args, _ctx) do
    raise ArgumentError, "truncate expects 2 or 3 arguments, got: #{length(args)}"
  end

  defp truncate_impl(value, count, omission) do
    value = to_string(value)
    count = normalize_integer(count, "truncate")

    cond do
      String.length(value) <= count ->
        value

      omission == "" ->
        String.slice(value, 0, count)

      true ->
        keep = max(count - String.length(omission), 0)
        String.slice(value, 0, keep) <> omission
    end
  end

  defp replace([value, pattern, replacement], _ctx) do
    String.replace(to_string(value), to_string(pattern), to_string(replacement))
  end

  defp replace(args, _ctx) do
    raise ArgumentError, "replace expects 3 arguments, got: #{length(args)}"
  end

  defp starts_with([value, prefix], _ctx) do
    String.starts_with?(to_string(value), to_string(prefix))
  end

  defp starts_with(args, _ctx) do
    raise ArgumentError, "starts_with expects 2 arguments, got: #{length(args)}"
  end

  defp ends_with([value, suffix], _ctx) do
    String.ends_with?(to_string(value), to_string(suffix))
  end

  defp ends_with(args, _ctx) do
    raise ArgumentError, "ends_with expects 2 arguments, got: #{length(args)}"
  end

  defp take([value, count], _ctx) do
    take_impl(value, count)
  end

  defp take(args, _ctx) do
    raise ArgumentError, "take expects 2 arguments, got: #{length(args)}"
  end

  defp take_impl(value, count) when is_binary(value) do
    String.slice(value, 0, normalize_integer(count, "take"))
  end

  defp take_impl(value, count) do
    value |> enumerable_list() |> Enum.take(normalize_integer(count, "take"))
  end

  defp drop([value, count], _ctx) do
    drop_impl(value, count)
  end

  defp drop(args, _ctx) do
    raise ArgumentError, "drop expects 2 arguments, got: #{length(args)}"
  end

  defp drop_impl(value, count) when is_binary(value) do
    String.slice(value, normalize_integer(count, "drop")..-1//1)
  end

  defp drop_impl(value, count) do
    value |> enumerable_list() |> Enum.drop(normalize_integer(count, "drop"))
  end

  defp slice([value, start, length], _ctx) do
    slice_impl(value, start, length)
  end

  defp slice(args, _ctx) do
    raise ArgumentError, "slice expects 3 arguments, got: #{length(args)}"
  end

  defp slice_impl(value, start, length) when is_binary(value) do
    String.slice(value, normalize_integer(start, "slice"), normalize_integer(length, "slice"))
  end

  defp slice_impl(value, start, length) do
    value
    |> enumerable_list()
    |> Enum.slice(normalize_integer(start, "slice"), normalize_integer(length, "slice"))
  end

  defp first([value], _ctx) do
    first_impl(value)
  end

  defp first(args, _ctx) do
    raise ArgumentError, "first expects 1 argument, got: #{length(args)}"
  end

  defp first_impl(value) when is_binary(value), do: String.first(value)
  defp first_impl(value), do: value |> enumerable_list() |> List.first()

  defp reverse([value], _ctx) do
    reverse_impl(value)
  end

  defp reverse(args, _ctx) do
    raise ArgumentError, "reverse expects 1 argument, got: #{length(args)}"
  end

  defp reverse_impl(value) when is_binary(value) do
    value |> String.graphemes() |> Enum.reverse() |> Enum.join()
  end

  defp reverse_impl(value) do
    value |> enumerable_list() |> Enum.reverse()
  end

  # Helpers

  defp enumerable_list(value) when is_list(value), do: value
  defp enumerable_list(value) when is_map(value), do: Map.values(value)
  defp enumerable_list(nil), do: []
  defp enumerable_list(value), do: List.wrap(value)

  defp normalize_integer(value, _helper) when is_integer(value), do: value

  defp normalize_integer(value, helper) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> raise ArgumentError, "#{helper} expects integer arguments"
    end
  end

  defp normalize_integer(value, helper) do
    raise ArgumentError, "#{helper} expects integer arguments, got: #{inspect(value)}"
  end
end
