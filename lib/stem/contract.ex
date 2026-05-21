# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Contract do
  @moduledoc false

  @spec normalize(keyword() | nil) :: %{required: [atom()], optional: [atom()]} | nil
  def normalize(nil), do: nil

  def normalize(contract) when is_list(contract) do
    %{
      required: normalize_keys(Keyword.get(contract, :required, [])),
      optional: normalize_keys(Keyword.get(contract, :optional, []))
    }
  end

  @spec validate!(keyword() | map(), %{required: [atom()], optional: [atom()]}) :: :ok
  def validate!(assigns, %{required: required}) do
    keys = assigns_keys(assigns)
    missing = Enum.reject(required, &MapSet.member?(keys, &1))

    if missing != [] do
      raise ArgumentError,
            "missing required assigns for Stem contract: #{Enum.join(Enum.map(missing, &to_string/1), ", ")}"
    end

    :ok
  end

  defp normalize_keys(keys) do
    Enum.map(keys, fn
      key when is_atom(key) -> key
      key when is_binary(key) -> String.to_atom(key)
    end)
  end

  defp assigns_keys(assigns) when is_list(assigns), do: assigns |> Keyword.keys() |> MapSet.new()

  defp assigns_keys(assigns) when is_map(assigns) do
    assigns
    |> Map.keys()
    |> Enum.map(&normalize_map_key/1)
    |> MapSet.new()
  end

  defp normalize_map_key(key) when is_atom(key), do: key
  defp normalize_map_key(key) when is_binary(key), do: String.to_atom(key)
end
