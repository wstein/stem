# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Stem.Docs.Drift do
  use Mix.Task

  @shortdoc "Fail if the hand-written docs reference removed/renamed terms"

  @moduledoc """
  A cheap drift gate for the hand-written AsciiDoc docs under `docs/`.

  The Antora `.adoc` sources are hand-maintained (see CLAUDE.md), so they rot
  silently when APIs are renamed or removed. This task greps them for a small
  set of *dead terms* and fails the build if any survive outside the places they
  are legitimately mentioned.

  It is deliberately conservative — each rule carries an `except` allow-list, so
  pages that document a rename (the migration guide, the changelog) or name an
  API in prose (the ADR log) don't trip false positives. Extend `@rules` as more
  terms are retired.

      mix stem.docs.drift
  """

  # `term` is a literal substring; a line in a non-excepted file containing it is
  # a violation. `except` lists file *basenames* where the term is expected.
  @rules [
    %{term: "myproject", why: "placeholder project name (use Stem)", except: []},
    %{term: "unescaped by default",
      why: "stale claim — output is HTML-escaped by default", except: []},
    %{term: "View Model", why: "renamed playground view -> 'Render Data'", except: []},
    %{term: "is_truthy", why: "renamed -> truthy?",
      except: ["migration.adoc", "changelog.adoc"]}
  ]

  # `eval_string`/`eval_file` must be qualified with `Stem.Unsafe.`; the migration
  # guide, changelog, and ADR log may name the bare function in prose.
  @eval_except ["migration.adoc", "changelog.adoc", "09-architecture-decisions.adoc"]

  @impl true
  def run(_argv) do
    files =
      Path.wildcard("docs/**/*.adoc") ++
        Path.wildcard("docs/**/*.md") ++ ["docs/antora.yml"]

    violations = files |> Enum.filter(&File.regular?/1) |> Enum.flat_map(&scan/1)

    if violations == [] do
      Mix.shell().info("Docs drift: clean (#{length(files)} files scanned).")
    else
      Enum.each(violations, fn {file, line, msg} ->
        Mix.shell().error("  #{file}:#{line}  #{msg}")
      end)

      Mix.raise("Docs drift: #{length(violations)} dead-term reference(s).")
    end
  end

  defp scan(file) do
    base = Path.basename(file)

    file
    |> File.stream!()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} -> line_violations(line, n, file, base) end)
  end

  defp line_violations(line, n, file, base) do
    term_hits =
      for %{term: term, why: why, except: except} <- @rules,
          base not in except,
          String.contains?(line, term),
          do: {file, n, "dead term #{inspect(term)} — #{why}"}

    eval_hit =
      if base not in @eval_except and line =~ ~r/\beval_(string|file)\b/ and
           not (line =~ ~r/Stem\.Unsafe\.eval_/) do
        [{file, n, "eval_string/eval_file must be qualified with Stem.Unsafe."}]
      else
        []
      end

    term_hits ++ eval_hit
  end
end
