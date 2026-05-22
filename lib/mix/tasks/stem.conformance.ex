# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Stem.Conformance do
  use Mix.Task

  @shortdoc "Generate the cross-backend conformance vector file"

  @moduledoc """
  Writes the canonical Stem conformance corpus to a JSON file.

  The vectors come from `Stem.Conformance`; each carries the output the
  reference (BEAM) backend produces, so a non-BEAM implementation can validate
  itself against `conformance/vectors.json`.

  ## Usage

      mix stem.conformance
      mix stem.conformance --output build/vectors.json

  The default output path is `conformance/vectors.json`. Run this after changing
  the corpus and commit the regenerated file; the conformance test fails if the
  checked-in file no longer matches the corpus.
  """

  @default_output "conformance/vectors.json"

  @impl true
  def run(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: [output: :string])
    path = Keyword.get(opts, :output, @default_output)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Stem.Conformance.to_json())

    Mix.shell().info("Wrote #{length(Stem.Conformance.corpus())} conformance vectors to #{path}.")
  end
end
