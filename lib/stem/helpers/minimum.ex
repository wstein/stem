# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Helpers.Minimum do
  @moduledoc """
  Secure minimum helpers: essential functions required for XSS protection and basic output.

  These helpers form the default, always-available capability set. They are focused on:
  - Output escaping for XSS prevention (`escape_html`, `escape_json`, `json`)
  - Safe fallback handling (`default`)
  - Basic introspection (`inspect`)
  - Essential collection operations (`lookup`, `join`)
  - Debugging support (`log`)

  This minimal set can be extended by loading additional capability groups via
  `Stem.Helpers.Strings`, `Stem.Helpers.Collections`, and `Stem.Helpers.Predicates`.
  """

  @type helper :: ([term()], map() -> term())

  @doc "Return all minimum helpers as a map keyed by name."
  @spec all() :: %{String.t() => helper()}
  def all do
    %{
      "escape_html" => &escape_html/2,
      "escape_json" => &escape_json/2,
      "json" => &json/2,
      "default" => &default/2,
      "inspect" => &do_helper_inspect/2,
      "lookup" => &lookup/2,
      "join" => &join/2,
      "log" => &log/2
    }
  end

  # Helpers

  defp lookup([collection, key], _ctx) do
    lookup_impl(collection, key)
  end

  defp lookup(args, _ctx) do
    raise ArgumentError, "lookup expects 2 arguments, got: #{length(args)}"
  end

  defp lookup_impl(collection, key) when is_map(collection) do
    Map.get(collection, key) || Map.get(collection, to_string(key))
  end

  defp lookup_impl(collection, key) when is_list(collection) and is_integer(key) do
    Enum.at(collection, key)
  end

  defp lookup_impl(_collection, _key), do: nil

  defp log(args, _ctx) do
    rendered_args =
      Enum.map(args, fn
        {key, value} when is_atom(key) -> "#{key}=#{to_string(value)}"
        value -> to_string(value)
      end)

    IO.puts(:stderr, Enum.join(rendered_args, " "))
    ""
  end

  defp escape_html([value], _ctx) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp escape_html(args, _ctx) do
    raise ArgumentError, "escape_html expects 1 argument, got: #{length(args)}"
  end

  defp default([value, fallback], _ctx) do
    if present?(value), do: value, else: fallback
  end

  defp default(args, _ctx) do
    raise ArgumentError, "default expects 2 arguments, got: #{length(args)}"
  end

  defp join([collection], _ctx) do
    join_impl(collection, "")
  end

  defp join([collection, separator], _ctx) do
    join_impl(collection, to_string(separator))
  end

  defp join(args, _ctx) do
    raise ArgumentError, "join expects 1 or 2 arguments, got: #{length(args)}"
  end

  defp join_impl(collection, separator) do
    collection
    |> enumerable_list()
    |> Enum.map_join(separator, &to_string/1)
  end

  defp do_helper_inspect([value], _ctx) do
    Kernel.inspect(value)
  end

  defp do_helper_inspect(args, _ctx) do
    raise ArgumentError, "inspect expects 1 argument, got: #{length(args)}"
  end

  defp json([value], _ctx) do
    JSON.encode!(value)
  end

  defp json(args, _ctx) do
    raise ArgumentError, "json expects 1 argument, got: #{length(args)}"
  end

  defp escape_json([value], _ctx) do
    escape_json_impl(value)
  end

  defp escape_json(args, _ctx) do
    raise ArgumentError, "escape_json expects 1 argument, got: #{length(args)}"
  end

  defp escape_json_impl(value) do
    encoded = JSON.encode!(to_string(value))
    String.slice(encoded, 1, max(byte_size(encoded) - 2, 0))
  end

  # Helpers

  defp present?(value), do: not empty?(value)

  defp empty?(value) when value in [nil, "", []], do: true
  defp empty?(value) when is_map(value), do: map_size(value) == 0
  defp empty?(value) when is_list(value), do: value == []
  defp empty?(value) when is_binary(value), do: value == ""
  defp empty?(_value), do: false

  defp enumerable_list(value) when is_list(value), do: value
  defp enumerable_list(value) when is_map(value), do: Map.values(value)
  defp enumerable_list(nil), do: []
  defp enumerable_list(value), do: List.wrap(value)
end
