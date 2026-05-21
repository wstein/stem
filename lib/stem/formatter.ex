# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Formatter do
  @moduledoc false

  alias Stem.Expression

  @spec format_string(binary()) :: binary()
  def format_string(source) when is_binary(source) do
    Regex.replace(~r/\{\{(.*?)\}\}/s, source, fn _, inner ->
      format_tag(inner)
    end)
  end

  defp format_tag(inner) do
    trimmed = String.trim(inner)
    {left_trim, core} = extract_trim(trimmed, :leading)
    {right_trim, core} = extract_trim(core, :trailing)
    core = String.trim(core)

    formatted =
      cond do
        core == "" ->
          ""

        core == "else" ->
          "else"

        String.starts_with?(core, "!--") ->
          core

        String.starts_with?(core, "!") ->
          core

        String.starts_with?(core, "/") ->
          ("/" <> String.trim_leading(core, "/")) |> String.trim()

        String.starts_with?(core, ">") ->
          "> " <> (core |> String.trim_leading(">") |> String.trim())

        String.starts_with?(core, "#") ->
          format_block_open(core)

        true ->
          case Expression.parse(core) do
            {:ok, expr} -> Expression.format(expr)
            {:error, message} -> raise ArgumentError, message
          end
      end

    "{{#{left_trim}#{formatted}#{right_trim}}}"
  end

  defp format_block_open("#" <> rest) do
    case String.split(String.trim(rest), ~r/\s+/, parts: 2) do
      [name] -> "##{name}"
      [name, args] -> "##{name} #{String.trim(args)}"
    end
  end

  defp extract_trim(string, :leading) do
    if String.starts_with?(string, "~") do
      {"~", String.trim_leading(string, "~")}
    else
      {"", string}
    end
  end

  defp extract_trim(string, :trailing) do
    if String.ends_with?(string, "~") do
      {"~", String.trim_trailing(string, "~")}
    else
      {"", string}
    end
  end
end
