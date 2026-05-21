# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Frontmatter do
  @moduledoc false

  # Frontmatter parsing for .stem template files.
  # Supports YAML frontmatter at the top of templates for per-template config.
  # Format:
  #   ---
  #   escape: html
  #   mode: safe
  #   ---
  #   template content...

  @spec parse(String.t()) :: {:ok, {keyword(), String.t()}} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    source = String.trim_leading(source)

    if String.starts_with?(source, "---") do
      # Try to find closing ---
      rest = String.slice(source, 3, String.length(source) - 3)

      case find_frontmatter_end(rest) do
        {:ok, frontmatter_text, template_body} ->
          case parse_yaml(frontmatter_text) do
            {:ok, config} -> {:ok, {config, template_body}}
            {:error, reason} -> {:error, reason}
          end

        :error ->
          {:error, "frontmatter delimiter '---' not closed"}
      end
    else
      # No frontmatter
      {:ok, {[], source}}
    end
  end

  # Private

  defp find_frontmatter_end(source) do
    # Frontmatter must be closed by --- on its own line
    lines = String.split(source, "\n")

    case find_closing_delimiter(lines, []) do
      {:ok, frontmatter_lines, rest_lines} ->
        frontmatter_text = frontmatter_lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
        template_body = rest_lines |> Enum.join("\n")
        {:ok, frontmatter_text, template_body}

      :error ->
        :error
    end
  end

  defp find_closing_delimiter([line | rest], acc) do
    trimmed = String.trim(line)

    if trimmed == "---" do
      {:ok, acc, rest}
    else
      find_closing_delimiter(rest, [line | acc])
    end
  end

  defp find_closing_delimiter([], _acc) do
    :error
  end

  defp parse_yaml(text) when is_binary(text) do
    text = String.trim(text)

    if text == "" do
      {:ok, []}
    else
      parse_yaml_lines(String.split(text, "\n"), [])
    end
  end

  defp parse_yaml_lines([], acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp parse_yaml_lines([line | rest], acc) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        # Skip empty lines and comments
        parse_yaml_lines(rest, acc)

      String.contains?(line, ":") ->
        case parse_yaml_pair(line) do
          {:ok, key, value} ->
            parse_yaml_lines(rest, [{key, value} | acc])

          :error ->
            parse_yaml_lines(rest, acc)
        end

      true ->
        parse_yaml_lines(rest, acc)
    end
  end

  defp parse_yaml_pair(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = String.trim(value)

        atom_key =
          case String.downcase(key) do
            "escape" -> :escape
            "warn_on_missing_assigns" -> :warn_on_missing_assigns
            "mode" -> :mode
            _ -> nil
          end

        if atom_key do
          {:ok, atom_key, normalize_yaml_value(atom_key, value)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp normalize_yaml_value(:escape, value) do
    case String.downcase(value) do
      "none" -> :none
      "html" -> :html
      "xml" -> :xml
      "json" -> :json
      "url" -> :url
      _ -> :html
    end
  end

  defp normalize_yaml_value(:warn_on_missing_assigns, value) do
    case String.downcase(value) do
      "true" -> true
      "yes" -> true
      "1" -> true
      "false" -> false
      "no" -> false
      "0" -> false
      _ -> false
    end
  end

  defp normalize_yaml_value(:mode, value) do
    case String.downcase(value) do
      "safe" -> :safe
      "permissive" -> :permissive
      _ -> :permissive
    end
  end
end
