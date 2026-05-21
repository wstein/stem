# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.DSLTest.Views do
  use Stem.DSL

  handlebars(
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
  handlebars_file(:from_file, template_file, [:assigns])
end

defmodule Stem.DSLTest.PrivateViews do
  use Stem.DSL

  handlebars(:private_hello, "Hello {{name}}", [:assigns], kind: :defp)

  handlebars_file(
    :private_card,
    Path.join(__DIR__, "../fixtures/stem_template_with_bindings.stem"),
    [:assigns],
    kind: :defp
  )

  def hello(assigns), do: private_hello(assigns)
  def card(assigns), do: private_card(assigns)
end

defmodule Stem.DSLTest do
  use ExUnit.Case, async: true

  test "handlebars defines compile-time function from heredoc template" do
    assert Stem.DSLTest.Views.welcome_email(name: "Nina", is_admin: true) ==
             "<h1>Hello Nina</h1>\n\n  <p>You have admin access.</p>\n\n"
  end

  test "handlebars_file defines compile-time function from file" do
    assert Stem.DSLTest.Views.from_file(bar: 7) == "foo 7\n"
  end

  test "kind: :defp creates private functions for handlebars and handlebars_file" do
    assert Stem.DSLTest.PrivateViews.hello(name: "Nina") == "Hello Nina"
    assert Stem.DSLTest.PrivateViews.card(bar: 11) == "foo 11\n"
  end

  test "invalid :kind raises argument error" do
    assert_raise ArgumentError, ~r/expected :kind to be :def or :defp/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.InvalidKind do
        use Stem.DSL
        handlebars :broken, "Hello {{name}}", [:assigns], kind: :oops
      end
      """)
    end
  end

  test "non-keyword options raises argument error" do
    assert_raise ArgumentError, ~r/expected options to be a keyword list/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.InvalidOptions do
        use Stem.DSL
        handlebars :broken, "Hello {{name}}", [:assigns], :oops
      end
      """)
    end
  end
end
