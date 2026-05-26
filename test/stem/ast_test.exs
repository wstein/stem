# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.ASTTest do
  use ExUnit.Case, async: true

  alias Stem.{AST, Parser}

  # The `stem-ast/v1` nodes for a source, with backend-native `src` provenance
  # (line/column) dropped so the assertions pin the cross-backend *conceptual*
  # contract — the node and expression kinds — that the Rust `parse_ast` export
  # also produces. (Exact byte/position parity is explicitly not required.)
  defp nodes(source) do
    {:ok, ast} = Parser.parse_ast(source)
    ast |> AST.to_wire() |> Map.fetch!("nodes") |> Enum.map(&strip_src/1)
  end

  defp strip_src(node) when is_map(node) do
    node
    |> Map.delete("src")
    |> Map.new(fn {key, value} -> {key, strip_src(value)} end)
  end

  defp strip_src(list) when is_list(list), do: Enum.map(list, &strip_src/1)
  defp strip_src(other), do: other

  test "version tag" do
    {:ok, ast} = Parser.parse_ast("x")
    assert AST.to_wire(ast)["version"] == "stem-ast/v1"
  end

  test "keeps partials unexpanded as dependency edges" do
    assert nodes("a {{> header}} b") == [
             %{"t" => "text", "text" => "a "},
             %{"t" => "partial", "name" => "header", "context" => nil, "hash" => %{}},
             %{"t" => "text", "text" => " b"}
           ]
  end

  test "partial carries its parsed context and hash arguments" do
    assert nodes(~s({{> card user role="admin"}})) == [
             %{
               "t" => "partial",
               "name" => "card",
               "context" => %{"t" => "identifier", "name" => "user"},
               "hash" => %{"role" => %{"t" => "lit", "value" => "admin"}}
             }
           ]
  end

  test "expressions keep their written syntactic form" do
    assert nodes("{{user.name | upcase}}") == [
             %{
               "t" => "emit",
               "escape" => "default",
               "expr" => %{
                 "t" => "pipeline",
                 "lhs" => %{"t" => "path", "segments" => ["user", "name"]},
                 "stages" => [%{"name" => "upcase", "args" => []}]
               }
             }
           ]
  end

  test "blocks and contextual references" do
    assert nodes("{{#each items}}{{@this.name}}{{/each}}") == [
             %{
               "t" => "each",
               "subject" => %{"t" => "identifier", "name" => "items"},
               "params" => [],
               "body" => [
                 %{
                   "t" => "emit",
                   "escape" => "default",
                   "expr" => %{"t" => "context", "kind" => "this", "path" => ["name"]}
                 }
               ],
               "else" => []
             }
           ]
  end

  test "unescaped output reports the none escape" do
    assert [%{"t" => "emit", "escape" => "none"}] = nodes("{{{raw}}}")
  end

  test "iteration variables and literals" do
    assert [%{"t" => "emit", "expr" => %{"t" => "index1"}}] =
             nodes("{{#each xs}}{{@index1}}{{/each}}") |> hd() |> Map.fetch!("body")

    assert [%{"t" => "emit", "expr" => %{"t" => "lit", "value" => 42}}] = nodes("{{42}}")
  end
end
