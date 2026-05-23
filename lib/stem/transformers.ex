# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Transformers do
  @moduledoc false

  # Runtime transformer dispatcher. `invoke/3` resolves a transformer name, in
  # order, against:
  #
  #   1. the caller-supplied `transformers:` binding (a capability group map
  #      and/or custom functions),
  #   2. the global registry populated via `register/2`,
  #   3. the default capability set (`default_transformers/0`).
  #
  # The default set is the single source of truth for which transformers are
  # available when nothing is loaded explicitly — see `default_transformers/0`.

  @registry_key {__MODULE__, :registry}
  @type transformer :: ([term()], map() -> term())

  @spec register(atom() | String.t(), transformer()) :: :ok
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
    transformers = normalize_transformers(Keyword.get(binding_env, :transformers, %{}))

    helper =
      Map.get(transformers, helper_key) ||
        Map.get(registry(), helper_key) ||
        Map.get(default_transformers(), helper_key) ||
        raise Stem.SyntaxError, unknown_transformer_message(helper_key)

    helper.(args, %{assigns: assigns, this: this, binding: binding_env})
  end

  # Secure-by-default capability floor: with no explicit `transformers:` binding
  # and no globally registered transformer, only the Minimum group is callable.
  # The Strings, Collections, and Predicates groups must be loaded explicitly
  # (via the `transformers:` binding, the `--transformers` CLI flag, or config)
  # so that a template can never reach a more powerful transformer than the
  # caller has opted into. Minimum remains the floor even when other groups are
  # loaded, since callers merge groups on top of it.
  defp default_transformers do
    Stem.Transformers.Minimum.all()
  end

  # Opt-in capability groups, consulted only to build a helpful error message
  # when a template references a transformer that has not been loaded.
  @capability_modules [
    Stem.Transformers.Strings,
    Stem.Transformers.Collections,
    Stem.Transformers.Predicates
  ]

  defp unknown_transformer_message(key) do
    case Enum.filter(@capability_modules, fn mod -> key in mod.names() end) do
      [] ->
        "unknown transformer '#{key}'. Register it with Stem.Transformers.register/2 " <>
          "or pass it in the transformers: map."

      mods ->
        group_phrase = mods |> Enum.map(&inspect/1) |> Enum.join(" or ")
        primary = inspect(hd(mods))

        standard_hint =
          if Stem.Transformers.Strings in mods,
            do: " (Stem.Transformers.Standard bundles Minimum + Strings.)",
            else: ""

        "unknown transformer '#{key}' — provided by the #{group_phrase} capability group, " <>
          "which is not loaded. Enable it via the transformers: option " <>
          "(transformers: #{primary}.all()), the --transformers CLI flag, or the " <>
          "\"transformers\" key in .stem.config.json." <>
          standard_hint <>
          " Prefer loading a capability group over allow_elixir_expressions: true — " <>
          "mix stem.audit fails CI if that reaches production config."
    end
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name

  defp normalize_transformers(functions) when is_map(functions) do
    Map.new(functions, fn {name, fun} -> {normalize_name(name), fun} end)
  end

  defp normalize_transformers(functions) when is_list(functions) do
    functions |> Enum.into(%{}) |> normalize_transformers()
  end

  defp registry do
    :persistent_term.get(@registry_key, %{})
  end
end
