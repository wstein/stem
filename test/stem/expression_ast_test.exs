# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.ExpressionAstTest do
  use ExUnit.Case, async: true

  alias Stem.Expression

  test "format renders all structured expression node forms" do
    assert Expression.format({:literal, ~s("x")}) == ~s("x")
    assert Expression.format({:special, :index}) == "@index"
    assert Expression.format({:special, :key}) == "@key"
    assert Expression.format({:special, :this}) == "this"
    assert Expression.format({:parent, "title"}) == "../title"
    assert Expression.format({:path, :implicit, ["user", "name"]}) == "user.name"
    assert Expression.format({:path, :this, ["title"]}) == "this.title"

    assert Expression.format(
             {:helper, "link", [{:identifier, "label"}, {:kw, "href", {:identifier, "url"}}]}
           ) ==
             "link label href=url"

    assert Expression.format(
             {:helper, "format", [{:helper, "uppercase", [{:identifier, "name"}]}]}
           ) ==
             "format (uppercase name)"

    assert Expression.format(
             {:helper, "wrap", [{:kw, "value", {:helper, "uppercase", [{:identifier, "name"}]}}]}
           ) == "wrap value=(uppercase name)"

    assert Expression.format(
             {:helper, "wrap",
              [
                {:pipeline, {:identifier, "name"}, [{:stage, "trim", []}]},
                {:kw, "value", {:pipeline, {:identifier, "name"}, [{:stage, "trim", []}]}}
              ]}
           ) == "wrap (name |> trim) value=(name |> trim)"

    assert Expression.format(
             {:pipeline, {:path, :implicit, ["user", "name"]},
              [
                {:stage, "trim", []},
                {:stage, "truncate", [{:literal, "20"}]}
              ]}
           ) == "user.name |> trim |> truncate(20)"

    assert Expression.format(
             {:pipeline, {:identifier, "name"},
              [{:stage, "default", [{:kw, "fallback", {:literal, ~s("x")}}]}]}
           ) == "name |> default(fallback=\"x\")"

    assert Expression.format({:elixir, "  a + b  "}) == "a + b"
  end

  test "references_identifier? handles helpers, paths, literals, and raw elixir" do
    refute Expression.references_identifier?({:literal, "true"}, "name")
    refute Expression.references_identifier?({:special, :this}, "name")
    refute Expression.references_identifier?({:parent, "name"}, "name")
    assert Expression.references_identifier?({:identifier, "name"}, "name")
    assert Expression.references_identifier?({:path, :implicit, ["name", "title"]}, "name")

    assert Expression.references_identifier?(
             {:helper, "wrap", [{:kw, "value", {:identifier, "name"}}]},
             "name"
           )

    assert Expression.references_identifier?({:helper, "wrap", [{:identifier, "name"}]}, "name")

    assert Expression.references_identifier?(
             {:pipeline, {:identifier, "name"}, [{:stage, "trim", []}]},
             "name"
           )

    assert Expression.references_identifier?(
             {:pipeline, {:literal, ~s("x")}, [{:stage, "default", [{:identifier, "name"}]}]},
             "name"
           )

    assert Expression.references_identifier?(
             {:pipeline, {:literal, ~s("x")},
              [{:stage, "default", [{:kw, "fallback", {:identifier, "name"}}]}]},
             "name"
           )

    assert Expression.references_identifier?({:elixir, "name + other"}, "name")
    refute Expression.references_identifier?({:elixir, "other + third"}, "name")
  end

  test "to_source prefers local bindings over implicit assigns" do
    context = %{in_each: true, locals: %{"item" => "current", "idx" => "stem_index"}}

    assert Expression.to_source({:identifier, "item"}, context) == "current"
    assert Expression.to_source({:identifier, "idx"}, context) == "stem_index"
    assert Expression.to_source({:path, :implicit, ["item", "title"]}, context) == "current.title"

    assert Expression.to_source(
             {:elixir, "item + idx"},
             %{in_each: false, locals: %{"item" => "row", "idx" => "index"}}
           ) == "row + index"
  end

  test "parse handles escaped quoted helper arguments" do
    assert {:ok, {:helper, "say", [{:literal, "\"a\\\"b\""}]}} =
             Expression.parse("say \"a\\\"b\"")
  end

  test "parse builds pipeline expression ast" do
    assert {:ok,
            {:pipeline, {:path, :implicit, ["user", "name"]},
             [
               {:stage, "trim", []},
               {:stage, "upcase", []},
               {:stage, "truncate", [{:literal, "20"}]}
             ]}} =
             Expression.parse("user.name |> trim |> upcase |> truncate(20)")
  end

  test "parse supports pipeline keyword args and pipeline subexpressions" do
    assert {:ok,
            {:pipeline, {:identifier, "name"},
             [{:stage, "default", [{:kw, "fallback", {:literal, ~s("x")}}]}]}} =
             Expression.parse("name |> default(fallback=\"x\")")

    assert {:ok,
            {:helper, "format", [{:pipeline, {:identifier, "name"}, [{:stage, "trim", []}]}]}} =
             Expression.parse("format (name |> trim)")
  end

  test "parse rejects non-helper pipeline stages" do
    assert {:error,
            "pipeline stages must be helper names or helper calls like trim or truncate(20)"} =
             Expression.parse("user.name |> String.trim()")
  end

  test "parse rejects invalid pipeline inputs and malformed arguments" do
    assert {:error, "pipeline expressions only allow structured Stem syntax"} =
             Expression.parse("a + b |> trim")

    assert {:error, "pipeline helper calls must use balanced parentheses"} =
             Expression.parse("name |> truncate((20)")

    assert {:error, "pipeline keyword arguments must use simple identifier keys"} =
             Expression.parse("name |> default(1=2)")

    assert {:ok, {:pipeline, {:identifier, "name"}, [{:stage, "default", []}]}} =
             Expression.parse("name |> default(  )")

    assert {:error, "pipeline stages cannot be empty"} =
             Expression.parse("name |>  |> trim")

    assert {:error, "pipeline expressions only allow structured Stem syntax"} =
             Expression.parse("name |> default(=1)")
  end

  test "translate raises for invalid pipelines" do
    assert_raise ArgumentError, ~r/pipeline stages must be helper names/, fn ->
      Expression.translate("name |> String.trim()", %{in_each: false, locals: %{}})
    end
  end

  test "invalid wrapped non-subexpressions fall back out of helper parsing" do
    assert {:ok, {:elixir, "format (name)"}} = Expression.parse("format (name)")
  end
end
