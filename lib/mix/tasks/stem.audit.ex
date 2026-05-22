# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Stem.Audit do
  use Mix.Task

  @shortdoc "Audit Stem configuration for insecure settings"

  @moduledoc """
  Static analysis gate for Stem security settings.

  `mix stem.audit` scans the files listed in `--paths` (defaulting to
  `config/prod.exs`, `config/runtime.exs`, and `.stem.config.json`) for

      allow_elixir_expressions: true

  and **fails the build** if any are found:

  * Source files (`.ex`/`.exs`) are scanned line-by-line, catching both
    `config :stem, allow_elixir_expressions: true` settings and single-line
    `Stem.Unsafe.eval_string/eval_file` calls that pass the flag.
  * `.stem.config.json` files are parsed as JSON and flagged when the
    `allow_elixir_expressions` key is `true`.

  Add this task to your CI/CD pipeline to ensure that arbitrary Elixir
  expression evaluation is never enabled in production.

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
  * `1` — one or more violations found

  A path passed explicitly via `--paths` that does not exist is treated as a
  violation: the gate fails closed because it cannot verify a file it cannot
  read (a renamed or mistyped `config/prod.exs` must not pass silently). A
  *default* path that is absent is skipped, so the task stays quiet in projects
  that do not have those config files.

  > #### Best-effort textual scan {: .info}
  >
  > Source files are matched with a regular expression, so the flag is detected
  > even inside comments or strings (possible false positives) and aliased or
  > multi-line forms may be missed (possible false negatives). Treat this as a
  > fast guardrail, not a substitute for review.
  """

  @default_paths ~w(config/prod.exs config/runtime.exs .stem.config.json)

  # Pattern that matches any line enabling allow_elixir_expressions
  @dangerous_pattern ~r/allow_elixir_expressions\s*:\s*true/

  @impl true
  def run(argv) do
    {opts, extra_paths, _invalid} =
      OptionParser.parse(argv, strict: [paths: :keep])

    {paths, fail_on_missing?} =
      case Keyword.get_values(opts, :paths) ++ extra_paths do
        [] -> {@default_paths, false}
        explicit -> {explicit, true}
      end

    violations = scan_paths(paths, fail_on_missing?)

    if violations == [] do
      Mix.shell().info("Stem audit passed — no insecure settings found.")
    else
      Enum.each(violations, &report_violation/1)

      Mix.raise("Stem audit failed: #{length(violations)} violation(s) found.")
    end
  end

  defp report_violation({file, :missing, _text}) do
    Mix.shell().error(
      "#{file}: [stem.audit] explicitly audited file does not exist; the gate " <>
        "fails closed because it cannot verify allow_elixir_expressions is not enabled."
    )
  end

  defp report_violation({file, line, text}) do
    Mix.shell().error(
      "#{file}:#{line}: [stem.audit] allow_elixir_expressions: true must not " <>
        "be used in production configuration.\n" <>
        "  #{String.trim(text)}"
    )
  end

  # Returns a list of {file, line_number, line_text} tuples for each violation.
  # A missing file yields {file, :missing, nil} when its path was given
  # explicitly (fail closed); a missing default path is skipped.
  defp scan_paths(paths, fail_on_missing?) do
    Enum.flat_map(paths, fn path ->
      abs = Path.expand(path, File.cwd!())

      cond do
        not File.exists?(abs) and fail_on_missing? ->
          [{path, :missing, nil}]

        not File.exists?(abs) ->
          Mix.shell().info("Stem audit: #{path} not found, skipping.")
          []

        String.ends_with?(path, ".json") ->
          scan_json(path, abs)

        true ->
          scan_source(path, abs)
      end
    end)
  end

  # Line-by-line scan of Elixir source/config files.
  defp scan_source(path, abs) do
    abs
    |> File.stream!()
    |> Stream.with_index(1)
    |> Stream.filter(fn {line, _n} -> Regex.match?(@dangerous_pattern, line) end)
    |> Enum.map(fn {line, n} -> {path, n, line} end)
  end

  # Parses a `.stem.config.json` file and flags `allow_elixir_expressions: true`.
  defp scan_json(path, abs) do
    content = File.read!(abs)

    case JSON.decode(content) do
      {:ok, %{"allow_elixir_expressions" => true}} ->
        line = json_key_line(content) || 1
        [{path, line, ~s("allow_elixir_expressions": true)}]

      {:ok, _decoded} ->
        []

      {:error, _reason} ->
        Mix.shell().info("Stem audit: #{path} is not valid JSON, skipping.")
        []
    end
  end

  # Best-effort line number of the offending key for a readable report.
  defp json_key_line(content) do
    content
    |> String.split("\n")
    |> Enum.find_index(&Regex.match?(~r/"allow_elixir_expressions"/, &1))
    |> case do
      nil -> nil
      index -> index + 1
    end
  end
end
