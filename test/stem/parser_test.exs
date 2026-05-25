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
             {:expr, {:identifier, "name"}, :default, %{line: 1, column: 4}},
             {:text, "!"}
           ]
  end

  test "if block without else" do
    assert [{:if, {:identifier, "show"}, [{:text, "yes"}], [], %{line: 1, column: 1}}] =
             ast("{{#if show}}yes{{/if}}")
  end

  test "if block with else" do
    assert [{:if, {:identifier, "show"}, [{:text, "yes"}], [{:text, "no"}], _}] =
             ast("{{#if show}}yes{{else}}no{{/if}}")
  end

  test "each, unless, with blocks" do
    assert [
             {:each, {:identifier, "items"}, [], [{:expr, {:special, :this}, :default, _}], [], _}
           ] =
             ast("{{#each items}}{{this}}{{/each}}")

    assert [{:unless, {:identifier, "flag"}, [{:text, "x"}], [], _}] =
             ast("{{#unless flag}}x{{/unless}}")

    assert [
             {:with, {:identifier, "story"}, [],
              [{:expr, {:path, :this, ["title"]}, :default, _}], [], _}
           ] =
             ast("{{#with story}}{{this.title}}{{/with}}")
  end

  test "region blocks and yields" do
    assert [
             {:region, "body", [{:text, "hi"}, {:yield, "sidebar", _}], _},
             {:yield, "body", _}
           ] = ast("{{#region body}}hi{{yield sidebar}}{{/region}}{{yield body}}")
  end

  test "nested blocks" do
    assert [
             {:each, {:identifier, "rows"}, [],
              [{:if, {:identifier, "ok"}, [{:text, "y"}], [], _}], [], _}
           ] = ast("{{#each rows}}{{#if ok}}y{{/if}}{{/each}}")
  end

  test "each and with block params are stored on block nodes" do
    assert [{:each, {:identifier, "items"}, ["item", "idx"], _, _, _}] =
             ast("{{#each items as |item idx|}}{{item}}:{{idx}}{{/each}}")

    assert [{:with, {:identifier, "story"}, ["article"], _, _, _}] =
             ast("{{#with story as |article|}}{{article.title}}{{/with}}")
  end

  test "invalid block param shapes are rejected" do
    assert {:error, "{{#with}} accepts at most one block parameter", _} =
             Parser.parse("{{#with story as |a b|}}{{a}}{{/with}}")

    assert {:error, "block parameters must be unique", _} =
             Parser.parse("{{#each items as |item item|}}{{item}}{{/each}}")

    assert {:ok, [{:each, _, ["item", "i0", "i1"], _, _, _}]} =
             Parser.parse("{{#each items as |item i0 i1|}}{{item}}{{/each}}")

    assert {:error, "{{#each}} accepts at most three block parameters", _} =
             Parser.parse("{{#each items as |item idx a b|}}{{item}}{{/each}}")

    assert {:error,
            "pipeline stages must be a helper name followed by space-separated arguments", _} =
             Parser.parse("{{#if name | String.trim()}}ok{{/if}}")
  end

  test "invalid region names are rejected" do
    assert {:error, "region name is required", _} = Parser.parse("{{yield}}")

    assert {:error, "region names must be simple identifiers", _} =
             Parser.parse("{{yield hero-body}}")

    assert {:error, "region names must be simple identifiers", _} =
             Parser.parse("{{#region hero-body}}x{{/region}}")
  end

  test "partials are expanded inline" do
    nodes = ast("a {{> greet}} b", partials: %{greet: "Hi {{name}}"})

    assert nodes == [
             {:text, "a "},
             {:text, "Hi "},
             {:expr, {:identifier, "name"}, :default, %{line: 1, column: 4}},
             {:text, " b"}
           ]
  end

  test "subexpressions are stored as expression AST" do
    assert [
             {:expr,
              {:transformer, "format", [{:transformer, "uppercase", [{:identifier, "name"}]}]},
              :default, _}
           ] =
             ast("{{format (uppercase name)}}")
  end

  test "partials may reference other partials" do
    nodes =
      ast("{{> outer}}", partials: %{outer: "[{{> inner}}]", inner: "x"})

    assert nodes == [{:text, "["}, {:text, "x"}, {:text, "]"}]
  end

  test "partial with a context argument produces a scope node" do
    nodes = ast("{{> card user}}", partials: %{card: "{{name}}"})

    assert [
             {:partial_scope, {:identifier, "user"}, [],
              [{:expr, {:identifier, "name"}, :default, _}], _}
           ] = nodes
  end

  test "partial with hash arguments produces a scope node" do
    nodes = ast(~s({{> card label="Hi"}}), partials: %{card: "{{label}}"})

    assert [{:partial_scope, nil, [label: {:literal, ~s("Hi")}], _body, _}] = nodes
  end

  test "partial with context and hash arguments produces a scope node" do
    nodes = ast(~s({{> card user role="admin"}}), partials: %{card: "{{name}}"})

    assert [
             {:partial_scope, {:identifier, "user"}, [role: {:literal, ~s("admin")}], _body, _}
           ] = nodes
  end

  test "partial without arguments expands inline without a scope node" do
    assert ast("{{> g}}", partials: %{g: "x"}) == [{:text, "x"}]
  end

  test "partials reject more than one context argument" do
    assert {:error, "partials accept at most one context argument before key=value pairs", _} =
             Parser.parse("{{> card a b}}", partials: %{card: "x"})
  end

  test "partials reject malformed arguments" do
    assert {:error, "partial arguments must be assigns, paths, literals, or key=value pairs", _} =
             Parser.parse("{{> card 1+2}}", partials: %{card: "x"})
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

    test "else inside region is rejected" do
      assert {:error, "unexpected '{{else}}' inside '{{#region}}'", _} =
               Parser.parse("{{#region body}}x{{else}}y{{/region}}")
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

    test "nested-brace syntax errors propagate" do
      assert {:error, "nested braces are not supported in Stem expressions", _} =
               Parser.parse("{{ {name} }}")
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
