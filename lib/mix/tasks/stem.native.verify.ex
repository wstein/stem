# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Stem.Native.Verify do
  use Mix.Task

  @shortdoc "Verify the native (Rust/WASM) PoC matches the BEAM on the conformance corpus"

  @moduledoc """
  Drives the native renderer PoC against the cross-backend conformance corpus.

  For every vector in `Stem.Conformance`, this task compiles the template to
  portable bytecode (`Stem.Bytecode.to_wire/1`), feeds `{program, data}` to the
  native engine, and asserts the output is byte-for-byte identical to the
  reference (BEAM) backend. It is the proof that the portable bytecode + a
  from-scratch native engine reproduce Stem's semantics off the BEAM.

  ## Usage

      # default: run the wasm32-wasip1 module via Node's WASI
      mix stem.native.verify

      # run the host binary instead
      mix stem.native.verify --engine "native/stem_native/target/release/stem_native"

      # point at a specific wasm module
      mix stem.native.verify --wasm path/to/stem_native.wasm

  Build the engine first (see native/README.md):

      cd native/stem_native && cargo build --release --target wasm32-wasip1

  The engine command must read a JSON request on stdin and write the rendered
  output to stdout. A non-zero exit code is returned if any vector diverges or
  the engine is missing.
  """

  @default_wasm "native/stem_native/target/wasm32-wasip1/release/stem_native.wasm"

  @impl true
  def run(argv) do
    Mix.Task.run("compile")
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: [engine: :string, wasm: :string])
    engine = resolve_engine(opts)

    corpus = Stem.Conformance.corpus()

    {passed, failures} =
      Enum.reduce(corpus, {0, []}, fn vector, {passed, failures} ->
        expected = Stem.Conformance.render_with_compiler(vector)
        actual = run_engine(engine, vector)

        if actual == expected do
          {passed + 1, failures}
        else
          {passed, [{vector.name, expected, actual} | failures]}
        end
      end)

    report(engine, passed, length(corpus), Enum.reverse(failures))
  end

  defp resolve_engine(opts) do
    cond do
      engine = opts[:engine] ->
        engine

      true ->
        wasm = opts[:wasm] || @default_wasm

        unless File.exists?(wasm) do
          Mix.raise(
            "native engine not found at #{wasm}. Build it with:\n" <>
              "  cd native/stem_native && cargo build --release --target wasm32-wasip1\n" <>
              "or pass --engine \"<command reading stdin>\"."
          )
        end

        "node native/run.mjs #{wasm}"
    end
  end

  defp run_engine(engine, vector) do
    {:ok, ast} = Stem.Parser.parse_with_spans(vector.template)
    program = Stem.Bytecode.compile(ast, escape: Map.get(vector, :escape, :html))
    request = JSON.encode!(%{"program" => Stem.Bytecode.to_wire(program), "data" => vector.data})

    tmp = Path.join(System.tmp_dir!(), "stem_native_#{System.unique_integer([:positive])}.json")
    File.write!(tmp, request)

    try do
      {output, _status} = System.cmd("sh", ["-c", "#{engine} < #{tmp} 2>/dev/null"])
      output
    after
      File.rm!(tmp)
    end
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
