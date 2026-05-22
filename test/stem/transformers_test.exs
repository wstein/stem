# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.TransformersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Stem.Transformers

  setup do
    Transformers.clear()
    :ok
  end

  test "register, invoke, and unregister a transformer" do
    Transformers.register(:up, fn [value], _ctx -> String.upcase(value) end)
    assert Transformers.invoke(:up, ["nina"], []) == "NINA"

    Transformers.unregister(:up)

    assert_raise Stem.SyntaxError, ~r/unknown transformer 'up'/, fn ->
      Transformers.invoke(:up, ["nina"], [])
    end
  end

  test "transformers can be registered under a string name" do
    Transformers.register("up", fn [value], _ctx -> String.upcase(value) end)
    assert Transformers.invoke(:up, ["nina"], []) == "NINA"
  end

  test "transformers passed as a keyword list or map override the registry" do
    assert Transformers.invoke(:x, ["a"], transformers: [x: fn [v], _ -> v <> "!" end]) == "a!"
    assert Transformers.invoke(:x, ["a"], transformers: %{x: fn [v], _ -> v <> "?" end}) == "a?"
  end

  test "transformers receive the current each-item context" do
    Transformers.register(:wrap, fn [value], %{this: this} -> "#{value}:#{this}" end)
    assert Transformers.invoke(:wrap, ["item"], this: 5) == "item:5"
  end

  describe "builtin lookup" do
    test "fetches map values by atom or string key" do
      assert Transformers.invoke(:lookup, [%{a: 1}, :a], []) == 1
      assert Transformers.invoke(:lookup, [%{"a" => 1}, "a"], []) == 1
    end

    test "falls back to a stringified key for maps" do
      assert Transformers.invoke(:lookup, [%{"a" => 1}, :a], []) == 1
    end

    test "fetches list values by index" do
      assert Transformers.invoke(:lookup, [["a", "b"], 1], []) == "b"
    end

    test "returns nil for unsupported collections" do
      assert Transformers.invoke(:lookup, [123, :a], []) == nil
    end
  end

  describe "builtin log" do
    test "writes positional and keyword arguments to stderr and returns empty output" do
      stderr =
        capture_io(:stderr, fn ->
          assert Transformers.invoke(:log, ["hello", {:level, "debug"}], []) == ""
        end)

      assert stderr =~ "hello level=debug"
    end
  end

  describe "builtin sanitize transformers" do
    test "escape_html escapes common HTML-sensitive characters" do
      assert Transformers.invoke(:escape_html, [~s(<b>&"')], []) == "&lt;b&gt;&amp;&quot;&#39;"
    end

    test "strip_tags and normalize_space are not built-ins" do
      assert_raise Stem.SyntaxError, ~r/unknown transformer 'strip_tags'/, fn ->
        Transformers.invoke(:strip_tags, ["<p>Hello <b>Nina</b></p>"], [])
      end

      assert_raise Stem.SyntaxError, ~r/unknown transformer 'normalize_space'/, fn ->
        Transformers.invoke(:normalize_space, ["  Hello\n\tNina  "], [])
      end
    end
  end

  describe "builtin transform functions" do
    test "builtins raise helpful arity errors" do
      cases = [
        {:default, [1], ~r/default expects 2 arguments/},
        {:join, [1, 2, 3], ~r/join expects 1 or 2 arguments/},
        {:inspect, [], ~r/inspect expects 1 argument/},
        {:json, [1, 2], ~r/json expects 1 argument/},
        {:escape_json, [], ~r/escape_json expects 1 argument/},
        {:trim, [1, 2], ~r/trim expects 1 argument/},
        {:upcase, [1, 2], ~r/upcase expects 1 argument/},
        {:downcase, [1, 2], ~r/downcase expects 1 argument/},
        {:capitalize, [1, 2], ~r/capitalize expects 1 argument/},
        {:truncate, [1], ~r/truncate expects 2 or 3 arguments/},
        {:replace, [1, 2], ~r/replace expects 3 arguments/},
        {:starts_with, [1], ~r/starts_with expects 2 arguments/},
        {:ends_with, [1], ~r/ends_with expects 2 arguments/},
        {:contains, [1], ~r/contains expects 2 arguments/},
        {:empty?, [1, 2], ~r/empty\? expects 1 argument/},
        {:present?, [1, 2], ~r/present\? expects 1 argument/},
        {:compact, [1, 2], ~r/compact expects 1 argument/},
        {:map, [1], ~r/map expects 2 arguments/},
        {:filter, [1, 2, 3], ~r/filter expects 1 or 2 arguments/},
        {:sort, [1, 2], ~r/sort expects 1 argument/},
        {:sort_by, [1], ~r/sort_by expects 2 arguments/},
        {:group_by, [1], ~r/group_by expects 2 arguments/},
        {:take, [1], ~r/take expects 2 arguments/},
        {:drop, [1], ~r/drop expects 2 arguments/},
        {:slice, [1, 2], ~r/slice expects 3 arguments/},
        {:first, [1, 2], ~r/first expects 1 argument/},
        {:uniq, [1, 2], ~r/uniq expects 1 argument/},
        {:flatten, [1, 2], ~r/flatten expects 1 argument/},
        {:reverse, [1, 2], ~r/reverse expects 1 argument/}
      ]

      Enum.each(cases, fn {name, args, message} ->
        assert_raise ArgumentError, message, fn ->
          Transformers.invoke(name, args, [])
        end
      end)
    end

    test "string transforms and defaults" do
      assert Transformers.invoke(:trim, ["  Nina  "], []) == "Nina"
      assert Transformers.invoke(:upcase, ["Nina"], []) == "NINA"
      assert Transformers.invoke(:downcase, ["Nina"], []) == "nina"
      assert Transformers.invoke(:capitalize, ["nina"], []) == "Nina"
      assert Transformers.invoke(:replace, ["stem", "e", "a"], []) == "stam"
      assert Transformers.invoke(:truncate, ["stem", 3], []) == "ste"
      assert Transformers.invoke(:truncate, ["stem", 3, ".."], []) == "s.."
      assert Transformers.invoke(:default, [nil, "fallback"], []) == "fallback"
      assert Transformers.invoke(:default, ["value", "fallback"], []) == "value"
    end

    test "json and inspect transformers serialize values" do
      assert Transformers.invoke(:inspect, [%{a: 1}], []) == "%{a: 1}"
      assert Transformers.invoke(:json, [%{a: 1}], []) == ~s({"a":1})
      assert Transformers.invoke(:escape_json, [~s(a"b)], []) == "a\\\"b"
    end

    test "predicates cover strings, maps, and lists" do
      assert Transformers.invoke(:contains, [["a", "b"], "a"], [])
      assert Transformers.invoke(:contains, [%{name: "Nina"}, :name], [])
      assert Transformers.invoke(:contains, ["stem", "te"], [])
      refute Transformers.invoke(:contains, [123, :name], [])
      assert Transformers.invoke(:empty?, [[]], [])
      refute Transformers.invoke(:empty?, [[1]], [])
      refute Transformers.invoke(:empty?, [0], [])
      assert Transformers.invoke(:present?, [[1]], [])
      refute Transformers.invoke(:present?, [%{}], [])
      assert Transformers.invoke(:starts_with, ["stem", "st"], [])
      assert Transformers.invoke(:ends_with, ["stem", "em"], [])
    end

    test "collection transformers support declarative selectors" do
      rows = [%{name: "b", active: true}, %{name: "a", active: false}, %{name: "c", active: true}]

      assert Transformers.invoke(:map, [rows, "name"], []) == ["b", "a", "c"]

      assert Transformers.invoke(:filter, [rows, "active"], []) == [
               %{name: "b", active: true},
               %{name: "c", active: true}
             ]

      assert Transformers.invoke(:sort_by, [rows, "name"], []) == [
               %{name: "a", active: false},
               %{name: "b", active: true},
               %{name: "c", active: true}
             ]

      assert Transformers.invoke(:group_by, [rows, "active"], []) == %{
               false => [%{name: "a", active: false}],
               true => [%{name: "b", active: true}, %{name: "c", active: true}]
             }

      assert Transformers.invoke(:map, [[%{"name" => "nina"}], "name"], []) == ["nina"]
      assert Transformers.invoke(:map, [[%{name: "nina"}], :name], []) == ["nina"]
      assert Transformers.invoke(:map, [[%{1 => "one"}], 1], []) == ["one"]
      assert Transformers.invoke(:map, [[["a", "b"]], "1"], []) == ["b"]
      assert Transformers.invoke(:map, [[["a", "b"]], 1], []) == ["b"]
      assert Transformers.invoke(:map, [[["a", "b"]], "x"], []) == [nil]
      assert Transformers.invoke(:map, [[:atom_entry], "name"], []) == [nil]
      assert Transformers.invoke(:map, [[%{other: "x"}], "name"], []) == [nil]
    end

    test "list and string transformers support common sequence operations" do
      assert Transformers.invoke(:join, [["a", "b"], ","], []) == "a,b"
      assert Transformers.invoke(:join, [["a", "b"]], []) == "ab"
      assert Transformers.invoke(:compact, [[1, nil, 2]], []) == [1, 2]
      assert Transformers.invoke(:compact, [nil], []) == []
      assert Transformers.invoke(:sort, [[3, 1, 2]], []) == [1, 2, 3]
      assert Transformers.invoke(:sort, [%{a: 2, b: 1}], []) == [1, 2]
      assert Transformers.invoke(:filter, [[true, false, nil, 0, ""]], []) == [true]
      assert Transformers.invoke(:take, [[1, 2, 3], 2], []) == [1, 2]
      assert Transformers.invoke(:take, [[1, 2, 3], "2"], []) == [1, 2]
      assert Transformers.invoke(:take, [7, 1], []) == [7]
      assert Transformers.invoke(:drop, [[1, 2, 3], 1], []) == [2, 3]
      assert Transformers.invoke(:slice, [[1, 2, 3], 1, 2], []) == [2, 3]
      assert Transformers.invoke(:first, [[1, 2, 3]], []) == 1
      assert Transformers.invoke(:first, [7], []) == 7
      assert Transformers.invoke(:uniq, [[1, 1, 2]], []) == [1, 2]
      assert Transformers.invoke(:flatten, [[[1], [2, [3]]]], []) == [1, 2, 3]
      assert Transformers.invoke(:reverse, [[1, 2, 3]], []) == [3, 2, 1]
      assert Transformers.invoke(:take, ["stem", 2], []) == "st"
      assert Transformers.invoke(:drop, ["stem", 2], []) == "em"
      assert Transformers.invoke(:slice, ["stem", 1, 2], []) == "te"
      assert Transformers.invoke(:first, ["stem"], []) == "s"
      assert Transformers.invoke(:reverse, ["stem"], []) == "mets"

      assert_raise ArgumentError, ~r/take expects integer arguments/, fn ->
        Transformers.invoke(:take, [[1, 2, 3], "nope"], [])
      end
    end
  end
end
