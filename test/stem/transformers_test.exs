# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.TransformersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Stem.Transformers

  defp invoke_module_helper(helpers, name, args, ctx \\ %{}) do
    Map.fetch!(helpers, Atom.to_string(name)).(args, ctx)
  end

  # The dispatcher-path tests below exercise resolution + execution for every
  # capability group, so they load the full trusted set explicitly. The library
  # default is the Minimum-only floor — see the "secure default" test.
  defp all_transformers do
    %{}
    |> Map.merge(Stem.Transformers.Minimum.all())
    |> Map.merge(Stem.Transformers.Strings.all())
    |> Map.merge(Stem.Transformers.Collections.all())
    |> Map.merge(Stem.Transformers.Predicates.all())
  end

  defp invoke_all(name, args),
    do: Transformers.invoke(name, args, transformers: all_transformers())

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

  test "register_all loads a whole group into the global registry" do
    assert_raise Stem.SyntaxError, ~r/unknown transformer 'upcase'/, fn ->
      Transformers.invoke(:upcase, ["nina"], [])
    end

    Transformers.register_all(Stem.Transformers.Strings.all())
    assert Transformers.invoke(:upcase, ["nina"], []) == "NINA"
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
          invoke_all(name, args)
        end
      end)
    end

    test "string transforms and defaults" do
      assert invoke_all(:trim, ["  Nina  "]) == "Nina"
      assert invoke_all(:upcase, ["Nina"]) == "NINA"
      assert invoke_all(:downcase, ["Nina"]) == "nina"
      assert invoke_all(:capitalize, ["nina"]) == "Nina"
      assert invoke_all(:replace, ["stem", "e", "a"]) == "stam"
      assert invoke_all(:truncate, ["stem", 3]) == "ste"
      assert invoke_all(:truncate, ["stem", 3, ".."]) == "s.."
      assert invoke_all(:default, [nil, "fallback"]) == "fallback"
      assert invoke_all(:default, ["value", "fallback"]) == "value"
    end

    test "json and inspect transformers serialize values" do
      assert Transformers.invoke(:inspect, [%{a: 1}], []) == "%{a: 1}"
      assert Transformers.invoke(:json, [%{a: 1}], []) == ~s({"a":1})
      assert Transformers.invoke(:escape_json, [~s(a"b)], []) == "a\\\"b"
    end

    test "predicates cover strings, maps, and lists" do
      assert invoke_all(:contains, [["a", "b"], "a"])
      assert invoke_all(:contains, [%{name: "Nina"}, :name])
      assert invoke_all(:contains, ["stem", "te"])
      refute invoke_all(:contains, [123, :name])
      assert invoke_all(:empty?, [[]])
      refute invoke_all(:empty?, [[1]])
      refute invoke_all(:empty?, [0])
      assert invoke_all(:present?, [[1]])
      refute invoke_all(:present?, [%{}])
      assert invoke_all(:starts_with, ["stem", "st"])
      assert invoke_all(:ends_with, ["stem", "em"])
    end

    test "collection transformers support declarative selectors" do
      rows = [%{name: "b", active: true}, %{name: "a", active: false}, %{name: "c", active: true}]

      assert invoke_all(:map, [rows, "name"]) == ["b", "a", "c"]

      assert invoke_all(:filter, [rows, "active"]) == [
               %{name: "b", active: true},
               %{name: "c", active: true}
             ]

      assert invoke_all(:sort_by, [rows, "name"]) == [
               %{name: "a", active: false},
               %{name: "b", active: true},
               %{name: "c", active: true}
             ]

      assert invoke_all(:group_by, [rows, "active"]) == %{
               false => [%{name: "a", active: false}],
               true => [%{name: "b", active: true}, %{name: "c", active: true}]
             }

      assert invoke_all(:map, [[%{"name" => "nina"}], "name"]) == ["nina"]
      assert invoke_all(:map, [[%{name: "nina"}], :name]) == ["nina"]
      assert invoke_all(:map, [[%{1 => "one"}], 1]) == ["one"]
      assert invoke_all(:map, [[["a", "b"]], "1"]) == ["b"]
      assert invoke_all(:map, [[["a", "b"]], 1]) == ["b"]
      assert invoke_all(:map, [[["a", "b"]], "x"]) == [nil]
      assert invoke_all(:map, [[:atom_entry], "name"]) == [nil]
      assert invoke_all(:map, [[%{other: "x"}], "name"]) == [nil]
    end

    test "list and string transformers support common sequence operations" do
      assert invoke_all(:join, [["a", "b"], ","]) == "a,b"
      assert invoke_all(:join, [["a", "b"]]) == "ab"
      assert invoke_all(:compact, [[1, nil, 2]]) == [1, 2]
      assert invoke_all(:compact, [nil]) == []
      assert invoke_all(:sort, [[3, 1, 2]]) == [1, 2, 3]
      assert invoke_all(:sort, [%{a: 2, b: 1}]) == [1, 2]
      assert invoke_all(:filter, [[true, false, nil, 0, ""]]) == [true]
      assert invoke_all(:take, [[1, 2, 3], 2]) == [1, 2]
      assert invoke_all(:take, [[1, 2, 3], "2"]) == [1, 2]
      assert invoke_all(:take, [7, 1]) == [7]
      assert invoke_all(:drop, [[1, 2, 3], 1]) == [2, 3]
      assert invoke_all(:slice, [[1, 2, 3], 1, 2]) == [2, 3]
      assert invoke_all(:first, [[1, 2, 3]]) == 1
      assert invoke_all(:first, [7]) == 7
      assert invoke_all(:uniq, [[1, 1, 2]]) == [1, 2]
      assert invoke_all(:flatten, [[[1], [2, [3]]]]) == [1, 2, 3]
      assert invoke_all(:reverse, [[1, 2, 3]]) == [3, 2, 1]
      assert invoke_all(:take, ["stem", 2]) == "st"
      assert invoke_all(:drop, ["stem", 2]) == "em"
      assert invoke_all(:slice, ["stem", 1, 2]) == "te"
      assert invoke_all(:first, ["stem"]) == "s"
      assert invoke_all(:reverse, ["stem"]) == "mets"

      assert_raise ArgumentError, ~r/take expects integer arguments/, fn ->
        invoke_all(:take, [[1, 2, 3], "nope"])
      end
    end

    test "secure default exposes only the Minimum group; other groups must be loaded" do
      # Minimum transformers resolve with no `transformers:` binding.
      assert Transformers.invoke(:escape_html, ["<b>"], []) == "&lt;b&gt;"
      assert Transformers.invoke(:default, [nil, "x"], []) == "x"

      # Strings/Collections/Predicates transformers are gated off by default.
      for name <- [:upcase, :trim, :map, :filter, :sort_by, :contains, :empty?] do
        assert_raise Stem.SyntaxError,
                     ~r/#{Regex.escape("unknown transformer '#{name}'")}/,
                     fn -> Transformers.invoke(name, ["x"], []) end
      end

      # Loading a group via the binding makes its transformers available, while
      # the Minimum floor stays reachable underneath.
      strings = Stem.Transformers.Strings.all()
      assert Transformers.invoke(:upcase, ["nina"], transformers: strings) == "NINA"
      assert Transformers.invoke(:escape_html, ["<b>"], transformers: strings) == "&lt;b&gt;"

      assert_raise Stem.SyntaxError, ~r/unknown transformer 'map'/, fn ->
        Transformers.invoke(:map, [[%{a: 1}], "a"], transformers: strings)
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

  describe "Collections capability audit signal" do
    setup do
      # Reset the per-VM log latch so the assertions below are deterministic.
      :persistent_term.erase({Stem.Transformers.Collections, :capability_logged})
      original = Application.get_env(:stem, :capability_log_level, false)
      on_exit(fn -> Application.put_env(:stem, :capability_log_level, original) end)
      :ok
    end

    test "is silent by default (telemetry-only)" do
      Application.put_env(:stem, :capability_log_level, false)
      log = capture_log(fn -> Stem.Transformers.Collections.all() end)
      refute log =~ "capability group loaded"
    end

    test "logs once per VM at the configured level when opted in" do
      Application.put_env(:stem, :capability_log_level, :info)

      first = capture_log(fn -> Stem.Transformers.Collections.all() end)
      second = capture_log(fn -> Stem.Transformers.Collections.all() end)

      assert first =~ "capability group loaded"
      refute second =~ "capability group loaded"
    end
  end

  describe "Stem.Transformers.Standard" do
    test "pre-merges Minimum and Strings transformers" do
      standard = Stem.Transformers.Standard.all()
      expected = Map.merge(Stem.Transformers.Minimum.all(), Stem.Transformers.Strings.all())

      assert Enum.sort(Map.keys(standard)) == Enum.sort(Map.keys(expected))
      assert Map.has_key?(standard, "escape_html")
      assert Map.has_key?(standard, "trim")
      assert Map.has_key?(standard, "upcase")
    end

    test "excludes Collections-only transformers to limit SSTI gadget chains" do
      standard = Stem.Transformers.Standard.all()

      for key <- ~w(map filter sort sort_by group_by compact uniq flatten) do
        refute Map.has_key?(standard, key), "Standard must not expose Collections helper #{key}"
      end
    end
  end

  describe "capability-group names/0" do
    test "each group lists its transformers without loading it (no audit event)" do
      assert "map" in Stem.Transformers.Collections.names()
      assert "trim" in Stem.Transformers.Strings.names()
      assert "contains" in Stem.Transformers.Predicates.names()
    end

    test "names/0 stays in sync with all/0 keys" do
      assert Enum.sort(Stem.Transformers.Strings.names()) ==
               Enum.sort(Map.keys(Stem.Transformers.Strings.all()))

      assert Enum.sort(Stem.Transformers.Collections.names()) ==
               Enum.sort(Map.keys(Stem.Transformers.Collections.all()))

      assert Enum.sort(Stem.Transformers.Predicates.names()) ==
               Enum.sort(Map.keys(Stem.Transformers.Predicates.all()))
    end
  end

  describe "unknown transformer guidance" do
    test "names the capability group and how to enable it" do
      assert_raise Stem.SyntaxError,
                   ~r/unknown transformer 'map'.*Stem\.Transformers\.Collections.*--transformers/s,
                   fn -> Transformers.invoke(:map, [[1, 2]], []) end
    end

    test "mentions the Standard bundle for string transformers" do
      assert_raise Stem.SyntaxError,
                   ~r/unknown transformer 'trim'.*Stem\.Transformers\.Strings.*Stem\.Transformers\.Standard/s,
                   fn -> Transformers.invoke(:trim, ["x"], []) end
    end

    test "suggests registering a transformer that belongs to no group" do
      assert_raise Stem.SyntaxError,
                   ~r/unknown transformer 'bogus'.*[Rr]egister/s,
                   fn -> Transformers.invoke(:bogus, [], []) end
    end
  end
end
