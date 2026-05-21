# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Escaping do
  @moduledoc false

  @registry_key {__MODULE__, :registry}
  @type escape_formatter :: (String.t() -> String.t())

  @spec register(atom() | String.t(), escape_formatter()) :: :ok
  def register(name, fun) when is_function(fun, 1) do
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

  @spec escape(term(), atom()) :: String.t()
  def escape(value, escape_mode) when is_atom(escape_mode) do
    string = String.Chars.to_string(value)
    formatter = find_escape_formatter(escape_mode)
    formatter.(string)
  end

  @spec escape_html(term()) :: String.t()
  def escape_html(value) do
    escape(value, :html)
  end

  defp find_escape_formatter(escape_mode) do
    case builtin_formatter(escape_mode) do
      fun when is_function(fun, 1) ->
        fun

      nil ->
        key = normalize_name(escape_mode)

        case Map.get(registry(), key) do
          fun when is_function(fun, 1) ->
            fun

          nil ->
            raise ArgumentError,
                  "unknown escape mode '#{escape_mode}', ensure it's registered or built-in"
        end
    end
  end

  defp builtin_formatter(:none), do: fn x -> x end

  defp builtin_formatter(:html) do
    fn value ->
      value
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&#39;")
    end
  end

  defp builtin_formatter(:xml) do
    fn value ->
      value
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
    end
  end

  defp builtin_formatter(:json) do
    fn value ->
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")
    end
  end

  defp builtin_formatter(:url) do
    fn value ->
      URI.encode_www_form(value)
    end
  end

  defp builtin_formatter(_), do: nil

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name

  defp registry do
    :persistent_term.get(@registry_key, %{})
  end
end
