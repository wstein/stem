# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Contract do
  @moduledoc """
  Compile-time assign contracts for Stem templates.

  Contracts act like **ST4 Group Interfaces**: they declare which assigns a
  template expects, whether they are required or optional, and what types are
  accepted. The runtime raises an `ArgumentError` when required assigns are
  absent or when a typed assign receives a value of the wrong type.

  ## Declaration

  Pass a `contract:` keyword list to `Stem.function_from_string/5`,
  `Stem.function_from_file/5`, `Stem.DSL.deftemplate/3`, or
  `Stem.DSL.deftemplate_file/3`:

      # simple presence-only
      contract: [required: [:title, :body], optional: [:subtitle]]

      # with type annotations (any | :string | :integer | :float | :number |
      #                         :boolean | :atom | :list | :map | :binary)
      contract: [
        required: [title: :string, count: :integer],
        optional: [subtitle: :string, active: :boolean]
      ]

  ## Referencing a shared contract

  If a module exports `def contract/0` returning a keyword list in the format
  above, you can reference it by module atom:

      contract: MyApp.Contracts.ArticleView

  This is equivalent to passing `MyApp.Contracts.ArticleView.contract()` inline
  and gives you a single place to define the interface across many templates.

  ## Types

  | Atom         | Elixir guard                          |
  |------------- |-------------------------------------- |
  | `:string`    | `is_binary/1`                         |
  | `:integer`   | `is_integer/1`                        |
  | `:float`     | `is_float/1`                          |
  | `:number`    | `is_number/1`                         |
  | `:boolean`   | `is_boolean/1`                        |
  | `:atom`      | `is_atom/1`                           |
  | `:list`      | `is_list/1`                           |
  | `:map`       | `is_map/1`                            |
  | `:binary`    | `is_binary/1`  (alias for `:string`)  |
  | `:any`       | always passes                         |

  Providing a type for an atom that is not in the list above raises an
  `ArgumentError` at *template compile time*, not at render time.
  """

  @valid_types ~w(string integer float number boolean atom list map binary any)a

  # ── Normalisation ──────────────────────────────────────────────────────────

  @doc """
  Normalises a contract declaration into a canonical map.

  Accepts:
  - `nil` — no contract, returns `nil`
  - a keyword list like `[required: [...], optional: [...]]`
  - a module atom that exports `contract/0` returning such a keyword list
  """
  @spec normalize(keyword() | module() | nil) ::
          %{required: [{atom(), atom()}], optional: [{atom(), atom()}]} | nil
  def normalize(nil), do: nil

  def normalize(module) when is_atom(module) do
    if function_exported?(module, :contract, 0) do
      normalize(module.contract())
    else
      raise ArgumentError,
            "Stem contract: #{inspect(module)} must export contract/0"
    end
  end

  def normalize(contract) when is_list(contract) do
    %{
      required: normalize_entries(Keyword.get(contract, :required, [])),
      optional: normalize_entries(Keyword.get(contract, :optional, []))
    }
  end

  # ── Runtime validation ─────────────────────────────────────────────────────

  @doc """
  Validates `assigns` against a normalised contract.

  Raises `ArgumentError` if:
  - a required assign is missing
  - a required or optional assign with a type annotation is present but has
    the wrong type
  """
  @spec validate!(keyword() | map(), %{required: list(), optional: list()}) :: :ok
  def validate!(assigns, %{required: required, optional: optional}) do
    keys = assigns_keys(assigns)

    missing = Enum.reject(required, fn {key, _type} -> MapSet.member?(keys, key) end)

    if missing != [] do
      names = missing |> Enum.map(fn {k, _} -> to_string(k) end) |> Enum.join(", ")

      raise ArgumentError,
            "missing required assigns for Stem contract: #{names}"
    end

    check_types!(assigns, required ++ optional)
  end

  # ── Compile-time contract type check ──────────────────────────────────────

  @doc """
  Validates that all type annotations in a raw (un-normalised) contract declaration
  are known type atoms. Raises `ArgumentError` at compile time if not.
  """
  @spec validate_types!(keyword()) :: :ok
  def validate_types!(nil), do: :ok

  def validate_types!(module) when is_atom(module) do
    if function_exported?(module, :contract, 0),
      do: validate_types!(module.contract()),
      else: :ok
  end

  def validate_types!(contract) when is_list(contract) do
    all_entries =
      Keyword.get(contract, :required, []) ++ Keyword.get(contract, :optional, [])

    Enum.each(all_entries, fn
      {_key, type} when is_atom(type) ->
        unless type in @valid_types do
          raise ArgumentError,
                "Stem contract: unknown type #{inspect(type)}. " <>
                  "Valid types: #{@valid_types |> Enum.map(&inspect/1) |> Enum.join(", ")}"
        end

      key when is_atom(key) ->
        :ok

      other ->
        raise ArgumentError,
              "Stem contract: expected atom or {atom, type} entry, got: #{inspect(other)}"
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp normalize_entries(entries) do
    Enum.map(entries, fn
      {key, type} when is_atom(key) and is_atom(type) -> {normalize_key(key), type}
      {key, type} when is_binary(key) and is_atom(type) -> {String.to_atom(key), type}
      key when is_atom(key) -> {key, :any}
      key when is_binary(key) -> {String.to_atom(key), :any}
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)

  defp check_types!(assigns, entries) do
    Enum.each(entries, fn {key, type} ->
      case fetch_assign(assigns, key) do
        {:ok, value} -> check_type!(key, value, type)
        :error -> :ok
      end
    end)
  end

  defp fetch_assign(assigns, key) when is_list(assigns) do
    case Keyword.fetch(assigns, key) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  end

  defp fetch_assign(assigns, key) when is_map(assigns) do
    case Map.fetch(assigns, key) do
      {:ok, _} = ok -> ok
      :error -> Map.fetch(assigns, Atom.to_string(key))
    end
  end

  defp check_type!(_key, _value, :any), do: :ok
  defp check_type!(_key, value, :string) when is_binary(value), do: :ok
  defp check_type!(_key, value, :binary) when is_binary(value), do: :ok
  defp check_type!(_key, value, :integer) when is_integer(value), do: :ok
  defp check_type!(_key, value, :float) when is_float(value), do: :ok
  defp check_type!(_key, value, :number) when is_number(value), do: :ok
  defp check_type!(_key, value, :boolean) when is_boolean(value), do: :ok
  defp check_type!(_key, value, :atom) when is_atom(value), do: :ok
  defp check_type!(_key, value, :list) when is_list(value), do: :ok
  defp check_type!(_key, value, :map) when is_map(value), do: :ok

  defp check_type!(key, value, type) do
    raise ArgumentError,
          "Stem contract type mismatch: assign #{inspect(key)} must be #{type}, " <>
            "got #{inspect(value)}"
  end

  defp assigns_keys(assigns) when is_list(assigns), do: assigns |> Keyword.keys() |> MapSet.new()

  defp assigns_keys(assigns) when is_map(assigns) do
    assigns
    |> Map.keys()
    |> Enum.map(&normalize_key/1)
    |> MapSet.new()
  end
end
