# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Stem.Audit do
  use Mix.Task

  @shortdoc "Audit Stem configuration for insecure settings"

  @moduledoc """
  Static analysis gate for Stem security settings.

  `mix stem.audit` scans the files listed in `--paths` (defaulting to
  `config/prod.exs` and `config/runtime.exs`) for occurrences of

      allow_elixir_expressions: true

  and **fails the build** if any are found. Add this task to your CI/CD
  pipeline to ensure that arbitrary Elixir expression evaluation is never
  enabled in production templates.

  ## Usage

      mix stem.audit
      mix stem.audit --paths config/prod.exs config/releases.exs

  ## CI/CD integration

  Add to your `.github/workflows/ci.yml` (or equivalent):

      - run: mix stem.audit

  A non-zero exit code is returned if any violation is found, which causes
  most CI systems to fail the job automatically.

  ## Exit codes

  * `0` — no violations found
  * `1` — one or more violations found (or a listed file does not exist)
  """

  @default_paths ~w(config/prod.exs config/runtime.exs)

  # Pattern that matches any line enabling allow_elixir_expressions
  @dangerous_pattern ~r/allow_elixir_expressions\s*:\s*true/

  @impl true
  def run(argv) do
    {opts, extra_paths, _invalid} =
      OptionParser.parse(argv, strict: [paths: :keep])

    paths =
      case Keyword.get_values(opts, :paths) ++ extra_paths do
        [] -> @default_paths
        explicit -> explicit
      end

    violations = scan_paths(paths)

    if violations == [] do
      Mix.shell().info("Stem audit passed — no insecure settings found.")
    else
      Enum.each(violations, fn {file, line, text} ->
        Mix.shell().error(
          "#{file}:#{line}: [stem.audit] allow_elixir_expressions: true must not " <>
            "be used in production configuration.\n" <>
            "  #{String.trim(text)}"
        )
      end)

      Mix.raise(
        "Stem audit failed: #{length(violations)} violation(s) found. " <>
          "Remove allow_elixir_expressions: true from production config files."
      )
    end
  end

  # Returns a list of {file, line_number, line_text} tuples for each violation.
  defp scan_paths(paths) do
    Enum.flat_map(paths, fn path ->
      abs = Path.expand(path, File.cwd!())

      cond do
        not File.exists?(abs) ->
          Mix.shell().info("Stem audit: #{path} not found, skipping.")
          []

        true ->
          abs
          |> File.stream!()
          |> Stream.with_index(1)
          |> Stream.filter(fn {line, _n} -> Regex.match?(@dangerous_pattern, line) end)
          |> Enum.map(fn {line, n} -> {path, n, line} end)
      end
    end)
  end
end
