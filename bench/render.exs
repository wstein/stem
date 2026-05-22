# SPDX-License-Identifier: Apache-2.0
#
# Render-throughput benchmark: production compiled backend vs. bytecode VM.
#
#     mix run bench/render.exs
#
# This is the measured signal that gates Phase 2 of the native-backend plan
# (see notes/Native Backend Strategy.md). The compiled backend lowers a template
# to a BEAM function; the bytecode VM interprets a portable program. A native
# (Rust/WASM) core would have to beat the *compiled* path to be worth building
# for a BEAM host — so this compares the two compile-once, render-many.

defmodule Bench.Compiled do
  @moduledoc false
  require Stem

  @small "Hello {{name}}, you have {{count}} messages."
  @loop "<ul>{{#each items}}<li>{{this}}</li>{{/each}}</ul>"

  Stem.function_from_string(:def, :small, @small, [:assigns])
  Stem.function_from_string(:def, :loop, @loop, [:assigns])

  def small_source, do: @small
  def loop_source, do: @loop
end

defmodule Bench do
  @moduledoc false

  def parse(source) do
    {:ok, ast} = Stem.Parser.parse_with_spans(source)
    ast
  end

  def measure(iterations, fun) do
    fun.()
    {micros, _} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> fun.() end) end)
    micros / iterations
  end

  def report(label, iterations, fun) do
    per_op = measure(iterations, fun)
    ips = Float.round(1_000_000 / per_op, 0)
    :io.format(~c"  ~-34ts ~10.3f µs/op  ~12w ops/s~n", [label, per_op, trunc(ips)])
    per_op
  end
end

small_assigns = [name: "Nina", count: 7]
loop_assigns = [items: Enum.map(1..200, &"item-#{&1}")]

small_program = Bench.Compiled.small_source() |> Bench.parse() |> Stem.Bytecode.compile()
loop_program = Bench.Compiled.loop_source() |> Bench.parse() |> Stem.Bytecode.compile()

IO.puts("\nRender throughput (compile once, render many)\n")

IO.puts("small template:")
compiled_small = Bench.report("compiled backend", 200_000, fn -> Bench.Compiled.small(small_assigns) end)
vm_small = Bench.report("bytecode VM", 200_000, fn -> Stem.Bytecode.VM.render(small_program, assigns: small_assigns) end)

IO.puts("\nloop template (200 items):")
compiled_loop = Bench.report("compiled backend", 20_000, fn -> Bench.Compiled.loop(loop_assigns) end)
vm_loop = Bench.report("bytecode VM", 20_000, fn -> Stem.Bytecode.VM.render(loop_program, assigns: loop_assigns) end)

IO.puts("\ncompile cost (one-time, per template):")
Bench.report("compiled (parse + lower to quoted)", 20_000, fn ->
  Stem.compile_string(Bench.Compiled.small_source())
end)

Bench.report("bytecode (parse + lower to program)", 20_000, fn ->
  Bench.Compiled.small_source() |> Bench.parse() |> Stem.Bytecode.compile()
end)

ratio = fn vm, compiled -> Float.round(vm / compiled, 1) end

IO.puts("""

Summary
  The compiled backend renders #{ratio.(vm_small, compiled_small)}x faster (small) and \
#{ratio.(vm_loop, compiled_loop)}x faster (loop) than the bytecode VM.
  On the BEAM the compiled path has no serialization boundary and runs as native
  BEAM code, so it sets the bar a native core would have to beat. There is no
  measured BEAM perf case for a Rust/WASM backend; pursue it only for a non-BEAM
  or edge consumer. See notes/Native Backend Strategy.md.
""")
