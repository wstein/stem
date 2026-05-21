# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Stem do
  use Mix.Task

  @shortdoc "Render a Stem template"

  @moduledoc """
  Render a Stem template.

      mix stem template.stem '{"name":"Nina"}'
      mix stem template.stem data.json -o output.txt
      mix stem - < data.json
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case Stem.CLI.run(args) do
      {:help, usage} ->
        Mix.shell().info(usage)

      {:version, version} ->
        Mix.shell().info(version)

      :ok ->
        :ok
    end
  rescue
    ArgumentError ->
      Mix.raise(Stem.CLI.usage())
  end
end
