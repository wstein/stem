# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Builtins do
  @moduledoc false

  @spec each_entries(term()) :: list()
  def each_entries(nil), do: []
  def each_entries(false), do: []
  def each_entries(0), do: []
  def each_entries(""), do: []
  def each_entries([]), do: []

  def each_entries(value) when is_map(value) do
    if map_size(value) == 0 do
      []
    else
      Enum.map(value, fn {key, current} -> {current, key} end)
    end
  end

  def each_entries(value) when is_list(value) do
    Enum.map(value, &{&1, nil})
  end

  def each_entries(value), do: List.wrap(value) |> Enum.map(&{&1, nil})

  @spec each(list(), (term(), non_neg_integer() -> term()), (-> term()) | nil) :: term()
  def each(entries, do_fun, else_fun \\ nil)
      when is_list(entries) and is_function(do_fun, 2) do
    case entries do
      [] when is_function(else_fun, 0) ->
        else_fun.()

      [] ->
        ""

      _ ->
        entries
        |> Enum.with_index()
        |> Enum.map_join("", fn {entry, stem_index} ->
          do_fun.(entry, stem_index)
        end)
    end
  end
end
