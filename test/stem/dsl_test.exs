# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.DSLTest.Views do
  use Stem.DSL

  deftemplate(
    :welcome_email,
    """
    <h1>Hello {{name}}</h1>
    {{#if is_admin}}
      <p>You have admin access.</p>
    {{else}}
      <p>Standard access.</p>
    {{/if}}
    """,
    [:assigns]
  )

  template_file = Path.join(__DIR__, "../fixtures/stem_template_with_bindings.stem")
  deftemplate_file(:from_file, template_file, [:assigns])
end

defmodule Stem.DSLTest.PrivateViews do
  use Stem.DSL

  deftemplate(:private_hello, "Hello {{name}}", [:assigns], kind: :defp)

  deftemplate_file(
    :private_card,
    Path.join(__DIR__, "../fixtures/stem_template_with_bindings.stem"),
    [:assigns],
    kind: :defp
  )

  def hello(assigns), do: private_hello(assigns)
  def card(assigns), do: private_card(assigns)
end

defmodule Stem.DSLTest.SigilViews do
  import Stem.Sigil

  def hello(assigns), do: ~STEM"Hello {{name}}"
  def upcase(assigns, helpers), do: ~STEM"{{upcase name}}"
end

defmodule Stem.DSLTest.UseStemViews do
  use Stem

  deftemplate(:hello, "Hello {{name}}", [:assigns])

  def hello_inline(assigns), do: ~STEM"Inline {{name}}"
end

defmodule Stem.DSLTest do
  use ExUnit.Case, async: true

  test "deftemplate defines compile-time function from heredoc template" do
    assert Stem.DSLTest.Views.welcome_email(name: "Nina", is_admin: true) ==
             "<h1>Hello Nina</h1>\n\n  <p>You have admin access.</p>\n\n"
  end

  test "deftemplate_file defines compile-time function from file" do
    assert Stem.DSLTest.Views.from_file(bar: 7) == "foo 7\n"
  end

  test "kind: :defp creates private functions for deftemplate and deftemplate_file" do
    assert Stem.DSLTest.PrivateViews.hello(name: "Nina") == "Hello Nina"
    assert Stem.DSLTest.PrivateViews.card(bar: 11) == "foo 11\n"
  end

  test "~STEM renders inline templates with surrounding assigns" do
    assert Stem.DSLTest.SigilViews.hello(name: "Nina") == "Hello Nina"
  end

  test "~STEM can resolve helpers from surrounding scope" do
    helpers = [upcase: fn [value], _ctx -> String.upcase(to_string(value)) end]

    assert Stem.DSLTest.SigilViews.upcase([name: "Nina"], helpers) == "NINA"
  end

  test "use Stem imports the DSL and sigil" do
    assert Stem.DSLTest.UseStemViews.hello(name: "Nina") == "Hello Nina"
    assert Stem.DSLTest.UseStemViews.hello_inline(name: "Nina") == "Inline Nina"
  end

  test "invalid :kind raises argument error" do
    assert_raise ArgumentError, ~r/expected :kind to be :def or :defp/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.InvalidKind do
        use Stem.DSL
        deftemplate :broken, "Hello {{name}}", [:assigns], kind: :oops
      end
      """)
    end
  end

  test "non-keyword options raises argument error" do
    assert_raise ArgumentError, ~r/expected options to be a keyword list/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.InvalidOptions do
        use Stem.DSL
        deftemplate :broken, "Hello {{name}}", [:assigns], :oops
      end
      """)
    end
  end
end
