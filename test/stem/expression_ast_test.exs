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
             {:pipeline, {:path, :implicit, ["user", "name"]},
              [
                {:stage, "trim", []},
                {:stage, "truncate", [{:literal, "20"}]}
              ]}
           ) == "user.name |> trim |> truncate(20)"

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

  test "parse rejects non-helper pipeline stages" do
    assert {:error,
            "pipeline stages must be helper names or helper calls like trim or truncate(20)"} =
             Expression.parse("user.name |> String.trim()")
  end
end
