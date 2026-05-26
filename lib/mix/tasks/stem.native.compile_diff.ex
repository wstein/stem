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
      mix stem.native.compile_diff --engine "native/target/release/stem_native"
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
    "{{#each rows}}{{@index}}/{{@index1}}/{{@key}}/{{@first}}/{{@last}} {{/each}}",
    "{{@root.name}}",
    "{{items.[2]}}",
    # Block helpers
    "{{#if active}}on{{else}}off{{/if}}",
    "{{#unless active}}off{{/unless}}",
    "{{#each items}}{{@this}};{{/each}}",
    "{{#each items}}x{{else}}none{{/each}}",
    "{{#each items as |item|}}{{item}} {{/each}}",
    "{{#each items as |item idx|}}{{idx}}:{{item}} {{/each}}",
    "{{#each rows as |row i0 i1|}}{{i0}}/{{i1}} {{/each}}",
    "{{#each rows}}{{@index1}}. {{@this.name}}{{/each}}",
    "{{#with user}}{{@this.name}}{{/with}}",
    "Hello {{#with name}}{{@this}}{{/with}}!",
    "{{#each items}}{{@this}};{{/each}}",
    "{{#with user as |u|}}{{u.name}} <{{u.email}}>{{/with}}",
    "<ul>{{#each items}}<li>{{@index1}}. {{@this}}</li>{{/each}}</ul>",
    "{{#each items}}{{@parent.title}}: {{@this}}{{/each}}",
    "{{#each rows}}{{#if @this.active}}[{{@this.name}}]{{/if}}{{/each}}",
    # Literal variable keys: bracket segments + uppercase block params
    "{{[first-name]}}",
    "{{user.[first-name]}}",
    "{{[a.b]}}",
    "{{#each people as |p _ I1|}}{{I1}}:{{p.[first-name]}} {{/each}}",
    "{{#each rows as |_ _ i1|}}{{i1}} {{/each}}",
    "{{#each rows}}{{@this.[full name]}}{{/each}}",
    "{{#with user as |u|}}{{u.[full name]}}{{/with}}",
    "{{default [my name] \"?\"}}",
    # Transformers and pipelines
    "{{name | upcase}}",
    "{{name | upcase | trim}}",
    "{{text | truncate 20}}",
    "{{items | join \", \"}}",
    "{{upcase name}}",
    "{{default user.name \"anon\"}}",
    "{{truncate text 20}}",
    "{{default (upcase name) \"X\"}}",
    "{{link url text=label}}",
    "{{x | wrap tag=\"b\"}}",
    "{{#each items}}{{@this.name | upcase}}{{/each}}",
    "{{42}} {{-3}} {{true}} {{null}}",
    # Single-quoted strings lower to the same value as double-quoted ones.
    "{{'single'}}",
    "{{'a quoted phrase'}}",
    "{{default missing 'fallback'}}",
    # Comments and whitespace-control trim markers
    "a {{~ x ~}} b",
    "a {{! c }} b",
    "{{!-- c --}}x",
    "a {{x ~}}   b",
    "{{#each items}}{{@this}}{{~/each}}",
    # Regions and yields
    "{{#region head}}H{{/region}}before{{yield head}}after",
    "{{yield undefined}}",
    "{{#region row}}{{@this.name}}{{/region}}{{#each rows}}{{yield row}};{{/each}}",
    # Not yet ported — should be reported as pending, not mismatched.
    # (A string with escape sequences still compiles on the BEAM, so it
    # exercises the pending bucket.)
    "{{\"a\\tb\"}}"
  ]

  # `{entry, %{name => source}}` cases exercising `{{> partial}}` expansion,
  # including Handlebars-style partial arguments (context + hash).
  @partial_cases [
    {"{{> greeting}}", %{"greeting" => "Hi {{name}}!"}},
    {"{{> header}}<ul>{{#each items}}{{> row}}{{/each}}</ul>",
     %{"header" => "<h1>{{title}}</h1>", "row" => "<li>{{@this.name}}</li>"}},
    {"{{> card user}}", %{"card" => "{{name}}"}},
    {~s({{> badge label="VIP"}}), %{"badge" => "[{{label}}]"}},
    {~s({{> card user role="admin"}}), %{"card" => "{{name}} ({{role}})"}},
    {"{{#each users}}{{> card @this}}{{/each}}", %{"card" => "[{{name}}]"}}
  ]

  # The reserved boolean operators `||`/`&&`. Both compilers must refuse these at
  # compile time (maximal munch, spaced or not). This path is unreachable from the
  # render harness — `mix stem.native.fuzz` compiles on the BEAM before the native
  # engine renders — so reserved-operator parity is gated here. A template that
  # compiles on one backend while erroring on the other is the parser-differential
  # bug this gate exists to catch.
  @reserved_templates [
    "{{a || b}}",
    "{{a||b}}",
    "{{a && b}}",
    "{{a&&b}}",
    "{{name | a && b}}",
    "{{name | a || b}}"
  ]

  # Multi-error templates for accumulation parity. Both compilers must report
  # *every* recoverable error, in source order, each attributed to the file
  # ("main" or a partial) it occurred in. The exact wording is backend-specific
  # (the BEAM and Rust phrase some errors differently), so the gate compares the
  # ordered list of files each error lands in — the conceptual invariant.
  @multi_error_cases [
    {"{{ a + b }} {{ c || d }}", %{}},
    {"{{> missing}} {{ a + b }}", %{}},
    {"{{> inner}}", %{"inner" => "{{ a + b }} {{ x && y }}"}},
    {"{{ a + b }} {{> inner}}", %{"inner" => "{{ c || d }}"}}
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("compile")
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: [engine: :string, wasm: :string])
    engine = Engine.resolve(opts)

    # Each case is `{template, partials}`; plain templates carry an empty map.
    cases = Enum.map(@templates, &{&1, %{}}) ++ @partial_cases

    beam = Enum.map(cases, fn {template, partials} -> beam_wire(template, partials) end)
    rust = Engine.compile_batch(engine, Enum.map(cases, &compile_request/1))

    results =
      [cases, beam, rust]
      |> Enum.zip()
      |> Enum.map(fn {{template, _partials}, beam_wire, rust_wire} ->
        classify(template, beam_wire, rust_wire)
      end)

    report(engine, results, reserved_results(engine), error_results(engine))
  end

  # Accumulation parity: every recoverable error, in source order, attributed to
  # the same file on both backends. `Stem.Parser.parse_all/2` gives the BEAM
  # list; the native engine returns `%{"errors" => [...]}`. Compared by the
  # ordered file list (messages are phrased differently per backend).
  defp error_results(engine) do
    rust = Engine.compile_batch(engine, Enum.map(@multi_error_cases, &compile_request/1))

    [@multi_error_cases, rust]
    |> Enum.zip()
    |> Enum.map(fn {{template, partials}, rust_wire} ->
      beam_files =
        case Stem.Parser.parse_all(template, partials: partials) do
          {:error, errors} -> Enum.map(errors, & &1.file)
          {:ok, _} -> []
        end

      rust_files =
        case rust_wire do
          %{"errors" => errors} -> Enum.map(errors, &Map.get(&1, "file"))
          _ -> []
        end

      {template, beam_files, rust_files}
    end)
  end

  # `||`/`&&` must be refused by both compilers at compile time. The BEAM parser
  # returns `{:error, _}`; the native compiler returns an `%{"error" => _}` map.
  # Each template must error on *both* backends — one accepting while the other
  # refuses would be a parser divergence.
  defp reserved_results(engine) do
    rust = Engine.compile_batch(engine, @reserved_templates)

    [@reserved_templates, rust]
    |> Enum.zip()
    |> Enum.map(fn {template, rust_wire} ->
      # `parse_with_spans/1` returns `{:ok, ast}` or `{:error, message, meta}`.
      beam_refused = elem(Stem.Parser.parse_with_spans(template), 0) == :error
      rust_refused = match?(%{"errors" => _}, rust_wire)
      {template, beam_refused, rust_refused}
    end)
  end

  # A bare source string when there are no partials, else a `{template, partials}`
  # object — both shapes are accepted by the native `compile_batch` handler.
  defp compile_request({template, partials}) when map_size(partials) == 0, do: template

  defp compile_request({template, partials}),
    do: %{"template" => template, "partials" => partials}

  defp beam_wire(template, partials) do
    {:ok, ast} = Stem.Parser.parse_with_spans(template, partials: partials)
    ast |> Stem.Bytecode.compile() |> Stem.Bytecode.to_wire()
  end

  defp classify(template, _beam_wire, %{"errors" => _} = _rust_wire), do: {:pending, template}

  defp classify(template, beam_wire, rust_wire) do
    if beam_wire == rust_wire,
      do: {:match, template},
      else: {:mismatch, template, beam_wire, rust_wire}
  end

  defp report(engine, results, reserved, errors) do
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

    reserved_failures =
      Enum.reject(reserved, fn {_template, beam_refused, rust_refused} ->
        beam_refused and rust_refused
      end)

    Enum.each(reserved_failures, fn {template, beam_refused, rust_refused} ->
      Mix.shell().error(
        "  ✗ reserved #{inspect(template)} — refused on beam: #{beam_refused}, rust: #{rust_refused}"
      )
    end)

    Mix.shell().info(
      "Compile parity: #{matched} matched, #{pending} pending (not yet ported), " <>
        "#{length(mismatches)} mismatched of #{length(results)} templates."
    )

    Mix.shell().info(
      "Reserved-operator parity: #{length(reserved) - length(reserved_failures)}/" <>
        "#{length(reserved)} refused on both backends."
    )

    error_failures =
      Enum.reject(errors, fn {_template, beam_files, rust_files} -> beam_files == rust_files end)

    Enum.each(error_failures, fn {template, beam_files, rust_files} ->
      Mix.shell().error(
        "  ✗ error accumulation #{inspect(template)}\n" <>
          "    beam files: #{inspect(beam_files)}\n" <>
          "    rust files: #{inspect(rust_files)}"
      )
    end)

    Mix.shell().info(
      "Error-accumulation parity: #{length(errors) - length(error_failures)}/" <>
        "#{length(errors)} templates report the same errors (count + file) on both backends."
    )

    divergences = length(mismatches) + length(reserved_failures) + length(error_failures)

    unless divergences == 0 do
      Mix.raise("Native compile parity failed: #{divergences} divergence(s).")
    end
  end
end
