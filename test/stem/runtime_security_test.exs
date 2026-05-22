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
    {result, _binding} = Code.eval_quoted(quoted, assigns: [name: "Nina"], transformers: %{})
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

  test "allow_elixir_expressions: false allows transformer pipelines" do
    assert Stem.Unsafe.eval_string(
             "{{name |> trim}}",
             [assigns: [name: " Nina "], transformers: Stem.Transformers.Standard.all()],
             allow_elixir_expressions: false
           ) == "Nina"
  end

  test "the secure default exposes only Minimum; powerful groups need explicit loading" do
    # `upcase` (Strings) is not in the Minimum floor, so a bare runtime eval
    # cannot reach it — the capability must be loaded deliberately.
    assert_raise Stem.SyntaxError, ~r/unknown transformer 'upcase'/, fn ->
      Stem.Unsafe.eval_string("{{name |> upcase}}", assigns: [name: "nina"])
    end

    assert Stem.Unsafe.eval_string(
             "{{name |> upcase}}",
             assigns: [name: "nina"],
             transformers: Stem.Transformers.Strings.all()
           ) == "NINA"
  end

  test "runtime contract validation enforces required assigns" do
    assert_raise ArgumentError, ~r/missing required assigns/, fn ->
      Stem.Unsafe.eval_string("Hello {{name}}", [assigns: []], contract: [required: [:name]])
    end
  end
end
