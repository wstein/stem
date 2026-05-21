# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Config do
  @moduledoc false

  # Config file loading and merging for Stem templates.
  # Supports .stem.config.json files with sensible defaults for escape mode,
  # warn_on_missing_assigns, and compiler mode.

  @config_filename ".stem.config.json"

  @spec load_config(String.t()) :: {:ok, keyword()} | {:error, String.t()}
  def load_config(config_path) when is_binary(config_path) do
    case File.read(config_path) do
      {:ok, content} ->
        case parse_json(content) do
          {:ok, map} -> {:ok, normalize_config(map)}
          {:error, reason} -> {:error, "Failed to parse #{config_path}: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to read #{config_path}: #{inspect(reason)}"}
    end
  end

  @spec find_config(Path.t()) :: {:ok, Path.t()} | :not_found
  def find_config(search_root) when is_binary(search_root) do
    search_root
    |> Path.expand()
    |> walk_up_directory_tree()
  end

  @spec merge_with_defaults(keyword(), keyword()) :: keyword()
  def merge_with_defaults(loaded_config, compile_opts) do
    Keyword.merge(loaded_config, compile_opts)
  end

  # Private

  defp walk_up_directory_tree(dir) do
    config_path = Path.join(dir, @config_filename)

    if File.exists?(config_path) do
      {:ok, config_path}
    else
      parent = Path.dirname(dir)

      if parent == dir do
        :not_found
      else
        # Stop walking if we find mix.exs (project root)
        if File.exists?(Path.join(parent, "mix.exs")) do
          if File.exists?(Path.join(parent, @config_filename)) do
            {:ok, Path.join(parent, @config_filename)}
          else
            :not_found
          end
        else
          walk_up_directory_tree(parent)
        end
      end
    end
  end

  defp parse_json(content) when is_binary(content) do
    try do
      content = String.trim(content)

      unless String.starts_with?(content, "{") and String.ends_with?(content, "}") do
        raise "invalid JSON structure"
      end

      inner = content |> String.slice(1, String.length(content) - 2) |> String.trim()

      if inner == "" do
        {:ok, %{}}
      else
        # Extract all "key": value pairs using regex
        pattern = ~r/"([^"]+)"\s*:\s*([^,}]+)/

        map =
          Regex.scan(pattern, inner)
          |> Enum.reduce(%{}, fn [_full, key, value], acc ->
            value = String.trim(value)
            parsed_value = parse_json_value(value)
            Map.put(acc, key, parsed_value)
          end)

        if map == %{} and inner != "" do
          raise "invalid JSON pairs"
        end

        {:ok, map}
      end
    rescue
      _error -> {:error, "invalid JSON"}
    end
  end

  defp parse_json_value(value) do
    cond do
      value == "true" ->
        true

      value == "false" ->
        false

      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        String.slice(value, 1, String.length(value) - 2)

      true ->
        value
    end
  end

  defp normalize_config(map) when is_map(map) do
    []
    |> maybe_add_escape(map)
    |> maybe_add_warn_on_missing_assigns(map)
    |> maybe_add_mode(map)
  end

  defp maybe_add_escape(acc, map) do
    case Map.get(map, "escape") do
      nil -> acc
      mode_string -> Keyword.put(acc, :escape, parse_escape_mode(mode_string))
    end
  end

  defp maybe_add_warn_on_missing_assigns(acc, map) do
    case Map.get(map, "warn_on_missing_assigns") do
      nil -> acc
      value when is_boolean(value) -> Keyword.put(acc, :warn_on_missing_assigns, value)
      _ -> acc
    end
  end

  defp maybe_add_mode(acc, map) do
    case Map.get(map, "mode") do
      nil ->
        acc

      mode_string when mode_string in ["permissive", "safe"] ->
        Keyword.put(acc, :mode, String.to_atom(mode_string))

      _ ->
        acc
    end
  end

  defp parse_escape_mode(mode_string) when is_binary(mode_string) do
    case String.downcase(mode_string) do
      "none" -> :none
      "html" -> :html
      "xml" -> :xml
      "json" -> :json
      "url" -> :url
      _ -> :html
    end
  end
end
