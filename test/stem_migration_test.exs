# SPDX-License-Identifier: Apache-2.0

Code.require_file("test_helper.exs", __DIR__)

defmodule Stem.StemMigrationTest do
  use ExUnit.Case, async: false

  setup do
    Stem.Helpers.clear()
    :ok
  end

  test "double braces resolve assigns without HTML escaping" do
    template = "Hello {{name}}"

    assert Stem.TestTemplate.eval_string(template, assigns: [name: "<b>World</b>"]) ==
             "Hello <b>World</b>"
  end

  test "triple braces are rejected" do
    template = "Hello {{{name}}}"

    assert_raise Stem.SyntaxError,
                 ~r/unsupported Stem expression '\{\{\{\.\.\.\}\}\}'; use '\{\{\.\.\.\}\}'/,
                 fn ->
                   Stem.TestTemplate.eval_string(template, assigns: [name: "<b>World</b>"])
                 end
  end

  test "stem comments are discarded" do
    assert Stem.TestTemplate.eval_string("a{{! comment }}b", []) == "ab"
    assert Stem.TestTemplate.eval_string("a{{!-- comment --}}b", []) == "ab"
  end

  test "unterminated stem expression raises syntax error" do
    assert_raise Stem.SyntaxError, ~r/expected closing '\}\}' for Stem expression/, fn ->
      Stem.TestTemplate.eval_string("{{name", assigns: [name: "World"])
    end
  end

  test "if block helper with else" do
    template = "{{#if show}}yes{{else}}no{{/if}}"
    assert Stem.TestTemplate.eval_string(template, assigns: [show: true]) == "yes"
    assert Stem.TestTemplate.eval_string(template, assigns: [show: false]) == "no"
  end

  test "missing values in conditionals are silent by default" do
    template = Path.expand("fixtures/stem_template_condition.stem", __DIR__)

    assert Stem.TestTemplate.eval_file(template, assigns: []) == "foo \n"
  end

  test "compound truthy condition renders with Elixir semantics" do
    template = Path.expand("fixtures/stem_template_truthy_condition.stem", __DIR__)

    render_output = fn value, fallback ->
      String.trim(
        Stem.TestTemplate.eval_file(template, assigns: [render: value, fallback: fallback])
      )
    end

    assert render_output.(1, false) == "Does render!"
    assert render_output.(0, false) == ""
    assert render_output.(0, true) == "Does render!"
    assert render_output.(true, false) == "Does render!"
    assert render_output.(false, true) == "Does render!"
    assert render_output.(nil, false) == ""
    assert render_output.([], false) == "Does render!"
  end

  test "each block helper with this context" do
    template = "{{#each items}}[{{this}}]{{/each}}"
    assert Stem.TestTemplate.eval_string(template, assigns: [items: ["a", "b"]]) == "[a][b]"
  end

  test "partials from compile options" do
    template = "before {{> greet}} after"
    partials = %{greet: "Hello {{name}}"}

    assert Stem.TestTemplate.eval_string(template, [assigns: [name: "Nina"]], partials: partials) ==
             "before Hello Nina after"
  end

  test "helper registry resolves inline helpers" do
    Stem.Helpers.register(:upcase, fn [value], _ctx -> String.upcase(to_string(value)) end)
    assert Stem.TestTemplate.eval_string("{{upcase name}}", assigns: [name: "nina"]) == "NINA"
  end

  test "local helper bindings can be passed via eval options" do
    helpers = [suffix: fn [value, suffix], _ctx -> "#{value}#{suffix}" end]

    assert Stem.TestTemplate.eval_string("{{suffix name \"!\"}}", [assigns: [name: "nina"]],
             helpers: helpers
           ) ==
             "nina!"
  end

  test "helper calls accept positional and keyword arguments" do
    template = Path.expand("fixtures/stem_template_with_helpers.stem", __DIR__)

    helpers = [
      progress: fn [label, percent, done], _ctx -> "#{label}:#{percent}:#{done}" end,
      link: fn [label, href: href, class: class_name], _ctx ->
        "<a class=\"#{class_name}\" href=\"#{href}\">#{label}</a>"
      end
    ]

    output =
      Stem.TestTemplate.eval_file(
        template,
        [assigns: [person: %{url: "https://yehudakatz.com/"}]],
        helpers: helpers
      )

    assert output |> String.split("\n", trim: true) == [
             "Search:10:false",
             "Upload:90:true",
             "Finish:100:false",
             "<a class=\"person\" href=\"https://yehudakatz.com/\">See Website</a>"
           ]
  end

  test "helper can use current each-item context" do
    Stem.Helpers.register(:wrap, fn [value], %{this: this} -> "#{value}:#{this}" end)
    template = "{{#each items}}({{this}}:{{wrap \"item\"}}){{/each}}"

    assert Stem.TestTemplate.eval_string(template, assigns: [items: [1, 2]]) ==
             "(1:item:1)(2:item:2)"
  end

  test "double braces preserve apostrophe and quotes" do
    assert Stem.TestTemplate.eval_string("{{name}}", assigns: [name: "'\""]) == "'\""
  end

  test "missing assign renders as empty string" do
    assert Stem.TestTemplate.eval_string("x{{missing}}y", assigns: []) == "xy"
  end

  test "each over empty list renders empty block body" do
    assert Stem.TestTemplate.eval_string("a{{#each items}}x{{/each}}b", assigns: [items: []]) ==
             "ab"
  end
end
