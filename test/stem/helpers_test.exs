# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.HelpersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Stem.Helpers

  setup do
    Helpers.clear()
    :ok
  end

  test "register, invoke, and unregister a helper" do
    Helpers.register(:up, fn [value], _ctx -> String.upcase(value) end)
    assert Helpers.invoke(:up, ["nina"], []) == "NINA"

    Helpers.unregister(:up)

    assert_raise Stem.SyntaxError, ~r/unknown helper 'up'/, fn ->
      Helpers.invoke(:up, ["nina"], [])
    end
  end

  test "helpers can be registered under a string name" do
    Helpers.register("up", fn [value], _ctx -> String.upcase(value) end)
    assert Helpers.invoke(:up, ["nina"], []) == "NINA"
  end

  test "local helpers passed as a keyword list or map override the registry" do
    assert Helpers.invoke(:x, ["a"], helpers: [x: fn [v], _ -> v <> "!" end]) == "a!"
    assert Helpers.invoke(:x, ["a"], helpers: %{x: fn [v], _ -> v <> "?" end}) == "a?"
  end

  test "helpers receive the current each-item context" do
    Helpers.register(:wrap, fn [value], %{this: this} -> "#{value}:#{this}" end)
    assert Helpers.invoke(:wrap, ["item"], this: 5) == "item:5"
  end

  describe "builtin lookup" do
    test "fetches map values by atom or string key" do
      assert Helpers.invoke(:lookup, [%{a: 1}, :a], []) == 1
      assert Helpers.invoke(:lookup, [%{"a" => 1}, "a"], []) == 1
    end

    test "falls back to a stringified key for maps" do
      assert Helpers.invoke(:lookup, [%{"a" => 1}, :a], []) == 1
    end

    test "fetches list values by index" do
      assert Helpers.invoke(:lookup, [["a", "b"], 1], []) == "b"
    end

    test "returns nil for unsupported collections" do
      assert Helpers.invoke(:lookup, [123, :a], []) == nil
    end
  end

  describe "builtin log" do
    test "writes positional and keyword arguments to stderr and returns empty output" do
      stderr =
        capture_io(:stderr, fn ->
          assert Helpers.invoke(:log, ["hello", {:level, "debug"}], []) == ""
        end)

      assert stderr =~ "hello level=debug"
    end
  end
end
