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

  test "special variables outside each keep their literal form" do
    assert t("@index") == "@index"
    assert t("@index1") == "@index1"
    assert t("@key") == "@key"
    assert t("this") == "this"
  end

  test "special variables inside each map to loop bindings" do
    assert t("@index", true) == "stem_index"
    assert t("@index1", true) == "stem_index + 1"
    assert t("@key", true) == "stem_key"
    assert t("this", true) == "current"
  end

  test "bare identifiers resolve to assigns or current item" do
    assert t("name") == "@name"
    assert t("name", true) == "current.name"
  end

  test "dot is an alias for this (the current context)" do
    assert {:ok, {:special, :this}} = p(".")
    assert t(".") == "this"
    assert t(".", true) == "current"
  end

  test "parent traversal strips segments to a top-level assign" do
    assert t("../prefix") == "@prefix"
    assert t("../../prefix") == "@prefix"
  end

  test "dotted paths" do
    assert t("user.name") == "@user.name"
    # Inside an each body the loop item is bound to `current`, so a non-local
    # implicit path resolves against it (the previous `this.` reference was never
    # bound and raised at compile time).
    assert t("user.name", true) == "current.user.name"
    assert t("this.title") == "this.title"
  end

  test "bracketed literal keys lower to quoted atoms" do
    assert t("[first-name]") == ~s|@(:"first-name")|
    assert t("[first-name]", true) == ~s|current."first-name"|
    assert t("user.[first-name]") == ~s|@user."first-name"|
    assert t("[user-id].[first-name]") == ~s|@(:"user-id")."first-name"|
    assert t("this.[full name]") == ~s|this."full name"|
  end

  test "uppercase identifiers are valid keys without brackets" do
    assert t("I1") == "@(:I1)"
    assert t("Item.Name") == ~s|@(:Item)."Name"|
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
    assert t(~s|wrap this @index ../top|, true) ==
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
