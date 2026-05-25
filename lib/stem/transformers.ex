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

  @doc """
  Registers a whole map of transformers (e.g. a group's `.all()`) into the global
  registry in one call, making them available to every render without a per-call
  `transformers:` binding.

  Intended for trusted-internal apps that want a richer baseline app-wide — call
  it once at startup, e.g. `Stem.Transformers.register_all(Stem.Transformers.Standard.all())`.
  Do **not** use it in an app that also renders untrusted templates, since it
  widens the default capability set for *all* renders; pass `transformers:`
  per-render there instead.
  """
  @spec register_all(%{optional(atom() | String.t()) => transformer()}) :: :ok
  def register_all(functions) when is_map(functions) do
    additions = Map.new(functions, fn {name, fun} -> {normalize_name(name), fun} end)
    :persistent_term.put(@registry_key, Map.merge(registry(), additions))
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

    check_builtin_arity!(helper_key, length(args))
    helper.(args, %{assigns: assigns, this: this, binding: binding_env})
  end

  # Inclusive positional-argument arity (`{min, max}`) of each built-in
  # transformer, kept in lockstep with the native `builtin_arity` table so an
  # arity mismatch reports the same message on both backends. The subject (the
  # piped value, or the first argument in prefix form) is the first positional,
  # so `title | replace "a" "b"` carries three positionals. Overriding a
  # built-in name with a host transformer of a different arity is unsupported:
  # arity is keyed by built-in name.
  @builtin_arity %{
    "replace" => {3, 3},
    "slice" => {3, 3},
    "default" => {2, 2},
    "lookup" => {2, 2},
    "starts_with" => {2, 2},
    "ends_with" => {2, 2},
    "take" => {2, 2},
    "drop" => {2, 2},
    "map" => {2, 2},
    "sort_by" => {2, 2},
    "group_by" => {2, 2},
    "contains" => {2, 2},
    "truncate" => {2, 3},
    "join" => {1, 2},
    "filter" => {1, 2},
    "escape_html" => {1, 1},
    "escape_json" => {1, 1},
    "json" => {1, 1},
    "inspect" => {1, 1},
    "first" => {1, 1},
    "last" => {1, 1},
    "len" => {1, 1},
    "empty?" => {1, 1},
    "present?" => {1, 1},
    "upcase" => {1, 1},
    "downcase" => {1, 1},
    "trim" => {1, 1},
    "capitalize" => {1, 1},
    "reverse" => {1, 1},
    "sort" => {1, 1},
    "compact" => {1, 1},
    "uniq" => {1, 1},
    "flatten" => {1, 1}
  }

  defp check_builtin_arity!(key, got) do
    case Map.get(@builtin_arity, key) do
      nil -> :ok
      {min, max} when got >= min and got <= max -> :ok
      {min, max} -> raise Stem.SyntaxError, arity_message(key, min, max, got)
    end
  end

  defp arity_message(name, min, max, got) do
    expected =
      if min == max,
        do: "#{min} argument#{if(min == 1, do: "", else: "s")}",
        else: "#{min} to #{max} arguments"

    "transformer '#{name}' takes #{expected}, got #{got}"
  end

  @doc """
  The built-in capability groups, mapping each group's atom name to its module.

  Single source of truth for the set of groups, used wherever code needs to map
  group names to their transformers (capability metadata, conformance tooling).
  """
  @spec groups() :: %{atom() => module()}
  def groups do
    %{
      minimum: Stem.Transformers.Minimum,
      strings: Stem.Transformers.Strings,
      collections: Stem.Transformers.Collections,
      predicates: Stem.Transformers.Predicates,
      i18n: Stem.Transformers.I18n
    }
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
          standard_hint
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
