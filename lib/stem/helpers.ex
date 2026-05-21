# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Helpers do
  @moduledoc false

  @registry_key {__MODULE__, :registry}
  @type helper :: ([term()], map() -> term())

  @spec register(atom() | String.t(), helper()) :: :ok
  def register(name, fun) when is_function(fun, 2) do
    key = normalize_name(name)
    registry = registry() |> Map.put(key, fun)
    :persistent_term.put(@registry_key, registry)
    :ok
  end

  @spec unregister(atom() | String.t()) :: :ok
  def unregister(name) do
    key = normalize_name(name)
    registry = registry() |> Map.delete(key)
    :persistent_term.put(@registry_key, registry)
    :ok
  end

  @spec clear() :: :ok
  def clear do
    :persistent_term.put(@registry_key, %{})
    :ok
  end

  @spec invoke(atom(), [term()], keyword()) :: term()
  def invoke(name, args, binding_env)
      when is_atom(name) and is_list(args) and is_list(binding_env) do
    helper_key = normalize_name(name)
    assigns = binding_env |> Keyword.get(:assigns, []) |> Enum.into(%{})
    this = Keyword.get(binding_env, :this)
    local_helpers = binding_env |> Keyword.get(:helpers, []) |> normalize_helpers()

    helper =
      Map.get(local_helpers, helper_key) ||
        Map.get(registry(), helper_key) ||
        built_in(helper_key) ||
        raise Stem.SyntaxError, "unknown helper '#{helper_key}'"

    helper.(args, %{assigns: assigns, this: this, binding: binding_env})
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name

  defp normalize_helpers(helpers) when is_map(helpers) do
    Map.new(helpers, fn {name, fun} -> {normalize_name(name), fun} end)
  end

  defp normalize_helpers(helpers) when is_list(helpers) do
    helpers |> Enum.into(%{}) |> normalize_helpers()
  end

  defp registry do
    :persistent_term.get(@registry_key, %{})
  end

  defp built_in("lookup") do
    fn [collection, key], _ctx ->
      lookup(collection, key)
    end
  end

  defp built_in("log") do
    fn args, _ctx ->
      rendered_args =
        Enum.map(args, fn
          {key, value} when is_atom(key) -> "#{key}=#{to_string(value)}"
          value -> to_string(value)
        end)

      IO.puts(:stderr, Enum.join(rendered_args, " "))
      ""
    end
  end

  defp built_in("html") do
    fn [value], _ctx ->
      Stem.Helpers.Sanitize.html(value)
    end
  end

  defp built_in("default") do
    fn
      [value, fallback], _ctx -> if(present?(value), do: value, else: fallback)
      args, _ctx -> raise ArgumentError, "default expects 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("join") do
    fn
      [collection], _ctx -> join(collection, "")
      [collection, separator], _ctx -> join(collection, to_string(separator))
      args, _ctx -> raise ArgumentError, "join expects 1 or 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("inspect") do
    fn
      [value], _ctx -> Kernel.inspect(value)
      args, _ctx -> raise ArgumentError, "inspect expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("json") do
    fn
      [value], _ctx -> JSON.encode!(value)
      args, _ctx -> raise ArgumentError, "json expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("escape_json") do
    fn
      [value], _ctx -> escape_json(value)
      args, _ctx -> raise ArgumentError, "escape_json expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("trim") do
    fn
      [value], _ctx -> value |> to_string() |> String.trim()
      args, _ctx -> raise ArgumentError, "trim expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("upcase") do
    fn
      [value], _ctx -> value |> to_string() |> String.upcase()
      args, _ctx -> raise ArgumentError, "upcase expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("downcase") do
    fn
      [value], _ctx -> value |> to_string() |> String.downcase()
      args, _ctx -> raise ArgumentError, "downcase expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("capitalize") do
    fn
      [value], _ctx -> value |> to_string() |> String.capitalize()
      args, _ctx -> raise ArgumentError, "capitalize expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("truncate") do
    fn
      [value, count], _ctx -> truncate(value, count, "")
      [value, count, omission], _ctx -> truncate(value, count, to_string(omission))
      args, _ctx -> raise ArgumentError, "truncate expects 2 or 3 arguments, got: #{length(args)}"
    end
  end

  defp built_in("replace") do
    fn
      [value, pattern, replacement], _ctx ->
        String.replace(to_string(value), to_string(pattern), to_string(replacement))

      args, _ctx ->
        raise ArgumentError, "replace expects 3 arguments, got: #{length(args)}"
    end
  end

  defp built_in("starts_with") do
    fn
      [value, prefix], _ctx -> String.starts_with?(to_string(value), to_string(prefix))
      args, _ctx -> raise ArgumentError, "starts_with expects 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("ends_with") do
    fn
      [value, suffix], _ctx -> String.ends_with?(to_string(value), to_string(suffix))
      args, _ctx -> raise ArgumentError, "ends_with expects 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("contains") do
    fn
      [collection, needle], _ctx -> contains?(collection, needle)
      args, _ctx -> raise ArgumentError, "contains expects 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("empty?") do
    fn
      [value], _ctx -> empty?(value)
      args, _ctx -> raise ArgumentError, "empty? expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("present?") do
    fn
      [value], _ctx -> present?(value)
      args, _ctx -> raise ArgumentError, "present? expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("compact") do
    fn
      [collection], _ctx -> collection |> enumerable_list() |> Enum.reject(&is_nil/1)
      args, _ctx -> raise ArgumentError, "compact expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("map") do
    fn
      [collection, selector], _ctx ->
        Enum.map(enumerable_list(collection), &select_value(&1, selector))

      args, _ctx ->
        raise ArgumentError, "map expects 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("filter") do
    fn
      [collection], _ctx ->
        Enum.filter(enumerable_list(collection), &truthy?/1)

      [collection, selector], _ctx ->
        Enum.filter(enumerable_list(collection), &truthy?(select_value(&1, selector)))

      args, _ctx ->
        raise ArgumentError, "filter expects 1 or 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("sort") do
    fn
      [collection], _ctx -> Enum.sort(enumerable_list(collection))
      args, _ctx -> raise ArgumentError, "sort expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("sort_by") do
    fn
      [collection, selector], _ctx ->
        Enum.sort_by(enumerable_list(collection), &select_value(&1, selector))

      args, _ctx ->
        raise ArgumentError, "sort_by expects 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("group_by") do
    fn
      [collection, selector], _ctx ->
        Enum.group_by(enumerable_list(collection), &select_value(&1, selector))

      args, _ctx ->
        raise ArgumentError, "group_by expects 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("take") do
    fn
      [value, count], _ctx -> take(value, count)
      args, _ctx -> raise ArgumentError, "take expects 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("drop") do
    fn
      [value, count], _ctx -> drop(value, count)
      args, _ctx -> raise ArgumentError, "drop expects 2 arguments, got: #{length(args)}"
    end
  end

  defp built_in("slice") do
    fn
      [value, start, length], _ctx -> slice(value, start, length)
      args, _ctx -> raise ArgumentError, "slice expects 3 arguments, got: #{length(args)}"
    end
  end

  defp built_in("first") do
    fn
      [value], _ctx -> first(value)
      args, _ctx -> raise ArgumentError, "first expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("uniq") do
    fn
      [collection], _ctx -> collection |> enumerable_list() |> Enum.uniq()
      args, _ctx -> raise ArgumentError, "uniq expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("flatten") do
    fn
      [collection], _ctx -> collection |> enumerable_list() |> List.flatten()
      args, _ctx -> raise ArgumentError, "flatten expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in("reverse") do
    fn
      [value], _ctx -> reverse(value)
      args, _ctx -> raise ArgumentError, "reverse expects 1 argument, got: #{length(args)}"
    end
  end

  defp built_in(_), do: nil

  defp lookup(collection, key) when is_map(collection) do
    Map.get(collection, key) || Map.get(collection, to_string(key))
  end

  defp lookup(collection, key) when is_list(collection) and is_integer(key) do
    Enum.at(collection, key)
  end

  defp lookup(_collection, _key), do: nil

  defp join(collection, separator) do
    collection
    |> enumerable_list()
    |> Enum.map_join(separator, &to_string/1)
  end

  defp escape_json(value) do
    encoded = JSON.encode!(to_string(value))
    String.slice(encoded, 1, max(byte_size(encoded) - 2, 0))
  end

  defp truncate(value, count, omission) do
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

  defp contains?(collection, needle) when is_binary(collection) do
    String.contains?(collection, to_string(needle))
  end

  defp contains?(collection, needle) when is_map(collection) do
    Map.has_key?(collection, needle) or Map.has_key?(collection, to_string(needle))
  end

  defp contains?(collection, needle) when is_list(collection) do
    Enum.member?(collection, needle)
  end

  defp contains?(_collection, _needle), do: false

  defp empty?(value) when value in [nil, "", []], do: true
  defp empty?(value) when is_map(value), do: map_size(value) == 0
  defp empty?(value) when is_list(value), do: value == []
  defp empty?(value) when is_binary(value), do: value == ""
  defp empty?(_value), do: false

  defp present?(value), do: not empty?(value)
  defp truthy?(value), do: value not in [false, nil]

  defp enumerable_list(value) when is_list(value), do: value
  defp enumerable_list(value) when is_map(value), do: Map.values(value)
  defp enumerable_list(nil), do: []
  defp enumerable_list(value), do: List.wrap(value)

  defp select_value(value, selector) do
    selector
    |> selector_segments()
    |> Enum.reduce(value, fn segment, acc -> lookup_segment(acc, segment) end)
  end

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

  defp take(value, count) when is_binary(value),
    do: String.slice(value, 0, normalize_integer(count, "take"))

  defp take(value, count),
    do: value |> enumerable_list() |> Enum.take(normalize_integer(count, "take"))

  defp drop(value, count) when is_binary(value),
    do: String.slice(value, normalize_integer(count, "drop")..-1//1)

  defp drop(value, count),
    do: value |> enumerable_list() |> Enum.drop(normalize_integer(count, "drop"))

  defp slice(value, start, length) when is_binary(value) do
    String.slice(value, normalize_integer(start, "slice"), normalize_integer(length, "slice"))
  end

  defp slice(value, start, length) do
    value
    |> enumerable_list()
    |> Enum.slice(normalize_integer(start, "slice"), normalize_integer(length, "slice"))
  end

  defp first(value) when is_binary(value), do: String.first(value)
  defp first(value), do: value |> enumerable_list() |> List.first()

  defp reverse(value) when is_binary(value),
    do: value |> String.graphemes() |> Enum.reverse() |> Enum.join()

  defp reverse(value), do: value |> enumerable_list() |> Enum.reverse()

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
