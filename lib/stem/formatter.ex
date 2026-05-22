# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Formatter do
  @moduledoc """
  Stem template formatter.

  Normalises Stem template syntax: canonicalises tag whitespace, trims markers,
  and pipes. Can be used as a standalone function (`format_string/1`) or as an
  **Elixir formatter plugin** declared in `.formatter.exs`:

      # .formatter.exs
      [
        plugins: [Stem.Formatter],
        inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "templates/**/*.stem"]
      ]

  When used as a plugin, `mix format` automatically processes every `.stem` file
  listed in `inputs`.

  ## Whitespace-trim markers

  The formatter normalises the visual noise around `{{~` and `~}}` whitespace
  trim markers:

  - `{{ ~ ... ~ }}` → `{{~...~}}`  (spaces between braces and tilde removed)
  - `{{~ ... ~}}` → `{{~...~}}`   (space after opening tilde removed)
  - `{{  expr  }}` → `{{expr}}`   (padding around expressions removed)

  This keeps template source readable without changing compiled output.
  """

  @behaviour Mix.Tasks.Format

  alias Stem.Expression

  # ── Formatter plugin callbacks ────────────────────────────────────────────

  @impl Mix.Tasks.Format
  def features(_opts), do: [extensions: [".stem"]]

  @impl Mix.Tasks.Format
  def format(contents, _opts) do
    format_string(contents)
  end

  # ── Public API ────────────────────────────────────────────────────────────

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
