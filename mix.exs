# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

defmodule Stem.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :stem,
      version: @version,
      elixir: "~> 1.17",
      description: description(),
      package: package(),
      docs: docs(),
      build_per_environment: false,
      deps: deps(),
      test_coverage: [
        summary: [threshold: 98],
        ignore_modules: [
          Stem.CoverageMetrics,
          Mix.Tasks.Coveralls.Branchcov,
          # Native PoC harness: needs the Rust/WASM toolchain + Node, so it runs
          # via `mix stem.native.verify` / `mix stem.native.fuzz`, not the unit suite.
          Mix.Tasks.Stem.Native.Verify,
          Mix.Tasks.Stem.Native.Fuzz,
          Stem.Native.Engine
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:nimble_parsec, "~> 1.4"},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp description do
    "Structural backbone for Handlebars templates in Elixir"
  end

  defp package do
    [
      name: "stem",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/elixir-lang/stem"
      },
      files: [
        "lib",
        "examples",
        "test/fixtures",
        "README.md",
        "LICENSE"
      ]
    ]
  end

  defp docs do
    [
      main: "Stem",
      source_ref: "v#{@version}",
      source_url: "https://github.com/elixir-lang/elixir",
      extras: ["README.md"]
    ]
  end
end
