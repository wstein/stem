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

  alias Stem.Transformers.Shared

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
      "take" => &Shared.take/2,
      "drop" => &Shared.drop/2,
      "slice" => &Shared.slice/2,
      "first" => &Shared.first/2,
      "reverse" => &Shared.reverse/2
    }
  end

  # Helpers

  defp map([collection, selector], _ctx) do
    Enum.map(Shared.enumerable_list(collection), &Shared.select_value(&1, selector))
  end

  defp map(args, _ctx) do
    raise ArgumentError, "map expects 2 arguments, got: #{length(args)}"
  end

  defp filter([collection], _ctx) do
    Enum.filter(Shared.enumerable_list(collection), &Shared.truthy?/1)
  end

  defp filter([collection, selector], _ctx) do
    Enum.filter(Shared.enumerable_list(collection), &Shared.truthy?(Shared.select_value(&1, selector)))
  end

  defp filter(args, _ctx) do
    raise ArgumentError, "filter expects 1 or 2 arguments, got: #{length(args)}"
  end

  defp sort([collection], _ctx) do
    Enum.sort(Shared.enumerable_list(collection))
  end

  defp sort(args, _ctx) do
    raise ArgumentError, "sort expects 1 argument, got: #{length(args)}"
  end

  defp sort_by([collection, selector], _ctx) do
    Enum.sort_by(Shared.enumerable_list(collection), &Shared.select_value(&1, selector))
  end

  defp sort_by(args, _ctx) do
    raise ArgumentError, "sort_by expects 2 arguments, got: #{length(args)}"
  end

  defp group_by([collection, selector], _ctx) do
    Enum.group_by(Shared.enumerable_list(collection), &Shared.select_value(&1, selector))
  end

  defp group_by(args, _ctx) do
    raise ArgumentError, "group_by expects 2 arguments, got: #{length(args)}"
  end

  defp compact([collection], _ctx) do
    collection |> Shared.enumerable_list() |> Enum.reject(&is_nil/1)
  end

  defp compact(args, _ctx) do
    raise ArgumentError, "compact expects 1 argument, got: #{length(args)}"
  end

  defp uniq([collection], _ctx) do
    collection |> Shared.enumerable_list() |> Enum.uniq()
  end

  defp uniq(args, _ctx) do
    raise ArgumentError, "uniq expects 1 argument, got: #{length(args)}"
  end

  defp flatten([collection], _ctx) do
    collection |> Shared.enumerable_list() |> List.flatten()
  end

  defp flatten(args, _ctx) do
    raise ArgumentError, "flatten expects 1 argument, got: #{length(args)}"
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
