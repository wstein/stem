# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.BytecodeTest do
  use ExUnit.Case, async: true

  alias Stem.Bytecode
  alias Stem.Bytecode.{Program, UnsupportedError}

  doctest Stem.Bytecode

  defp compile(source, opts \\ []) do
    {:ok, ast} = Stem.Parser.parse_with_spans(source, opts)
    Bytecode.compile(ast, opts)
  end

  test "version/0 reports the bytecode format version" do
    assert Bytecode.version() == "stem-bc/v1"
  end

  describe "compile/2 program shape" do
    test "emits a versioned program for text and expressions" do
      program = compile("Hello {{name}}!")

      assert %Program{version: "stem-bc/v1", instructions: instructions} = program

      assert instructions == [
               {:text, "Hello "},
               {:emit, {:assign, :name}, :html},
               {:text, "!"}
             ]
    end

    test "lowers dotted paths to a get over a top-level assign" do
      program = compile("{{user.profile.name}}")

      assert program.instructions == [{:emit, {:get, {:assign, :user}, [:profile, :name]}, :html}]
    end

    test "treats a parent path as a top-level assign, matching the compiled backend" do
      program = compile("{{../title}}")
      assert program.instructions == [{:emit, {:assign, :title}, :html}]
    end

    test "raw triple-stash expressions are not escaped" do
      program = compile("{{{raw}}}")
      assert program.instructions == [{:emit, {:assign, :raw}, :none}]
    end

    test "resolves the default escape mode at compile time" do
      assert compile("{{x}}", escape: :json).instructions == [{:emit, {:assign, :x}, :json}]
      assert compile("{{x}}", escape: :none).instructions == [{:emit, {:assign, :x}, :none}]
    end

    test "lowers a pipeline into nested calls with the value threaded first" do
      program = compile("{{name |> trim |> truncate(20)}}")

      assert program.instructions == [
               {:emit,
                {:call, "truncate", [{:call, "trim", [{:assign, :name}], []}, {:lit, 20}], []},
                :html}
             ]
    end

    test "lowers transformer calls, keyword arguments, and subexpressions" do
      program = compile("{{format (uppercase name) sep=\"-\"}}")

      assert program.instructions == [
               {:emit,
                {:call, "format", [{:call, "uppercase", [{:assign, :name}], []}],
                 [sep: {:lit, "-"}]}, :html}
             ]
    end

    test "parses literal arguments to their Elixir values" do
      assert [{:emit, {:call, "default", [{:assign, :x}, {:lit, 42}], []}, :html}] =
               compile("{{default x 42}}").instructions

      assert [{:emit, {:call, "default", [{:assign, :x}, {:lit, -5}], []}, :html}] =
               compile("{{default x -5}}").instructions

      assert [{:emit, {:call, "default", [{:assign, :x}, {:lit, true}], []}, :html}] =
               compile("{{default x true}}").instructions

      # Single-quoted template literals are charlists; Elixir's parser emits a
      # deprecation warning for them, captured here to keep test output clean.
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert [{:emit, {:call, "default", [{:assign, :x}, {:lit, ~c"abc"}], []}, :html}] =
                 compile("{{default x 'abc'}}").instructions
      end)
    end

    test "rejects a non-literal source in argument position" do
      # `compile/2` accepts any Stem.AST; guard against a literal node whose
      # source is not actually a literal term (e.g. string interpolation).
      meta = %{line: 1, column: 1}
      literal = {:literal, ~S("a#{b}")}
      ast = [{:expr, {:transformer, "default", [{:identifier, "x"}, literal]}, :default, meta}]

      assert_raise UnsupportedError, ~r/non-literal expression/, fn ->
        Bytecode.compile(ast)
      end
    end
  end

  describe "compile/2 capability metadata" do
    test "records the built-in groups a program references" do
      assert compile("{{name |> upcase}}").capabilities == [:strings]
      assert compile("{{items |> map(\"id\")}}").capabilities == [:collections]
      assert compile("Hello {{name}}").capabilities == []
    end

    test "lists transformer names that belong to no built-in group as host transformers" do
      program = compile("{{price |> currency}}")
      assert program.host_transformers == ["currency"]
      assert program.capabilities == []
    end

    test "a built-in transformer is not a host transformer" do
      program = compile("{{name |> upcase}}")
      assert program.host_transformers == []
    end
  end

  describe "compile/2 rejects out-of-scope constructs" do
    test "block helpers raise UnsupportedError" do
      for source <- [
            "{{#if ok}}y{{/if}}",
            "{{#unless ok}}y{{/unless}}",
            "{{#each items}}{{this}}{{/each}}",
            "{{#with user}}{{name}}{{/with}}"
          ] do
        assert_raise UnsupportedError, ~r/block helper/, fn -> compile(source) end
      end
    end

    test "regions and yields raise UnsupportedError" do
      assert_raise UnsupportedError, ~r/region/, fn ->
        compile("{{#region body}}x{{/region}}")
      end

      assert_raise UnsupportedError, ~r/yield/, fn ->
        compile("{{yield body}}")
      end
    end

    test "block-scoped references raise UnsupportedError" do
      for source <- ["{{this}}", "{{@index}}", "{{@key}}", "{{this.name}}"] do
        assert_raise UnsupportedError, ~r/block/, fn -> compile(source) end
      end
    end

    test "arbitrary Elixir expressions raise UnsupportedError" do
      assert_raise UnsupportedError, ~r/Elixir expression/, fn ->
        compile("{{1 + 1}}", allow_elixir_expressions: true)
      end
    end
  end

  describe "disasm/1" do
    test "renders a readable, versioned listing" do
      disasm = "Hello {{name |> upcase}}" |> compile() |> Bytecode.disasm()

      assert disasm =~ "; stem-bc/v1"
      assert disasm =~ ~s(EMIT_TEXT "Hello ")
      assert disasm =~ "CALL upcase(ASSIGN name) ESCAPE=html"
    end

    test "renders gets and keyword arguments" do
      disasm =
        "{{user.name}}{{format x sep=\"-\"}}"
        |> compile()
        |> Bytecode.disasm()

      assert disasm =~ "GET ASSIGN user name"
      assert disasm =~ "CALL format(ASSIGN x, sep=LIT \"-\")"
    end
  end
end
