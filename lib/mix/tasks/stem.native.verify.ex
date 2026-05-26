# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Stem.Native.Verify do
  use Mix.Task

  @shortdoc "Verify the native (Rust/WASM) PoC matches the BEAM on the conformance corpus"

  @moduledoc """
  Drives the native renderer PoC against the cross-backend conformance corpus.

  For every vector in `Stem.Conformance`, this task compiles the template to
  portable bytecode (`Stem.Bytecode.to_wire/1`), feeds `{program, data}` to the
  native engine in a single batch, and asserts the output is byte-for-byte
  identical to the reference (BEAM) backend.

  ## Usage

      # default: run the wasm32-wasip1 module via Node's WASI
      mix stem.native.verify

      # run the host binary instead
      mix stem.native.verify --engine "native/target/release/stem_native"

      # point at a specific wasm module
      mix stem.native.verify --wasm path/to/stem_native.wasm

  Build the engine first (see native/README.md):

      cd native/stem_native && cargo build --release --target wasm32-wasip1
  """

  alias Stem.Native.Engine

  @impl true
  def run(argv) do
    Mix.Task.run("compile")
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: [engine: :string, wasm: :string])
    engine = Engine.resolve(opts)

    corpus = Stem.Conformance.corpus()

    requests =
      Enum.map(corpus, fn vector ->
        groups = Enum.map(vector.transformers, &Atom.to_string/1)
        Engine.request(vector.template, vector.data, Map.get(vector, :escape, :html), groups)
      end)

    actuals = Engine.render_batch(engine, requests)

    failures =
      [corpus, actuals]
      |> Enum.zip()
      |> Enum.flat_map(fn {vector, actual} ->
        expected = Stem.Conformance.render_with_compiler(vector)
        if actual == expected, do: [], else: [{vector.name, expected, actual}]
      end)

    report(engine, length(corpus) - length(failures), length(corpus), failures)
  end

  defp report(engine, passed, total, []) do
    Mix.shell().info("Native engine: #{engine}")

    Mix.shell().info(
      "Conformance: #{passed}/#{total} vectors match the BEAM reference byte-for-byte."
    )
  end

  defp report(engine, passed, total, failures) do
    Mix.shell().info("Native engine: #{engine}")

    Enum.each(failures, fn {name, expected, actual} ->
      Mix.shell().error(
        "  ✗ #{name}\n    expected: #{inspect(expected)}\n    actual:   #{inspect(actual)}"
      )
    end)

    Mix.raise(
      "Native conformance failed: #{passed}/#{total} matched, #{length(failures)} diverged."
    )
  end
end
