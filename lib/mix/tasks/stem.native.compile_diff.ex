# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Stem.Native.CompileDiff do
  use Mix.Task

  @shortdoc "Differential-check the native (Rust/WASM) compiler against the BEAM compiler"

  @moduledoc """
  The parity gate for the native parser+compiler port.

  The BEAM compiler is the spec oracle: for each template, this task compiles to
  wire bytecode on the BEAM (`Stem.Parser.parse_with_spans/1` →
  `Stem.Bytecode.compile/1` → `Stem.Bytecode.to_wire/1`) and on the native
  engine (`{"compile": ...}`), then compares the two programs structurally.

  Each template lands in one of three buckets:

    * **match** — the native compiler produced byte-identical bytecode;
    * **pending** — the native compiler returned an `error` ("not yet
      supported"); the construct is not ported yet, which is not a failure;
    * **mismatch** — the native compiler produced *different* bytecode. This is
      a hard failure: it means the two parsers disagree, the exact
      parser-differential risk this gate exists to catch.

  As the Rust grammar grows, templates move from *pending* to *match*; a
  *mismatch* must never appear. Run it after every grammar increment.

      mix stem.native.compile_diff
      mix stem.native.compile_diff --engine "native/stem_native/target/release/stem_native"
  """

  alias Stem.Native.Engine

  # Templates spanning the ported subset (expected to match) and a few not yet
  # ported (expected to land in the pending bucket, proving the gate classifies
  # rather than miscompiles). Grow this list as the grammar expands.
  @templates [
    "",
    "no tags here",
    "Hello {{name}}!",
    "{{name}}",
    "{{user.name}}",
    "{{a.b.c}}",
    "Dear {{user.profile.name}}, welcome",
    "{{{raw}}}",
    "{{{user.bio}}}",
    "prefix {{x}} mid {{y.z}} suffix",
    # Not yet ported — should be reported as pending, not mismatched.
    "{{name |> upcase}}",
    "{{#if active}}on{{/if}}",
    "{{@index}}",
    "{{../name}}"
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("compile")
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: [engine: :string, wasm: :string])
    engine = Engine.resolve(opts)

    beam = Enum.map(@templates, &beam_wire/1)
    rust = Engine.compile_batch(engine, @templates)

    results =
      [@templates, beam, rust]
      |> Enum.zip()
      |> Enum.map(fn {template, beam_wire, rust_wire} ->
        classify(template, beam_wire, rust_wire)
      end)

    report(engine, results)
  end

  defp beam_wire(template) do
    {:ok, ast} = Stem.Parser.parse_with_spans(template)
    ast |> Stem.Bytecode.compile() |> Stem.Bytecode.to_wire()
  end

  defp classify(template, _beam_wire, %{"error" => _} = _rust_wire), do: {:pending, template}

  defp classify(template, beam_wire, rust_wire) do
    if beam_wire == rust_wire,
      do: {:match, template},
      else: {:mismatch, template, beam_wire, rust_wire}
  end

  defp report(engine, results) do
    Mix.shell().info("Native engine: #{engine}")
    counts = Enum.frequencies_by(results, &elem(&1, 0))
    matched = Map.get(counts, :match, 0)
    pending = Map.get(counts, :pending, 0)
    mismatches = Enum.filter(results, &(elem(&1, 0) == :mismatch))

    Enum.each(mismatches, fn {:mismatch, template, beam_wire, rust_wire} ->
      Mix.shell().error(
        "  ✗ #{inspect(template)}\n" <>
          "    beam: #{inspect(beam_wire)}\n" <>
          "    rust: #{inspect(rust_wire)}"
      )
    end)

    Mix.shell().info(
      "Compile parity: #{matched} matched, #{pending} pending (not yet ported), " <>
        "#{length(mismatches)} mismatched of #{length(results)} templates."
    )

    unless mismatches == [] do
      Mix.raise("Native compile parity failed: #{length(mismatches)} template(s) diverged.")
    end
  end
end
