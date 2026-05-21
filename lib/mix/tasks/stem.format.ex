# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Stem.Format do
  use Mix.Task

  @shortdoc "Format Stem templates"

  @impl true
  def run(argv) do
    {opts, paths, invalid} =
      OptionParser.parse(argv, strict: [check_formatted: :boolean])

    if invalid != [] or paths == [] do
      Mix.raise("Usage: mix stem.format [--check-formatted] FILE...")
    end

    check? = !!opts[:check_formatted]

    mismatches =
      Enum.reduce(paths, [], fn path, acc ->
        original = File.read!(path)
        formatted = Stem.Formatter.format_string(original)

        cond do
          original == formatted ->
            acc

          check? ->
            [path | acc]

          true ->
            File.write!(path, formatted)
            acc
        end
      end)

    if check? and mismatches != [] do
      Mix.raise("Unformatted Stem templates: #{Enum.join(Enum.reverse(mismatches), ", ")}")
    end
  end
end
