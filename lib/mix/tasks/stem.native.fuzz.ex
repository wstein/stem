# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Stem.Native.Fuzz do
  use Mix.Task

  @shortdoc "Differential fuzz: random templates rendered on the BEAM vs the native engine"

  @moduledoc """
  Generates random Stem templates over a matchable grammar and asserts the
  native (Rust/WASM) engine renders each byte-for-byte identically to the BEAM
  reference. The BEAM is the oracle.

  The generator stays within the value/transformer space whose parity is
  deterministic under random input: ASCII strings, integers, floats (across a
  wide range of magnitudes), and the Strings, Collections and Predicates groups.
  `json`/`inspect` are covered by the fixed conformance corpus instead (for
  `inspect`, parity is bounded to non-map values), and `i18n` is host-delegated.
  So any divergence here is a real engine bug, not an out-of-scope construct.

  ## Usage

      mix stem.native.fuzz                 # 200 cases, random seed
      mix stem.native.fuzz --count 1000
      mix stem.native.fuzz --seed 42       # reproduce a run
      mix stem.native.fuzz --engine "native/stem_native/target/release/stem_native"
  """

  alias Stem.Native.Engine

  @impl true
  def run(argv) do
    Mix.Task.run("compile")

    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [engine: :string, wasm: :string, count: :integer, seed: :integer]
      )

    engine = Engine.resolve(opts)
    count = opts[:count] || 200
    seed = opts[:seed] || :erlang.system_time(:microsecond)
    :rand.seed(:exsss, {seed, seed, seed})

    transformers =
      Stem.Transformers.Standard.all()
      |> Map.merge(Stem.Transformers.Collections.all())
      |> Map.merge(Stem.Transformers.Predicates.all())

    # The same groups, by name, for the native engine's capability gate.
    groups = ~w(minimum strings collections predicates)

    cases = for _ <- 1..count, do: gen_case()

    expected =
      Enum.map(cases, fn {template, data} -> render_oracle(template, data, transformers) end)

    requests =
      Enum.map(cases, fn {template, data} -> Engine.request(template, data, :html, groups) end)

    actuals = Engine.render_batch(engine, requests)

    failures =
      [cases, expected, actuals]
      |> Enum.zip()
      |> Enum.filter(fn {_case, exp, act} -> exp != act end)

    report(engine, seed, count, failures)
  end

  # The BEAM oracle. A render-time refusal (e.g. an arity mismatch) is normalized
  # to the native engine's "stem_native error: " sentinel so error cases compare
  # for parity exactly like successful renders.
  defp render_oracle(template, data, transformers) do
    quoted = Stem.compile_string(template, escape: :html)
    {result, _binding} = Code.eval_quoted(quoted, assigns: data, transformers: transformers)
    result
  rescue
    e in Stem.SyntaxError -> "stem_native error: " <> Exception.message(e)
  end

  defp report(engine, seed, count, []) do
    Mix.shell().info("Native engine: #{engine}")
    Mix.shell().info("Fuzz: #{count}/#{count} random templates match the BEAM (seed #{seed}).")
  end

  defp report(_engine, seed, count, failures) do
    Enum.take(failures, 5)
    |> Enum.each(fn {{template, data}, exp, act} ->
      Mix.shell().error(
        "  ✗ template: #{inspect(template)}\n    data:     #{inspect(data)}\n" <>
          "    expected: #{inspect(exp)}\n    actual:   #{inspect(act)}"
      )
    end)

    Mix.raise(
      "Native fuzz failed: #{length(failures)}/#{count} diverged (seed #{seed}; " <>
        "rerun with --seed #{seed} to reproduce)."
    )
  end

  # ── Template generator (matchable grammar) ───────────────────────────────────

  defp gen_case do
    data = %{
      s: maybe_special(ascii(0..10)),
      n: rand_int(0..999),
      f: rand_float(),
      flag: Enum.random([true, false]),
      items: gen_list(0..5, fn -> ascii(1..6) end),
      nums: gen_list(0..5, fn -> rand_int(0..50) end),
      words: gen_list(0..5, fn -> ascii(1..5) end),
      rows: gen_list(0..4, fn -> %{name: ascii(1..5), age: rand_int(0..80)} end),
      obj: %{k: ascii(1..6), v: rand_int(0..9)}
    }

    template = for _ <- 1..rand_int(1..5), into: "", do: segment()
    {template, data}
  end

  defp segment do
    case rand_int(0..18) do
      0 -> literal()
      1 -> "{{s}}"
      2 -> "{{{s}}}"
      3 -> "{{s | #{string_pipeline()}}}"
      4 -> "{{n}}"
      5 -> "{{flag}}"
      6 -> "{{items | join #{quoted(separator())}}}"
      7 -> "{{nums | sort | join \",\"}}"
      8 -> "{{words | sort | reverse | join \"-\"}}"
      9 -> "{{items | uniq | join \"/\"}}"
      10 -> "{{items | first}}"
      11 -> "{{rows | map \"name\" | join \" \"}}"
      12 -> "{{contains words #{quoted(ascii(1..3))}}}"
      13 -> "{{#if flag}}#{literal()}{{else}}#{literal()}{{/if}}"
      14 -> "{{#each items}}{{this | upcase}};{{/each}}"
      15 -> "{{#each rows as |r i0 i1|}}{{i0}}/{{i1}}:{{r.name}};{{/each}}"
      16 -> "{{#with obj as |o|}}{{o.k}}={{o.v}}{{/with}}"
      # Exercises float rendering across magnitudes (the `:short` format the
      # native core reproduces — gap G2).
      17 -> "{{f}}"
      # Render-time arity violation: a built-in called with the wrong number of
      # arguments must refuse identically on both engines (the subject counts as
      # the first argument), so the error sentinels compare byte-for-byte.
      18 -> arity_violation()
    end
  end

  # A built-in invoked outside its arity range. The subject is the first
  # argument, so each of these over- or under-fills a known range; both backends
  # raise the same uniform message, normalized to the native sentinel in
  # `render_oracle/3`.
  defp arity_violation do
    Enum.random([
      ~s({{s | upcase "x"}}),
      ~s({{s | truncate}}),
      ~s({{items | first "x"}}),
      ~s({{items | join "," "y" "z"}}),
      ~s({{nums | sort "x"}}),
      ~s({{words | reverse "x"}})
    ])
  end

  # A float spanning a wide range of magnitudes (positive and negative
  # exponents) to stress the decimal/scientific notation boundary.
  defp rand_float do
    mantissa = :rand.uniform() * Enum.random([1, -1])
    mantissa * :math.pow(10, rand_int(-8..21))
  end

  defp string_pipeline do
    stages = ~w(upcase downcase trim capitalize reverse)
    chosen = for _ <- 1..rand_int(1..3), do: Enum.random(stages)
    chosen = if rand_int(0..1) == 1, do: chosen ++ ["truncate #{rand_int(0..8)}"], else: chosen
    Enum.join(chosen, " | ")
  end

  # `1..0//1` is an empty range, so a count of 0 yields an empty list.
  defp gen_list(range, fun), do: for(_ <- 1..rand_int(range)//1, do: fun.())

  defp ascii(range) do
    alphabet = ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    for _ <- 1..rand_int(range)//1, into: "", do: <<Enum.random(alphabet)>>
  end

  defp literal do
    alphabet = ~c"abcdefghijklmnopqrstuvwxyz0123456789 "
    for _ <- 1..rand_int(0..6)//1, into: "", do: <<Enum.random(alphabet)>>
  end

  defp maybe_special(s) do
    case rand_int(0..3) do
      0 -> s <> "<b>&\"'"
      _ -> s
    end
  end

  defp separator, do: Enum.random([", ", "-", "/", ""])
  defp quoted(s), do: ~s("#{s}")
  defp rand_int(low..high//_), do: low + :rand.uniform(high - low + 1) - 1
end
