# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.CompilerTest do
  use ExUnit.Case, async: true

  alias Stem.Compiler
  alias Stem.Parser

  defp render(template, assigns) do
    {:ok, ast} = Parser.parse(template)
    {result, _bindings} = Code.eval_quoted(Compiler.compile(ast), assigns: assigns)
    result
  end

  test "compile/1 uses default options" do
    {:ok, ast} = Parser.parse("hello")
    {result, _bindings} = Code.eval_quoted(Compiler.compile(ast))
    assert result == "hello"
  end

  test "unless with an else branch" do
    template = "{{#unless flag}}no{{else}}yes{{/unless}}"
    assert render(template, flag: true) == "yes"
    assert render(template, flag: false) == "no"
  end

  test "with renders the else branch for a falsy subject" do
    template = "{{#with v}}{{this}}{{else}}none{{/with}}"
    assert render(template, v: nil) == "none"
    assert render(template, v: 7) == "7"
  end

  test "block params resolve inside each and with bodies" do
    assert render("{{#each rows as |row idx|}}{{idx}}={{row.name}};{{/each}}",
             rows: [%{name: "a"}]
           ) ==
             "0=a;"

    assert render("{{#with story as |article|}}{{article.title}}{{/with}}",
             story: %{title: "Stem"}
           ) ==
             "Stem"
  end

  test "regions render through yields across inline partial layouts" do
    {:ok, ast} =
      Parser.parse("{{#region body}}<p>{{content}}</p>{{/region}}{{> layout}}",
        partials: %{layout: "<article>{{yield body}}</article>"}
      )

    {result, _bindings} = Code.eval_quoted(Compiler.compile(ast), assigns: [content: "Hello"])

    assert result == "<article><p>Hello</p></article>"
  end

  test "missing yields render as empty strings" do
    assert render("<main>{{yield body}}</main>", []) == "<main></main>"
  end

  test "recursive region yields raise a compile error" do
    {:ok, ast} = Parser.parse("{{#region body}}{{yield body}}{{/region}}{{yield body}}")

    assert_raise CompileError, ~r/recursive region yield detected for 'body'/, fn ->
      Compiler.compile(ast, file: "layout.stem")
    end
  end
end
