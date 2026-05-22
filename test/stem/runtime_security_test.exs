# SPDX-License-Identifier: Apache-2.0

require Stem

defmodule Stem.RuntimeSecurity.Compiled do
  require Stem
  Stem.function_from_string(:def, :render_from_string, "Hello {{name}}", [:assigns])
end

defmodule Stem.RuntimeSecurityTest do
  use ExUnit.Case, async: true

  test "eval_string works at runtime" do
    assert Stem.Unsafe.eval_string("Hello {{name}}", assigns: [name: "Nina"]) == "Hello Nina"
  end

  test "compile_string returns quoted expressions" do
    quoted = Stem.compile_string("Hello {{name}}")
    {result, _binding} = Code.eval_quoted(quoted, assigns: [name: "Nina"], helpers: [])
    assert result == "Hello Nina"
  end

  test "compile-time generated template function still works" do
    assert Stem.RuntimeSecurity.Compiled.render_from_string(name: "Nina") == "Hello Nina"
  end

  test "default mode rejects arbitrary Elixir fallback expressions" do
    assert_raise CompileError, ~r/arbitrary Elixir expressions are not allowed/, fn ->
      Stem.Unsafe.eval_string("{{a + b}}", assigns: [a: 1, b: 2])
    end
  end

  test "allow_elixir_expressions: false rejects arbitrary Elixir fallback expressions" do
    assert_raise CompileError, ~r/arbitrary Elixir expressions are not allowed/, fn ->
      Stem.Unsafe.eval_string("{{a + b}}", [assigns: [a: 1, b: 2]],
        allow_elixir_expressions: false
      )
    end
  end

  test "allow_elixir_expressions: true allows arbitrary Elixir fallback expressions" do
    assert Stem.Unsafe.eval_string("{{a + b}}", [assigns: [a: 1, b: 2]],
             allow_elixir_expressions: true
           ) ==
             "3"
  end

  test "allow_elixir_expressions: false still allows structured Stem expressions" do
    assert Stem.Unsafe.eval_string("Hello {{name}}", [assigns: [name: "Nina"]],
             allow_elixir_expressions: false
           ) ==
             "Hello Nina"
  end

  test "allow_elixir_expressions: false allows helper pipelines" do
    helpers = [trim: fn [value], _ctx -> String.trim(to_string(value)) end]

    assert Stem.Unsafe.eval_string(
             "{{name |> trim}}",
             [assigns: [name: " Nina "], helpers: helpers],
             allow_elixir_expressions: false
           ) == "Nina"
  end

  test "runtime contract validation enforces required assigns" do
    assert_raise ArgumentError, ~r/missing required assigns/, fn ->
      Stem.Unsafe.eval_string("Hello {{name}}", [assigns: []], contract: [required: [:name]])
    end
  end
end
