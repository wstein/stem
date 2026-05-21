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

  defp built_in(_), do: nil

  defp lookup(collection, key) when is_map(collection) do
    Map.get(collection, key) || Map.get(collection, to_string(key))
  end

  defp lookup(collection, key) when is_list(collection) and is_integer(key) do
    Enum.at(collection, key)
  end

  defp lookup(_collection, _key), do: nil
end
