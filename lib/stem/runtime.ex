# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Runtime do
  @moduledoc false

  # Runtime support invoked by compiled Stem templates.

  @doc """
  Resolves a computed getter.

  A zero-arity function value is invoked and its result returned; every other
  value is returned unchanged. This is the ST4-style "computed getter": the
  template reads a property name the backend chose to back with a function and
  cannot pass arguments, so it stays declarative. Getters should be pure.
  """
  @spec resolve(term()) :: term()
  def resolve(value) when is_function(value, 0), do: value.()
  def resolve(value), do: value

  @doc """
  Resolves an assign by key, invoking a computed getter (see `resolve/1`).

  Missing assigns return `nil`. When `warn?` is true, a missing assign also
  prints a warning naming the available assigns.
  """
  @spec fetch_assign!(Access.t(), Access.key(), boolean()) :: term() | nil
  def fetch_assign!(assigns, key, warn?) do
    case Access.fetch(assigns, key) do
      {:ok, value} ->
        resolve(value)

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
  Checks if a value is truthy according to Handlebars semantics.

  Falsey values: false, nil, 0, "", [], %{}
  All other values are truthy.
  """
  @spec is_truthy(term()) :: boolean()
  def is_truthy(value), do: value not in [false, nil, 0, "", [], %{}]

  @spec is_truthy(term(), keyword()) :: boolean()
  def is_truthy(value, opts) when is_list(opts) do
    value
    |> warn_on_falsy_coercion(opts)
    |> is_truthy()
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
