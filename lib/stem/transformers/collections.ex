# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Transformers.Collections do
  @moduledoc """
  Collection transformers: filtering, sorting, grouping, slicing, and transformation.

  Load this capability group when templates perform complex data operations:
  - Filtering and selection: `filter`, `compact`, `uniq`
  - Sorting: `sort`, `sort_by`
  - Grouping: `group_by`
  - Transformation: `map`
  - Slicing: `take`, `drop`, `slice`, `first`
  - Flattening: `flatten`, `reverse`

  **Security Note:** These transformers enable powerful data transformations. In an SSTI attack,
  an attacker with access to this group could chain operations to extract internal states.
  Only load this group when the template source is trusted.

  ## Example

      Stem.Unsafe.eval_string(
        template,
        assigns: data,
        transformers: Stem.Transformers.Collections.all()
      )
  """

  @type transformer :: ([term()], map() -> term())

  @doc "Return all collection transformers as a map keyed by name."
  @spec all() :: %{String.t() => transformer()}
  def all do
    emit_capability_loaded_event()

    %{
      "map" => &map/2,
      "filter" => &filter/2,
      "sort" => &sort/2,
      "sort_by" => &sort_by/2,
      "group_by" => &group_by/2,
      "compact" => &compact/2,
      "uniq" => &uniq/2,
      "flatten" => &flatten/2,
      "take" => &take/2,
      "drop" => &drop/2,
      "slice" => &slice/2,
      "first" => &first/2,
      "reverse" => &reverse/2
    }
  end

  # Helpers

  defp map([collection, selector], _ctx) do
    Enum.map(enumerable_list(collection), &select_value(&1, selector))
  end

  defp map(args, _ctx) do
    raise ArgumentError, "map expects 2 arguments, got: #{length(args)}"
  end

  defp filter([collection], _ctx) do
    Enum.filter(enumerable_list(collection), &truthy?/1)
  end

  defp filter([collection, selector], _ctx) do
    Enum.filter(enumerable_list(collection), &truthy?(select_value(&1, selector)))
  end

  defp filter(args, _ctx) do
    raise ArgumentError, "filter expects 1 or 2 arguments, got: #{length(args)}"
  end

  defp sort([collection], _ctx) do
    Enum.sort(enumerable_list(collection))
  end

  defp sort(args, _ctx) do
    raise ArgumentError, "sort expects 1 argument, got: #{length(args)}"
  end

  defp sort_by([collection, selector], _ctx) do
    Enum.sort_by(enumerable_list(collection), &select_value(&1, selector))
  end

  defp sort_by(args, _ctx) do
    raise ArgumentError, "sort_by expects 2 arguments, got: #{length(args)}"
  end

  defp group_by([collection, selector], _ctx) do
    Enum.group_by(enumerable_list(collection), &select_value(&1, selector))
  end

  defp group_by(args, _ctx) do
    raise ArgumentError, "group_by expects 2 arguments, got: #{length(args)}"
  end

  defp compact([collection], _ctx) do
    collection |> enumerable_list() |> Enum.reject(&is_nil/1)
  end

  defp compact(args, _ctx) do
    raise ArgumentError, "compact expects 1 argument, got: #{length(args)}"
  end

  defp uniq([collection], _ctx) do
    collection |> enumerable_list() |> Enum.uniq()
  end

  defp uniq(args, _ctx) do
    raise ArgumentError, "uniq expects 1 argument, got: #{length(args)}"
  end

  defp flatten([collection], _ctx) do
    collection |> enumerable_list() |> List.flatten()
  end

  defp flatten(args, _ctx) do
    raise ArgumentError, "flatten expects 1 argument, got: #{length(args)}"
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

  defp truthy?(value), do: value not in [false, nil, 0, "", [], %{}]

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

  # ── Telemetry / audit event ────────────────────────────────────────────────

  # Emits a [:stem, :capability_group, :loaded] telemetry event when the
  # Collections group is loaded dynamically. This event can be used to audit
  # which processes are using the most powerful transformer set.
  #
  # If the :telemetry application is not available (it is an optional dep),
  # falls back to a Logger warning so no crash occurs.
  defp emit_capability_loaded_event do
    key = {__MODULE__, :capability_loaded}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      metadata = %{group: __MODULE__, caller: Process.info(self(), :current_stacktrace)}

      if Code.ensure_loaded?(:telemetry) do
        apply(:telemetry, :execute, [[:stem, :capability_group, :loaded], %{count: 1}, metadata])
      else
        require Logger

        Logger.warning(
          "[Stem] #{inspect(__MODULE__)} capability group loaded. " <>
            "This group contains powerful data-manipulation transformers " <>
            "(map, group_by, sort_by, filter, etc.). " <>
            "Ensure the template source is fully trusted."
        )
      end
    end
  end
end
