# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.SigilTest do
  use ExUnit.Case, async: true

  test "sigil_STEM macro accepts a direct literal binary" do
    Code.compile_string("""
    defmodule Stem.SigilTest.DirectLiteralTemplate do
      import Stem.Sigil

      def render(assigns) do
        sigil_STEM("Hello {{name}}", [])
      end
    end
    """)

    assert Stem.SigilTest.DirectLiteralTemplate.render(name: "Nina") == "Hello Nina"
  end

  test "~STEM rejects modifiers" do
    assert_raise ArgumentError, ~r/~STEM does not accept modifiers/, fn ->
      Code.compile_string("""
      defmodule Stem.SigilTest.InvalidModifier do
        import Stem.Sigil

        def render(assigns) do
          ~STEM"Hello {{name}}"x
        end
      end
      """)
    end
  end

  test "~STEM requires a literal template string" do
    assert_raise ArgumentError, ~r/~STEM expects a literal template string/, fn ->
      Code.compile_string(~S"""
      defmodule Stem.SigilTest.NonLiteralTemplate do
        import Stem.Sigil

        def render(assigns) do
          template_ast = quote(do: name)
          sigil_STEM(template_ast, [])
        end
      end
      """)
    end
  end
end
