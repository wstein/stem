# SPDX-License-Identifier: Apache-2.0

require Stem

defmodule Stem.RuntimeSecurity.Compiled do
  require Stem
  Stem.function_from_string(:def, :render_from_string, "Hello {{name}}", [:assigns])
end

defmodule Stem.RuntimeSecurityTest do
  use ExUnit.Case, async: true

  test "eval_string is disabled" do
    assert_raise Stem.SecurityError, fn ->
      Stem.eval_string("Hello {{name}}", assigns: [name: "Nina"])
    end
  end

  test "compile_string is disabled" do
    assert_raise Stem.SecurityError, fn ->
      Stem.compile_string("Hello {{name}}")
    end
  end

  test "compile-time generated template function still works" do
    assert Stem.RuntimeSecurity.Compiled.render_from_string(name: "Nina") == "Hello Nina"
  end
end
