# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Transformers.Strings do
  @moduledoc """
  String transformers: case conversion, trimming, truncation, replacement, and pattern matching.

  Load this capability group when templates need to perform text transformations:
  - Case conversion: `trim`, `upcase`, `downcase`, `capitalize`
  - Text shaping: `truncate`, `replace`, `take`, `drop`, `slice`, `first`, `reverse`
  - Pattern matching: `starts_with`, `ends_with`

  ## Example

      Stem.Unsafe.eval_string(
        template,
        assigns: data,
        transformers: Stem.Transformers.Strings.all()
      )
  """

  alias Stem.Transformers.Shared

  @type transformer :: ([term()], map() -> term())

  @doc "Return all string transformers as a map keyed by name."
  @spec all() :: %{String.t() => transformer()}
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
      "take" => &Shared.take/2,
      "drop" => &Shared.drop/2,
      "slice" => &Shared.slice/2,
      "first" => &Shared.first/2,
      "reverse" => &Shared.reverse/2
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
    count = Shared.normalize_integer(count, "truncate")

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
end
