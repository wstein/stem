# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Native.Engine do
  @moduledoc false

  # Support for the native PoC verification tasks (`mix stem.native.verify`,
  # `mix stem.native.fuzz`): resolve the engine command and run a batch of
  # `{program, data}` requests through it in a single process.

  @default_wasm "native/stem_native/target/wasm32-wasip1/release/stem_native.wasm"

  @doc "Resolves the engine command from `--engine`/`--wasm` options (default: the wasm via Node WASI)."
  @spec resolve(keyword()) :: String.t()
  def resolve(opts) do
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

  @doc """
  Builds a `{program, data, transformers}` request map for a template + assigns.

  `groups` names the capability groups the caller has loaded (group-name strings,
  e.g. `["strings", "collections"]`); the native engine enables Minimum always
  and refuses any transformer outside the listed groups, mirroring the BEAM
  `transformers:` binding.
  """
  @spec request(String.t(), map() | keyword(), atom(), [String.t()]) :: map()
  def request(template, data, escape, groups \\ []) do
    {:ok, ast} = Stem.Parser.parse_with_spans(template)
    program = Stem.Bytecode.compile(ast, escape: escape)

    %{
      "program" => Stem.Bytecode.to_wire(program),
      "data" => data,
      "transformers" => groups
    }
  end

  @doc """
  Runs a batch of requests through the engine in one invocation, returning the
  rendered strings in order.
  """
  @spec render_batch(String.t(), [map()]) :: [String.t()]
  def render_batch(engine, requests) do
    payload = JSON.encode!(%{"batch" => requests})

    tmp =
      Path.join(System.tmp_dir!(), "stem_native_batch_#{System.unique_integer([:positive])}.json")

    File.write!(tmp, payload)

    try do
      {output, _status} = System.cmd("sh", ["-c", "#{engine} < #{tmp} 2>/dev/null"])
      JSON.decode!(output)
    after
      File.rm!(tmp)
    end
  end

  @doc """
  Compiles a batch of template sources through the engine's native compiler in
  one invocation, returning each result as a wire-program map or an
  `%{"error" => %{...}}` map, in order. Used by the BEAM-vs-Rust differential
  harness (`mix stem.native.compile_diff`).
  """
  @spec compile_batch(String.t(), [String.t()]) :: [map()]
  def compile_batch(engine, sources) do
    payload = JSON.encode!(%{"compile_batch" => sources})

    tmp =
      Path.join(
        System.tmp_dir!(),
        "stem_native_compile_#{System.unique_integer([:positive])}.json"
      )

    File.write!(tmp, payload)

    try do
      {output, _status} = System.cmd("sh", ["-c", "#{engine} < #{tmp} 2>/dev/null"])
      JSON.decode!(output)
    after
      File.rm!(tmp)
    end
  end
end
