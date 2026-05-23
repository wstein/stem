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
    # Text + expressions
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
    "{{@index}} {{@index1}} {{@key}}",
    "{{../name}}",
    # Block helpers
    "{{#if active}}on{{else}}off{{/if}}",
    "{{#unless active}}off{{/unless}}",
    "{{#each items}}{{this}};{{/each}}",
    "{{#each items}}x{{else}}none{{/each}}",
    "{{#each items as |item|}}{{item}} {{/each}}",
    "{{#each items as |item idx|}}{{idx}}:{{item}} {{/each}}",
    "{{#each rows as |row i0 i1|}}{{i0}}/{{i1}} {{/each}}",
    "{{#each rows}}{{@index1}}. {{this.name}}{{/each}}",
    "{{#with user}}{{this.name}}{{/with}}",
    "{{#with user as |u|}}{{u.name}} <{{u.email}}>{{/with}}",
    "<ul>{{#each items}}<li>{{@index1}}. {{this}}</li>{{/each}}</ul>",
    "{{#each items}}{{../title}}: {{this}}{{/each}}",
    "{{#each rows}}{{#if this.active}}[{{this.name}}]{{/if}}{{/each}}",
    # Transformers and pipelines
    "{{name |> upcase}}",
    "{{name |> upcase |> trim}}",
    "{{text |> truncate(20)}}",
    "{{items |> join(\", \")}}",
    "{{upcase name}}",
    "{{default user.name \"anon\"}}",
    "{{truncate text 20}}",
    "{{default (upcase name) \"X\"}}",
    "{{link url text=label}}",
    "{{x |> wrap(tag: \"b\")}}",
    "{{#each items}}{{this.name |> upcase}}{{/each}}",
    "{{42}} {{-3}} {{true}} {{null}}",
    # Comments and whitespace-control trim markers
    "a {{~ x ~}} b",
    "a {{! c }} b",
    "{{!-- c --}}x",
    "a {{x ~}}   b",
    "{{#each items}}{{this}}{{~/each}}",
    # Not yet ported — should be reported as pending, not mismatched.
    # (Both still compile on the BEAM, so they exercise the pending bucket.)
    "{{'single'}}",
    "{{yield undefined}}"
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
