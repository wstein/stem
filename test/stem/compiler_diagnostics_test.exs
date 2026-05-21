# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.CompilerDiagnosticsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Stem.Compiler
  alias Stem.Parser

  defp compile_template(template) do
    {:ok, ast} = Parser.parse(template)
    Compiler.compile(ast, file: "diagnostics.stem", warn_on_diagnostics: true)
  end

  test "warns on constant conditions" do
    stderr =
      capture_io(:stderr, fn ->
        quoted = compile_template("{{#if true}}ok{{/if}}")
        Code.eval_quoted(quoted, assigns: %{}, helpers: [])
      end)

    assert stderr =~ "diagnostics.stem:1: if condition is constant"
  end

  test "warns on unused block params" do
    stderr =
      capture_io(:stderr, fn ->
        quoted = compile_template("{{#each rows as |row idx|}}{{row.name}}{{/each}}")
        Code.eval_quoted(quoted, assigns: %{rows: [%{name: "a"}]}, helpers: [])
      end)

    assert stderr =~ "unused each block parameter(s): idx"
  end

  test "warns on constant unless conditions and with block params" do
    stderr =
      capture_io(:stderr, fn ->
        quoted =
          compile_template(
            "{{#unless false}}ok{{/unless}}{{#with story as |article|}}{{this.title}}{{/with}}"
          )

        Code.eval_quoted(quoted, assigns: %{story: %{title: "Stem"}}, helpers: [])
      end)

    assert stderr =~ "unless condition is constant"
    assert stderr =~ "unused with block parameter(s): article"
  end

  test "diagnostics stay silent when not requested" do
    {:ok, ast} = Parser.parse("{{#if true}}ok{{/if}}")

    stderr =
      capture_io(:stderr, fn ->
        quoted = Compiler.compile(ast, file: "diagnostics.stem")
        Code.eval_quoted(quoted, assigns: %{}, helpers: [])
      end)

    assert stderr == ""
  end

  test "nested control-flow still counts block params as used" do
    template = """
    {{#each rows as |row|}}
      {{#if row.ok}}{{row.name}}{{/if}}
      {{#unless row.skip}}{{row.name}}{{/unless}}
      {{#with row as |item|}}{{item.name}}{{/with}}
      {{#each row.children}}{{row.name}}{{/each}}
    {{/each}}
    """

    stderr =
      capture_io(:stderr, fn ->
        quoted = compile_template(template)

        Code.eval_quoted(quoted,
          assigns: %{
            rows: [%{ok: true, skip: false, name: "root", children: [1]}]
          },
          helpers: []
        )
      end)

    assert stderr == ""
  end

  test "nested else branches still count block params as used" do
    template = """
    {{#each rows as |row|}}
      {{#if false}}{{else}}{{row.name}}{{/if}}
      {{#unless true}}{{else}}{{row.name}}{{/unless}}
      {{#each row.empty}}{{else}}{{row.name}}{{/each}}
      {{#with row.nothing}}{{else}}{{row.name}}{{/with}}
    {{/each}}
    """

    stderr =
      capture_io(:stderr, fn ->
        quoted = compile_template(template)

        Code.eval_quoted(quoted,
          assigns: %{rows: [%{name: "root", empty: [], nothing: nil}]},
          helpers: []
        )
      end)

    refute stderr =~ "unused each block parameter"
  end

  test "identifier tracking walks nested unless, each, and with nodes" do
    template = """
    {{#each rows as |row|}}
      {{#unless false}}
        {{#each row.children}}{{row.name}}{{/each}}
        {{#with row.meta}}{{row.name}}{{else}}{{row.name}}{{/with}}
      {{/unless}}
    {{/each}}
    """

    stderr =
      capture_io(:stderr, fn ->
        quoted = compile_template(template)

        Code.eval_quoted(quoted,
          assigns: %{rows: [%{name: "root", children: [1], meta: nil}]},
          helpers: []
        )
      end)

    refute stderr =~ "unused each block parameter"
  end

  test "identifier tracking counts else-only references across block types" do
    templates = [
      "{{#each rows as |row|}}{{#unless true}}{{else}}{{row.name}}{{/unless}}{{/each}}",
      "{{#each rows as |row|}}{{#each row.empty}}{{else}}{{row.name}}{{/each}}{{/each}}",
      "{{#each rows as |row|}}{{#with row.missing}}{{else}}{{row.name}}{{/with}}{{/each}}"
    ]

    Enum.each(templates, fn template ->
      stderr =
        capture_io(:stderr, fn ->
          quoted = compile_template(template)

          Code.eval_quoted(quoted,
            assigns: %{rows: [%{name: "root", empty: [], missing: nil}]},
            helpers: []
          )
        end)

      refute stderr =~ "unused each block parameter"
    end)
  end
end
