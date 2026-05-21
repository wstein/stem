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
end
