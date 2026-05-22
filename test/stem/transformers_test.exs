# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.TransformersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Stem.Transformers

  defp invoke_module_helper(helpers, name, args, ctx \\ %{}) do
    Map.fetch!(helpers, Atom.to_string(name)).(args, ctx)
  end

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

  describe "direct minimum helper module coverage" do
    test "minimum helper map exposes functions and covers success and error branches" do
      helpers = Stem.Transformers.Minimum.all()

      assert Map.keys(helpers) |> Enum.sort() == [
               "default",
               "escape_html",
               "escape_json",
               "inspect",
               "join",
               "json",
               "log",
               "lookup"
             ]

      assert invoke_module_helper(helpers, :lookup, [%{name: "nina"}, :name]) == "nina"
      assert invoke_module_helper(helpers, :lookup, [%{"name" => "nina"}, :name]) == "nina"
      assert invoke_module_helper(helpers, :lookup, [["a", "b"], 1]) == "b"
      assert invoke_module_helper(helpers, :lookup, [["a", "b"], "1"]) == nil
      assert invoke_module_helper(helpers, :lookup, [123, :name]) == nil

      stderr =
        capture_io(:stderr, fn ->
          assert invoke_module_helper(helpers, :log, ["hello", {:level, :debug}]) == ""
        end)

      assert stderr =~ "hello level=debug"

      assert invoke_module_helper(helpers, :escape_html, [~s(<b>&"')]) ==
               "&lt;b&gt;&amp;&quot;&#39;"

      assert invoke_module_helper(helpers, :default, ["value", "fallback"]) == "value"
      assert invoke_module_helper(helpers, :default, [nil, "fallback"]) == "fallback"
      assert invoke_module_helper(helpers, :default, ["", "fallback"]) == "fallback"
      assert invoke_module_helper(helpers, :default, [[1], "fallback"]) == [1]
      assert invoke_module_helper(helpers, :default, [%{}, "fallback"]) == "fallback"
      assert invoke_module_helper(helpers, :default, [false, "fallback"]) == false

      assert invoke_module_helper(helpers, :join, [["a", "b"]]) == "ab"
      assert invoke_module_helper(helpers, :join, [["a", "b"], ","]) == "a,b"
      assert invoke_module_helper(helpers, :join, [%{a: 1, b: 2}, ","])
         |> String.split(",")
         |> Enum.sort() == ["1", "2"]
      assert invoke_module_helper(helpers, :join, [nil, ","]) == ""
      assert invoke_module_helper(helpers, :join, [7, ","]) == "7"

      assert invoke_module_helper(helpers, :inspect, [%{a: 1}]) == "%{a: 1}"
      assert invoke_module_helper(helpers, :json, [%{a: 1}]) == ~s({"a":1})
      assert invoke_module_helper(helpers, :escape_json, [~s(a"b)]) == "a\\\"b"

      assert_raise ArgumentError, ~r/lookup expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :lookup, [1])
      end

      assert_raise ArgumentError, ~r/escape_html expects 1 argument/, fn ->
        invoke_module_helper(helpers, :escape_html, [1, 2])
      end

      assert_raise ArgumentError, ~r/default expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :default, [1])
      end

      assert_raise ArgumentError, ~r/join expects 1 or 2 arguments/, fn ->
        invoke_module_helper(helpers, :join, [1, 2, 3])
      end

      assert_raise ArgumentError, ~r/inspect expects 1 argument/, fn ->
        invoke_module_helper(helpers, :inspect, [])
      end

      assert_raise ArgumentError, ~r/json expects 1 argument/, fn ->
        invoke_module_helper(helpers, :json, [1, 2])
      end

      assert_raise ArgumentError, ~r/escape_json expects 1 argument/, fn ->
        invoke_module_helper(helpers, :escape_json, [])
      end
    end
  end

  describe "direct predicates helper module coverage" do
    test "predicate helpers cover collection types and arity errors" do
      helpers = Stem.Transformers.Predicates.all()

      assert Map.keys(helpers) |> Enum.sort() == ["contains", "empty?", "present?"]

      assert invoke_module_helper(helpers, :contains, ["stem", "te"])
      assert invoke_module_helper(helpers, :contains, [%{name: "nina"}, :name])
      assert invoke_module_helper(helpers, :contains, [%{"name" => "nina"}, :name])
      assert invoke_module_helper(helpers, :contains, [["a", "b"], "a"])
      refute invoke_module_helper(helpers, :contains, [123, :name])

      assert invoke_module_helper(helpers, :empty?, [nil])
      assert invoke_module_helper(helpers, :empty?, [""])
      assert invoke_module_helper(helpers, :empty?, [[]])
      assert invoke_module_helper(helpers, :empty?, [%{}])
      refute invoke_module_helper(helpers, :empty?, ["stem"])
      refute invoke_module_helper(helpers, :empty?, [[1]])
      refute invoke_module_helper(helpers, :empty?, [0])

      assert invoke_module_helper(helpers, :present?, [[1]])
      assert invoke_module_helper(helpers, :present?, [false])
      refute invoke_module_helper(helpers, :present?, [%{}])

      assert_raise ArgumentError, ~r/contains expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :contains, [1])
      end

      assert_raise ArgumentError, ~r/empty\? expects 1 argument/, fn ->
        invoke_module_helper(helpers, :empty?, [1, 2])
      end

      assert_raise ArgumentError, ~r/present\? expects 1 argument/, fn ->
        invoke_module_helper(helpers, :present?, [1, 2])
      end
    end
  end

  describe "direct string helper module coverage" do
    test "string helpers cover main branches and integer normalization" do
      helpers = Stem.Transformers.Strings.all()

      assert Map.keys(helpers) |> Enum.sort() == [
               "capitalize",
               "downcase",
               "drop",
               "ends_with",
               "first",
               "replace",
               "reverse",
               "slice",
               "starts_with",
               "take",
               "trim",
               "truncate",
               "upcase"
             ]

      assert invoke_module_helper(helpers, :trim, ["  Nina  "]) == "Nina"
      assert invoke_module_helper(helpers, :upcase, ["Nina"]) == "NINA"
      assert invoke_module_helper(helpers, :downcase, ["Nina"]) == "nina"
      assert invoke_module_helper(helpers, :capitalize, ["nina"]) == "Nina"
      assert invoke_module_helper(helpers, :truncate, ["stem", 10]) == "stem"
      assert invoke_module_helper(helpers, :truncate, ["stem", 3]) == "ste"
      assert invoke_module_helper(helpers, :truncate, ["stem", 3, ".."]) == "s.."
      assert invoke_module_helper(helpers, :replace, ["stem", "e", "a"]) == "stam"
      assert invoke_module_helper(helpers, :starts_with, ["stem", "st"])
      assert invoke_module_helper(helpers, :ends_with, ["stem", "em"])

      assert invoke_module_helper(helpers, :take, ["stem", 2]) == "st"
      assert invoke_module_helper(helpers, :take, [[1, 2, 3], "2"]) == [1, 2]
      assert invoke_module_helper(helpers, :take, [%{a: 2, b: 1}, 1]) |> length() == 1
      assert invoke_module_helper(helpers, :take, [7, 1]) == [7]
      assert invoke_module_helper(helpers, :drop, ["stem", 2]) == "em"
      assert invoke_module_helper(helpers, :drop, [[1, 2, 3], 1]) == [2, 3]
      assert invoke_module_helper(helpers, :drop, [nil, 1]) == []
      assert invoke_module_helper(helpers, :slice, ["stem", 1, 2]) == "te"
      assert invoke_module_helper(helpers, :slice, [[1, 2, 3], 1, "2"]) == [2, 3]
      assert invoke_module_helper(helpers, :first, ["stem"]) == "s"
      assert invoke_module_helper(helpers, :first, [[1, 2, 3]]) == 1
      assert invoke_module_helper(helpers, :reverse, ["stem"]) == "mets"
      assert invoke_module_helper(helpers, :reverse, [[1, 2, 3]]) == [3, 2, 1]

      assert_raise ArgumentError, ~r/trim expects 1 argument/, fn ->
        invoke_module_helper(helpers, :trim, [1, 2])
      end

      assert_raise ArgumentError, ~r/upcase expects 1 argument/, fn ->
        invoke_module_helper(helpers, :upcase, [1, 2])
      end

      assert_raise ArgumentError, ~r/downcase expects 1 argument/, fn ->
        invoke_module_helper(helpers, :downcase, [1, 2])
      end

      assert_raise ArgumentError, ~r/capitalize expects 1 argument/, fn ->
        invoke_module_helper(helpers, :capitalize, [1, 2])
      end

      assert_raise ArgumentError, ~r/truncate expects 2 or 3 arguments/, fn ->
        invoke_module_helper(helpers, :truncate, [1])
      end

      assert_raise ArgumentError, ~r/replace expects 3 arguments/, fn ->
        invoke_module_helper(helpers, :replace, [1, 2])
      end

      assert_raise ArgumentError, ~r/starts_with expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :starts_with, [1])
      end

      assert_raise ArgumentError, ~r/ends_with expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :ends_with, [1])
      end

      assert_raise ArgumentError, ~r/take expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :take, [1])
      end

      assert_raise ArgumentError, ~r/take expects integer arguments/, fn ->
        invoke_module_helper(helpers, :take, [[1, 2, 3], "nope"])
      end

      assert_raise ArgumentError, ~r/drop expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :drop, [1])
      end

      assert_raise ArgumentError, ~r/drop expects integer arguments, got: :bad/, fn ->
        invoke_module_helper(helpers, :drop, [[1, 2, 3], :bad])
      end

      assert_raise ArgumentError, ~r/slice expects 3 arguments/, fn ->
        invoke_module_helper(helpers, :slice, [1, 2])
      end

      assert_raise ArgumentError, ~r/slice expects integer arguments/, fn ->
        invoke_module_helper(helpers, :slice, ["stem", "bad", 1])
      end

      assert_raise ArgumentError, ~r/first expects 1 argument/, fn ->
        invoke_module_helper(helpers, :first, [1, 2])
      end

      assert_raise ArgumentError, ~r/reverse expects 1 argument/, fn ->
        invoke_module_helper(helpers, :reverse, [1, 2])
      end
    end
  end

  describe "direct collections helper module coverage" do
    test "collection helpers cover selector traversal, sequence branches, and errors" do
      helpers = Stem.Transformers.Collections.all()

      assert Map.keys(helpers) |> Enum.sort() == [
               "compact",
               "drop",
               "filter",
               "first",
               "flatten",
               "group_by",
               "map",
               "reverse",
               "slice",
               "sort",
               "sort_by",
               "take",
               "uniq"
             ]

      rows = [
        %{name: "b", active: true, meta: %{rank: 2}},
        %{name: "a", active: false, meta: %{rank: 1}},
        %{name: "c", active: true, meta: %{rank: 3}}
      ]

      assert invoke_module_helper(helpers, :map, [rows, "name"]) == ["b", "a", "c"]
      assert invoke_module_helper(helpers, :map, [[%{"name" => "nina"}], "name"]) == ["nina"]
      assert invoke_module_helper(helpers, :map, [[%{name: "nina"}], :name]) == ["nina"]
      assert invoke_module_helper(helpers, :map, [[%{1 => "one"}], 1]) == ["one"]
      assert invoke_module_helper(helpers, :map, [[%{meta: %{rank: 2}}], "meta.rank"]) == [2]
      assert invoke_module_helper(helpers, :map, [[["a", "b"]], 1]) == ["b"]
      assert invoke_module_helper(helpers, :map, [[[%{"name" => "nina"}]], "0.name"]) == ["nina"]
      assert invoke_module_helper(helpers, :map, [[%{1 => "one"}], "missing"]) == [nil]
      assert invoke_module_helper(helpers, :map, [[[:atom_entry]], "name"]) == [nil]
      assert invoke_module_helper(helpers, :map, [[1], "name"]) == [nil]
      assert invoke_module_helper(helpers, :map, [[[%{name: "nina"}]], "x"]) == [nil]

      assert invoke_module_helper(helpers, :filter, [[true, false, nil, 0, "", [], %{}, 1]]) == [
               true,
               1
             ]

      assert invoke_module_helper(helpers, :filter, [rows, "active"]) == [
               %{name: "b", active: true, meta: %{rank: 2}},
               %{name: "c", active: true, meta: %{rank: 3}}
             ]

      assert invoke_module_helper(helpers, :sort, [[3, 1, 2]]) == [1, 2, 3]

      assert invoke_module_helper(helpers, :sort_by, [rows, "name"]) == [
               %{name: "a", active: false, meta: %{rank: 1}},
               %{name: "b", active: true, meta: %{rank: 2}},
               %{name: "c", active: true, meta: %{rank: 3}}
             ]

      assert invoke_module_helper(helpers, :group_by, [rows, "active"]) == %{
               false => [%{name: "a", active: false, meta: %{rank: 1}}],
               true => [
                 %{name: "b", active: true, meta: %{rank: 2}},
                 %{name: "c", active: true, meta: %{rank: 3}}
               ]
             }

      assert invoke_module_helper(helpers, :compact, [[1, nil, 2]]) == [1, 2]
      assert Enum.sort(invoke_module_helper(helpers, :compact, [%{a: 2, b: nil, c: 1}])) == [1, 2]
      assert invoke_module_helper(helpers, :compact, [nil]) == []
      assert invoke_module_helper(helpers, :uniq, [[1, 1, 2]]) == [1, 2]
      assert invoke_module_helper(helpers, :flatten, [[[1], [2, [3]]]]) == [1, 2, 3]

      assert invoke_module_helper(helpers, :take, ["stem", 2]) == "st"
      assert invoke_module_helper(helpers, :take, [[1, 2, 3], "2"]) == [1, 2]
      assert invoke_module_helper(helpers, :take, [7, 1]) == [7]
      assert invoke_module_helper(helpers, :drop, ["stem", 2]) == "em"
      assert invoke_module_helper(helpers, :drop, [[1, 2, 3], 1]) == [2, 3]
      assert invoke_module_helper(helpers, :slice, ["stem", 1, 2]) == "te"
      assert invoke_module_helper(helpers, :slice, [[1, 2, 3], 1, "2"]) == [2, 3]
      assert invoke_module_helper(helpers, :first, ["stem"]) == "s"
      assert invoke_module_helper(helpers, :first, [[1, 2, 3]]) == 1
      assert invoke_module_helper(helpers, :first, [7]) == 7
      assert invoke_module_helper(helpers, :reverse, ["stem"]) == "mets"
      assert invoke_module_helper(helpers, :reverse, [[1, 2, 3]]) == [3, 2, 1]

      assert_raise ArgumentError, ~r/map expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :map, [1])
      end

      assert_raise ArgumentError, ~r/filter expects 1 or 2 arguments/, fn ->
        invoke_module_helper(helpers, :filter, [1, 2, 3])
      end

      assert_raise ArgumentError, ~r/sort expects 1 argument/, fn ->
        invoke_module_helper(helpers, :sort, [1, 2])
      end

      assert_raise ArgumentError, ~r/sort_by expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :sort_by, [1])
      end

      assert_raise ArgumentError, ~r/group_by expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :group_by, [1])
      end

      assert_raise ArgumentError, ~r/compact expects 1 argument/, fn ->
        invoke_module_helper(helpers, :compact, [1, 2])
      end

      assert_raise ArgumentError, ~r/uniq expects 1 argument/, fn ->
        invoke_module_helper(helpers, :uniq, [1, 2])
      end

      assert_raise ArgumentError, ~r/flatten expects 1 argument/, fn ->
        invoke_module_helper(helpers, :flatten, [1, 2])
      end

      assert_raise ArgumentError, ~r/take expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :take, [1])
      end

      assert_raise ArgumentError, ~r/take expects integer arguments, got: :bad/, fn ->
        invoke_module_helper(helpers, :take, [[1, 2, 3], :bad])
      end

      assert_raise ArgumentError, ~r/drop expects 2 arguments/, fn ->
        invoke_module_helper(helpers, :drop, [1])
      end

      assert_raise ArgumentError, ~r/drop expects integer arguments/, fn ->
        invoke_module_helper(helpers, :drop, ["stem", "bad"])
      end

      assert_raise ArgumentError, ~r/slice expects 3 arguments/, fn ->
        invoke_module_helper(helpers, :slice, [1, 2])
      end

      assert_raise ArgumentError, ~r/slice expects integer arguments, got: :bad/, fn ->
        invoke_module_helper(helpers, :slice, [[1, 2, 3], :bad, 1])
      end

      assert_raise ArgumentError, ~r/first expects 1 argument/, fn ->
        invoke_module_helper(helpers, :first, [1, 2])
      end

      assert_raise ArgumentError, ~r/reverse expects 1 argument/, fn ->
        invoke_module_helper(helpers, :reverse, [1, 2])
      end
    end
  end
end
