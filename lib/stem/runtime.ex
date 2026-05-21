# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Runtime do
  @moduledoc false

  # Runtime support invoked by compiled Stem templates.

  @doc """
  Resolves an assign by key.

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
end
