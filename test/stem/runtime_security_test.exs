# SPDX-License-Identifier: Apache-2.0

require Stem

defmodule Stem.RuntimeSecurity.Compiled do
  require Stem
  Stem.function_from_string(:def, :render_from_string, "Hello {{name}}", [:assigns])
end

defmodule Stem.RuntimeSecurityTest do
  use ExUnit.Case, async: true

  test "eval_string works at runtime" do
    assert Stem.eval_string("Hello {{name}}", assigns: [name: "Nina"]) == "Hello Nina"
  end

  test "compile_string returns quoted expressions" do
    quoted = Stem.compile_string("Hello {{name}}")
    {result, _binding} = Code.eval_quoted(quoted, assigns: [name: "Nina"], helpers: [])
    assert result == "Hello Nina"
  end

  test "compile-time generated template function still works" do
    assert Stem.RuntimeSecurity.Compiled.render_from_string(name: "Nina") == "Hello Nina"
  end
end
