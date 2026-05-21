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

  describe "builtin sanitize helpers" do
    test "html escapes common HTML-sensitive characters" do
      assert Helpers.invoke(:html, [~s(<b>&"')], []) == "&lt;b&gt;&amp;&quot;&#39;"
    end

    test "strip_tags and normalize_space are not built-ins" do
      assert_raise Stem.SyntaxError, ~r/unknown helper 'strip_tags'/, fn ->
        Helpers.invoke(:strip_tags, ["<p>Hello <b>Nina</b></p>"], [])
      end

      assert_raise Stem.SyntaxError, ~r/unknown helper 'normalize_space'/, fn ->
        Helpers.invoke(:normalize_space, ["  Hello\n\tNina  "], [])
      end
    end
  end

  describe "builtin transform helpers" do
    test "string transforms and defaults" do
      assert Helpers.invoke(:trim, ["  Nina  "], []) == "Nina"
      assert Helpers.invoke(:upcase, ["Nina"], []) == "NINA"
      assert Helpers.invoke(:downcase, ["Nina"], []) == "nina"
      assert Helpers.invoke(:capitalize, ["nina"], []) == "Nina"
      assert Helpers.invoke(:replace, ["stem", "e", "a"], []) == "stam"
      assert Helpers.invoke(:truncate, ["stem", 3], []) == "ste"
      assert Helpers.invoke(:truncate, ["stem", 3, ".."], []) == "s.."
      assert Helpers.invoke(:default, [nil, "fallback"], []) == "fallback"
      assert Helpers.invoke(:default, ["value", "fallback"], []) == "value"
    end

    test "json and inspect helpers serialize values" do
      assert Helpers.invoke(:inspect, [%{a: 1}], []) == "%{a: 1}"
      assert Helpers.invoke(:json, [%{a: 1}], []) == ~s({"a":1})
      assert Helpers.invoke(:escape_json, [~s(a"b)], []) == "a\\\"b"
    end

    test "predicates cover strings, maps, and lists" do
      assert Helpers.invoke(:contains, [["a", "b"], "a"], [])
      assert Helpers.invoke(:contains, [%{name: "Nina"}, :name], [])
      assert Helpers.invoke(:contains, ["stem", "te"], [])
      assert Helpers.invoke(:empty?, [[]], [])
      refute Helpers.invoke(:empty?, [[1]], [])
      assert Helpers.invoke(:present?, [[1]], [])
      refute Helpers.invoke(:present?, [%{}], [])
      assert Helpers.invoke(:starts_with, ["stem", "st"], [])
      assert Helpers.invoke(:ends_with, ["stem", "em"], [])
    end

    test "collection helpers support declarative selectors" do
      rows = [%{name: "b", active: true}, %{name: "a", active: false}, %{name: "c", active: true}]

      assert Helpers.invoke(:map, [rows, "name"], []) == ["b", "a", "c"]

      assert Helpers.invoke(:filter, [rows, "active"], []) == [
               %{name: "b", active: true},
               %{name: "c", active: true}
             ]

      assert Helpers.invoke(:sort_by, [rows, "name"], []) == [
               %{name: "a", active: false},
               %{name: "b", active: true},
               %{name: "c", active: true}
             ]

      assert Helpers.invoke(:group_by, [rows, "active"], []) == %{
               false => [%{name: "a", active: false}],
               true => [%{name: "b", active: true}, %{name: "c", active: true}]
             }
    end

    test "list and string helpers support common sequence operations" do
      assert Helpers.invoke(:join, [["a", "b"], ","], []) == "a,b"
      assert Helpers.invoke(:compact, [[1, nil, 2]], []) == [1, 2]
      assert Helpers.invoke(:sort, [[3, 1, 2]], []) == [1, 2, 3]
      assert Helpers.invoke(:take, [[1, 2, 3], 2], []) == [1, 2]
      assert Helpers.invoke(:drop, [[1, 2, 3], 1], []) == [2, 3]
      assert Helpers.invoke(:slice, [[1, 2, 3], 1, 2], []) == [2, 3]
      assert Helpers.invoke(:first, [[1, 2, 3]], []) == 1
      assert Helpers.invoke(:uniq, [[1, 1, 2]], []) == [1, 2]
      assert Helpers.invoke(:flatten, [[[1], [2, [3]]]], []) == [1, 2, 3]
      assert Helpers.invoke(:reverse, [[1, 2, 3]], []) == [3, 2, 1]
      assert Helpers.invoke(:take, ["stem", 2], []) == "st"
      assert Helpers.invoke(:drop, ["stem", 2], []) == "em"
      assert Helpers.invoke(:slice, ["stem", 1, 2], []) == "te"
      assert Helpers.invoke(:first, ["stem"], []) == "s"
      assert Helpers.invoke(:reverse, ["stem"], []) == "mets"
    end
  end
end
