# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.InspectTest do
  use ExUnit.Case, async: true

  alias Stem.Bytecode
  alias Stem.Bytecode.VM

  # Compile with spans and return the first `:emit` instruction's source meta, so
  # the tests target a span without hardcoding line/column.
  defp emit_target(program) do
    find = fn find, instrs ->
      Enum.find_value(instrs, fn
        {:emit, _op, _escape, meta} -> meta
        {:if, _cond, then_b, else_b} -> find.(find, then_b) || find.(find, else_b)
        {:each, _c, _p, body, else_b} -> find.(find, body) || find.(find, else_b)
        {:with, _s, _p, body, else_b} -> find.(find, body) || find.(find, else_b)
        {:scope, _b, _h, body} -> find.(find, body)
        _ -> nil
      end)
    end

    meta = find.(find, program.instructions)
    Map.take(meta, [:line, :column])
  end

  defp program_with_spans(source) do
    {:ok, ast} = Stem.Parser.parse_with_spans(source)
    Bytecode.compile(ast, spans: true)
  end

  test "captures one snapshot per loop iteration" do
    program = program_with_spans("{{#each items}}{{name}}{{/each}}")
    target = emit_target(program)

    snaps =
      VM.inspect_at(program, [assigns: [items: [%{name: "a"}, %{name: "b"}]]], target)

    assert length(snaps) == 2
    assert Enum.at(snaps, 0).this == %{name: "a"}
    assert Enum.at(snaps, 0).index == 0
    assert Enum.at(snaps, 0).index1 == 1
    assert Enum.at(snaps, 0).first == true
    assert Enum.at(snaps, 0).parent == [items: [%{name: "a"}, %{name: "b"}]]
    assert Enum.at(snaps, 1).this == %{name: "b"}
    assert Enum.at(snaps, 1).last == true
  end

  test "top-level snapshot has nil iteration vars" do
    program = program_with_spans("Hi {{user.name}}!")
    target = emit_target(program)

    snaps = VM.inspect_at(program, [assigns: [user: %{name: "Nina"}]], target)

    assert length(snaps) == 1
    snap = hd(snaps)
    assert snap.this == [user: %{name: "Nina"}]
    assert snap.root == [user: %{name: "Nina"}]
    assert snap.index == nil
    assert snap.index1 == nil
    assert snap.first == nil
  end

  test "an unreached span yields no snapshots" do
    program = program_with_spans("{{#if shown}}{{name}}{{/if}}")
    target = emit_target(program)

    assert VM.inspect_at(program, [assigns: [shown: false, name: "hidden"]], target) == []
  end

  test "without :spans there is nothing to target" do
    {:ok, ast} = Stem.Parser.parse_with_spans("{{name}}")
    program = Bytecode.compile(ast)
    assert VM.inspect_at(program, [assigns: [name: "x"]], %{line: 1, column: 1}) == []
  end
end
