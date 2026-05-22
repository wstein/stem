# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.ExpressionTest do
  use ExUnit.Case, async: true

  alias Stem.Expression

  defp t(raw, in_each \\ false), do: Expression.translate(raw, %{in_each: in_each})
  defp p(raw), do: Expression.parse(raw)

  test "empty expression" do
    assert t("") == "\"\""
  end

  test "literals pass through" do
    assert t("true") == "true"
    assert t("false") == "false"
    assert t("nil") == "nil"
  end

  test "special variables outside each keep their literal form" do
    assert t("@index") == "@index"
    assert t("@key") == "@key"
    assert t("this") == "this"
  end

  test "special variables inside each map to loop bindings" do
    assert t("@index", true) == "stem_index"
    assert t("@key", true) == "stem_key"
    assert t("this", true) == "current"
  end

  test "bare identifiers resolve to assigns or current item" do
    assert t("name") == "@name"
    assert t("name", true) == "current.name"
  end

  test "parent traversal strips segments to a top-level assign" do
    assert t("../prefix") == "@prefix"
    assert t("../../prefix") == "@prefix"
  end

  test "dotted paths" do
    assert t("user.name") == "@user.name"
    assert t("user.name", true) == "this.user.name"
    assert t("this.title") == "this.title"
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
    assert t(~s|wrap this @index ../top|, true) ==
             ~s|Stem.Transformers.invoke(:wrap, [current, stem_index, @top], [this: current, key: stem_key, assigns: assigns, transformers: transformers])|
  end

  test "non-helper expressions fall back to assigns rewriting" do
    assert t("a + b") == "@a + @b"
    assert t("a + b", true) == "this.a + this.b"
  end

  test "rewriting preserves boolean operators and literals" do
    assert t("a or b && c") == "@a or @b && @c"
    assert t("not a && b") == "not @a && @b"
  end

  test "a bare word followed by arguments is treated as a helper call" do
    assert t("a b c") ==
             "Stem.Transformers.invoke(:a, [@b, @c], [assigns: assigns, transformers: transformers])"
  end

  test "@key is resolved as a helper argument inside each" do
    assert t("wrap @key", true) ==
             "Stem.Transformers.invoke(:wrap, [stem_key], [this: current, key: stem_key, assigns: assigns, transformers: transformers])"
  end

  test "an argument with an empty key is not a helper" do
    assert t("foo =bar") == "@foo =@bar"
  end
end
