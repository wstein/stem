# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Runtime do
  @moduledoc false

  # Runtime support invoked by compiled Stem templates.

  @doc """
  Fetches an assign by key.

  Missing assigns return `nil`. When `warn?` is true, a missing assign also
  prints a warning naming the available assigns.
  """
  @spec fetch_assign!(Access.t(), Access.key(), boolean()) :: term() | nil
  def fetch_assign!(assigns, key, warn?) do
    case Access.fetch(assigns, key) do
      {:ok, value} ->
        value

      :error ->
        if warn? do
          keys = Enum.map(assigns, &elem(&1, 0))

          IO.warn(
            "assign @#{key} not available in Stem template. " <>
              "Please ensure all assigns are given as options. " <>
              "Available assigns: #{inspect(keys)}"
          )
        end

        nil
    end
  end

  @doc """
  Builds the assign scope for a partial invoked with arguments.

  `base` is the context argument value (or the caller's current data context
  when no context argument is given). It is coerced to a map so the partial body
  can read it by key. `hash` carries the partial's hash arguments and is merged
  on top, so hash keys win over matching context keys.
  """
  @spec partial_scope(term(), map()) :: map()
  def partial_scope(base, hash) when is_map(hash) do
    base
    |> to_scope_map()
    |> Map.merge(hash)
  end

  defp to_scope_map(map) when is_map(map), do: map

  defp to_scope_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Map.new(list), else: %{}
  end

  defp to_scope_map(_other), do: %{}

  @doc """
  Resolves one path segment against a value, tolerantly.

  A map is keyed by the segment (atom keys preferred, with a string-key
  fallback for JSON-shaped data); a list is indexed by an integer segment.
  Anything else — a missing key, an out-of-range index, or a scalar — yields
  `nil` so templates render empty instead of raising.
  """
  @spec get_field(term(), atom() | binary() | integer()) :: term()
  def get_field(value, key) when is_map(value) and is_atom(key) do
    case Map.fetch(value, key) do
      {:ok, found} -> found
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

  def get_field(value, key) when is_map(value), do: Map.get(value, key)
  def get_field(value, index) when is_list(value) and is_integer(index), do: Enum.at(value, index)

  def get_field(value, key) when is_list(value) and is_atom(key) do
    if Keyword.keyword?(value), do: Keyword.get(value, key)
  end

  def get_field(_value, _key), do: nil

  @doc """
  Checks if a value is truthy according to Handlebars semantics.

  Falsey values: false, nil, 0, "", [], %{}
  All other values are truthy.
  """
  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: value not in [false, nil, 0, "", [], %{}]

  @spec truthy?(term(), keyword()) :: boolean()
  def truthy?(value, opts) when is_list(opts) do
    value
    |> warn_on_falsy_coercion(opts)
    |> truthy?()
  end

  @spec warn_on_falsy_coercion(term(), keyword()) :: term()
  def warn_on_falsy_coercion(value, opts \\ []) when is_list(opts) do
    if Keyword.get(opts, :warn_on_falsy_coercion, false) and coerced_falsey?(value) do
      file = Keyword.get(opts, :file, "nofile")
      line = Keyword.get(opts, :line, 1)
      context = Keyword.get(opts, :context, :condition)

      IO.warn(
        "#{file}:#{line}: #{context} coerces #{inspect(value)} to falsy under Stem truthiness"
      )
    end

    value
  end

  defp coerced_falsey?(0), do: true
  defp coerced_falsey?(""), do: true
  defp coerced_falsey?([]), do: true
  defp coerced_falsey?(value) when is_map(value), do: map_size(value) == 0
  defp coerced_falsey?(_value), do: false
end
