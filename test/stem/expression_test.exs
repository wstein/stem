# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.ExpressionTest do
  use ExUnit.Case, async: true

  alias Stem.Expression

  # Inside an each the current item is bound to `current` and the immediate
  # parent is the render root.
  defp t(raw, in_each \\ false) do
    context = %{
      in_each: in_each,
      locals: %{},
      this_var: if(in_each, do: "current", else: :root),
      parent_var: if(in_each, do: :root, else: nil)
    }

    Expression.translate(raw, context)
  end

  defp p(raw), do: Expression.parse(raw)

  test "empty expression" do
    assert t("") == "\"\""
  end

  test "literals pass through" do
    assert t("true") == "true"
    assert t("false") == "false"
    assert t("nil") == "nil"
  end

  test "null and nil both translate to Elixir nil" do
    assert t("null") == "nil"
    assert t("nil") == "nil"
  end

  test "formatting canonicalises nil to null" do
    assert {:ok, expr} = p("nil")
    assert Expression.format(expr) == "null"

    assert {:ok, expr} = p("null")
    assert Expression.format(expr) == "null"
  end

  test "iteration variables require an each" do
    for var <- ~w(@index @index1 @key @first @last) do
      assert_raise ArgumentError, fn -> t(var) end
    end
  end

  test "iteration variables inside each map to loop bindings" do
    assert t("@index", true) == "stem_index"
    assert t("@index1", true) == "stem_index + 1"
    assert t("@key", true) == "stem_key"
    assert t("@first", true) == "stem_first"
    assert t("@last", true) == "stem_last"
  end

  test "bare identifiers resolve to assigns or the current item" do
    assert t("name") == "@name"
    assert t("name", true) == "Stem.Runtime.get_field(current, :name)"
  end

  test "@this is the current context" do
    assert {:ok, {:path, :this, []}} = p("@this")
    # At the root the current context is the render assigns.
    assert t("@this") == "assigns"
    assert t("@this", true) == "current"
    # `@this.field` reads an assign at the root, a field of the item in an each.
    assert t("@this.title") == "@title"
    assert t("@this.title", true) == "Stem.Runtime.get_field(current, :title)"
  end

  test "@root reads the render assigns from any depth" do
    assert {:ok, {:path, :root, ["x"]}} = p("@root.x")
    assert t("@root.x") == "@x"
    assert t("@root.x", true) == "@x"
  end

  test "@parent reads the enclosing context and requires a block" do
    assert {:ok, {:path, :parent, ["top"]}} = p("@parent.top")
    assert t("@parent.top", true) == "@top"
    assert_raise ArgumentError, fn -> t("@parent.top") end
  end

  test "dotted paths fold through tolerant field access" do
    assert t("user.name") == "Stem.Runtime.get_field(@user, :name)"

    assert t("user.name", true) ==
             "Stem.Runtime.get_field(Stem.Runtime.get_field(current, :user), :name)"
  end

  test "numeric segments index lists" do
    assert {:ok, {:path, :implicit, ["items", "1"]}} = p("items.[1]")
    assert t("items.[1]") == "Stem.Runtime.get_field(@items, 1)"
  end

  test "bracketed literal keys lower to quoted atoms" do
    assert t("[first-name]") == ~s|@(:"first-name")|
    assert t("[first-name]", true) == ~s|Stem.Runtime.get_field(current, :"first-name")|
    assert t("user.[first-name]") == ~s|Stem.Runtime.get_field(@user, :"first-name")|
    assert t("[user-id].[first-name]") == ~s|Stem.Runtime.get_field(@(:"user-id"), :"first-name")|
    assert t("@this.[full name]", true) == ~s|Stem.Runtime.get_field(current, :"full name")|
  end

  test "uppercase identifiers are valid keys without brackets" do
    assert t("I1") == "@(:I1)"
    assert t("Item.Name") == ~s|Stem.Runtime.get_field(@(:Item), :Name)|
  end

  test "bracket segments may contain dots and reserved words" do
    assert {:ok, {:identifier, "a.b"}} = p("[a.b]")
    assert {:ok, {:identifier, "this"}} = p("[this]")
  end

  test "bracketed keys round-trip through format" do
    assert {:ok, expr} = p("[first-name]")
    assert Expression.format(expr) == "[first-name]"

    assert {:ok, expr} = p("user.[first-name]")
    assert Expression.format(expr) == "user.[first-name]"
  end

  test "bare keys with non-identifier characters are rejected" do
    assert {:error, _} = p("a-b")
  end

  test "helper invocation with positional, literal, and numeric args" do
    assert t(~s|progress "Search" 10 false|) ==
             ~s|Stem.Transformers.invoke(:progress, ["Search", 10, false], [assigns: assigns, transformers: transformers])|
  end

  test "helper invocation with keyword args and identifiers" do
    assert t(~s|link label href=url class="c"|) ==
             ~s|Stem.Transformers.invoke(:link, [@label, href: @url, class: "c"], [assigns: assigns, transformers: transformers])|
  end

  test "subexpressions compose helper calls" do
    assert t("format (uppercase name)") ==
             "Stem.Transformers.invoke(:format, [Stem.Transformers.invoke(:uppercase, [@name], [assigns: assigns, transformers: transformers])], [assigns: assigns, transformers: transformers])"
  end

  test "parse returns structured helper AST" do
    assert {:ok, {:transformer, "format", [{:transformer, "uppercase", [{:identifier, "name"}]}]}} =
             p("format (uppercase name)")
  end

  test "helper invocation inside each adds this/key context and resolves args" do
    assert t(~s|wrap @this @index @parent.top|, true) ==
             ~s|Stem.Transformers.invoke(:wrap, [current, stem_index, @top], [this: current, key: stem_key, assigns: assigns, transformers: transformers])|
  end

  test "a bare word followed by arguments is treated as a helper call" do
    assert t("a b c") ==
             "Stem.Transformers.invoke(:a, [@b, @c], [assigns: assigns, transformers: transformers])"
  end

  test "@key is resolved as a helper argument inside each" do
    assert t("wrap @key", true) ==
             "Stem.Transformers.invoke(:wrap, [stem_key], [this: current, key: stem_key, assigns: assigns, transformers: transformers])"
  end
end
