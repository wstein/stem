# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.ParserTest do
  use ExUnit.Case, async: true

  alias Stem.Parser

  defp ast(source, opts \\ []) do
    {:ok, nodes} = Parser.parse(source, opts)
    nodes
  end

  test "text and expressions" do
    assert ast("Hi {{name}}!") == [
             {:text, "Hi "},
             {:expr, "name", %{line: 1, column: 4}},
             {:text, "!"}
           ]
  end

  test "raw expression node" do
    assert [{:raw, "name", _}] = ast("{{{name}}}")
  end

  test "if block without else" do
    assert [{:if, "show", [{:text, "yes"}], [], %{line: 1, column: 1}}] =
             ast("{{#if show}}yes{{/if}}")
  end

  test "if block with else" do
    assert [{:if, "show", [{:text, "yes"}], [{:text, "no"}], _}] =
             ast("{{#if show}}yes{{else}}no{{/if}}")
  end

  test "each, unless, with blocks" do
    assert [{:each, "items", [{:expr, "this", _}], [], _}] =
             ast("{{#each items}}{{this}}{{/each}}")

    assert [{:unless, "flag", [{:text, "x"}], [], _}] = ast("{{#unless flag}}x{{/unless}}")

    assert [{:with, "story", [{:expr, "this.title", _}], [], _}] =
             ast("{{#with story}}{{this.title}}{{/with}}")
  end

  test "nested blocks" do
    assert [
             {:each, "rows", [{:if, "ok", [{:text, "y"}], [], _}], [], _}
           ] = ast("{{#each rows}}{{#if ok}}y{{/if}}{{/each}}")
  end

  test "partials are expanded inline" do
    nodes = ast("a {{> greet}} b", partials: %{greet: "Hi {{name}}"})

    assert nodes == [
             {:text, "a "},
             {:text, "Hi "},
             {:expr, "name", %{line: 1, column: 4}},
             {:text, " b"}
           ]
  end

  test "partials may reference other partials" do
    nodes =
      ast("{{> outer}}", partials: %{outer: "[{{> inner}}]", inner: "x"})

    assert nodes == [{:text, "["}, {:text, "x"}, {:text, "]"}]
  end

  describe "errors" do
    test "unclosed block reports the opening position" do
      assert Parser.parse("a\n{{#if show}}yes") ==
               {:error, "expected a closing '{{/if}}' for block expression in Stem",
                %{line: 2, column: 1}}
    end

    test "mismatched closing tag" do
      assert {:error, "unexpected closing tag '{{/each}}'; expected '{{/if}}'", _} =
               Parser.parse("{{#if a}}{{/each}}")
    end

    test "closing tag without an open block" do
      assert {:error, "unexpected closing tag '{{/if}}'", _} = Parser.parse("{{/if}}")
    end

    test "else outside of a block" do
      assert {:error, "unexpected '{{else}}' outside of a block", _} = Parser.parse("{{else}}")
    end

    test "second else inside a block" do
      assert {:error, "unexpected second '{{else}}' inside '{{#each}}'", _} =
               Parser.parse("{{#each xs}}a{{else}}b{{else}}c{{/each}}")
    end

    test "unknown partial" do
      assert {:error, "unknown partial 'missing'", _} = Parser.parse("{{> missing}}")
    end

    test "partial recursion is detected" do
      assert {:error, "partial recursion detected for 'loop'", _} =
               Parser.parse("{{> loop}}", partials: %{loop: "x {{> loop}}"})
    end

    test "empty partial name" do
      assert {:error, "partial name is required in '{{> ...}}'", _} = Parser.parse("{{>}}")
    end

    test "tokenizer errors propagate" do
      assert {:error, "expected closing '}}' for Stem expression", _} = Parser.parse("{{oops")
    end

    test "errors inside a block body propagate" do
      assert {:error, "unknown partial 'missing'", _} =
               Parser.parse("{{#if a}}{{> missing}}{{/if}}")
    end

    test "mismatched closing tag after else" do
      assert {:error, "unexpected closing tag '{{/each}}'; expected '{{/if}}'", _} =
               Parser.parse("{{#if a}}x{{else}}y{{/each}}")
    end

    test "unclosed block after else" do
      assert {:error, "expected a closing '{{/if}}' for block expression in Stem", _} =
               Parser.parse("{{#if a}}x{{else}}y")
    end

    test "errors inside an else body propagate" do
      assert {:error, "unknown partial 'missing'", _} =
               Parser.parse("{{#if a}}x{{else}}{{> missing}}{{/if}}")
    end
  end

  test "accepts partials given as a keyword list" do
    assert ast("{{> g}}", partials: [g: "hi"]) == [{:text, "hi"}]
  end
end
