# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.SmartEngineTest do
  use ExUnit.Case, async: true

  test "evaluates simple string" do
    assert_eval("foo bar", "foo bar")
  end

  test "evaluates with assigns as keywords" do
    assert_eval("1", "{{foo}}", assigns: [foo: 1])
  end

  test "evaluates with assigns as a map" do
    assert_eval("1", "{{foo}}", assigns: %{foo: 1})
  end

  test "missing assigns are silent by default" do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_eval("", "{{foo}}", assigns: %{})
      end)

    assert stderr == ""
  end

  test "missing assigns can warn when enabled" do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Stem.TestTemplate.eval_string("{{foo}}", [assigns: %{}],
                 file: __ENV__.file,
                 engine: Stem.SmartEngine,
                 warn_on_missing_assigns: true
               ) == ""
      end)

    assert stderr =~ "assign @foo not available in Stem template"
  end

  test "evaluates with loops" do
    assert_eval("1\n2\n3\n", "{{#each values}}{{this}}\n{{/each}}", assigns: [values: [1, 2, 3]])
  end

  test "preserves line numbers in assignments" do
    result = Stem.__compile_string__("foo\n{{hello}}", engine: Stem.SmartEngine)

    Macro.prewalk(result, fn
      {{:., _, [{:__aliases__, _, [:Stem, :Engine]}, :fetch_assign!]}, meta, [_, :hello, false]} ->
        assert Keyword.get(meta, :line) == 2
        send(self(), :found)

      node ->
        node
    end)

    assert_received :found
  end

  defp assert_eval(expected, actual, binding \\ []) do
    result =
      Stem.TestTemplate.eval_string(actual, binding,
        file: __ENV__.file,
        engine: Stem.SmartEngine
      )

    assert result == expected
  end
end
