# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.BuiltinHelpersGuideTest do
  use ExUnit.Case, async: false

  describe "if helper examples" do
    test "basic if block" do
      template = "{{#if isActive}}active{{/if}}"
      assert Stem.TestTemplate.eval_string(template, assigns: [isActive: true]) == "active"
      assert Stem.TestTemplate.eval_string(template, assigns: [isActive: false]) == ""
    end

    test "if block with else" do
      template = "{{#if isActive}}active{{else}}inactive{{/if}}"
      assert Stem.TestTemplate.eval_string(template, assigns: [isActive: true]) == "active"
      assert Stem.TestTemplate.eval_string(template, assigns: [isActive: false]) == "inactive"
    end

    test "if treats Handlebars falsey values as empty" do
      template = "{{#if value}}non-empty{{else}}empty{{/if}}"

      assert Stem.TestTemplate.eval_string(template, assigns: [value: 0]) == "empty"
      assert Stem.TestTemplate.eval_string(template, assigns: [value: ""]) == "empty"
      assert Stem.TestTemplate.eval_string(template, assigns: [value: []]) == "empty"
      assert Stem.TestTemplate.eval_string(template, assigns: [value: 1]) == "non-empty"
    end
  end

  describe "unless helper examples" do
    test "basic unless block" do
      template = "{{#unless isActive}}inactive{{/unless}}"
      assert Stem.TestTemplate.eval_string(template, assigns: [isActive: false]) == "inactive"
      assert Stem.TestTemplate.eval_string(template, assigns: [isActive: true]) == ""
    end
  end

  describe "each helper examples" do
    test "iterate list values" do
      template = "{{#each items}}<li>{{this}}</li>{{/each}}"

      assert Stem.TestTemplate.eval_string(template, assigns: [items: ["a", "b"]]) ==
               "<li>a</li><li>b</li>"
    end

    test "index access with @index" do
      template = "{{#each items}}{{@index}}:{{this}};{{/each}}"
      assert Stem.TestTemplate.eval_string(template, assigns: [items: ["a", "b"]]) == "0:a;1:b;"
    end

    test "object iteration with @key" do
      template = "{{#each map}}{{@key}}: {{this}}{{/each}}"

      assert Stem.TestTemplate.eval_string(template, assigns: [map: %{firstName: "Homer"}]) ==
               "firstName: Homer"
    end

    test "each with else" do
      template = "{{#each items}}{{this}}{{else}}empty{{/each}}"
      assert Stem.TestTemplate.eval_string(template, assigns: [items: []]) == "empty"
    end
  end

  describe "with helper examples" do
    test "basic with block" do
      template = "{{#with story}}{{this.title}} by {{this.author}}{{/with}}"
      assigns = [story: %{title: "The Story", author: "A. Writer"}]

      assert Stem.TestTemplate.eval_string(template, assigns: assigns) ==
               "The Story by A. Writer"
    end

    test "with uses Handlebars truthiness (0, empty string are falsey)" do
      template = "{{#with value}}{{this}}{{else}}empty{{/with}}"

      assert Stem.TestTemplate.eval_string(template, assigns: [value: 0]) == "empty"
      assert Stem.TestTemplate.eval_string(template, assigns: [value: ""]) == "empty"
      assert Stem.TestTemplate.eval_string(template, assigns: [value: 1]) == "1"
      assert Stem.TestTemplate.eval_string(template, assigns: [value: "text"]) == "text"
    end
  end

  describe "lookup helper examples" do
    test "lookup map value by key" do
      template = "{{lookup person \"firstName\"}}"
      assigns = [person: %{"firstName" => "Nils"}]
      assert Stem.TestTemplate.eval_string(template, assigns: assigns) == "Nils"
    end

    test "lookup list value by index" do
      template = "{{lookup values 1}}"
      assert Stem.TestTemplate.eval_string(template, assigns: [values: ["a", "b"]]) == "b"
    end
  end

  describe "log helper examples" do
    test "log helper writes to stderr and returns empty output" do
      template = "X{{log \"hello\" name}}Y"

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Stem.TestTemplate.eval_string(template, assigns: [name: "world"]) == "XY"
        end)

      assert stderr =~ "hello world"
    end

    test "log with level hash argument" do
      template = "{{log \"hello\" level=\"debug\"}}"
      assert Stem.TestTemplate.eval_string(template, assigns: []) == ""
    end
  end

  describe "pipeline helper examples" do
    test "text pipelines compose built-in helpers" do
      template = "{{name |> trim |> upcase |> truncate(4)}}"

      assert Stem.TestTemplate.eval_string(template, assigns: [name: "  nina  "]) == "NINA"
    end

    test "collection pipelines stay declarative with selector helpers" do
      template = "{{people |> sort_by(\"name\") |> map(\"name\") |> join(\", \")}}"

      assigns = [people: [%{name: "Mila"}, %{name: "Ada"}, %{name: "Nina"}]]

      assert Stem.TestTemplate.eval_string(template, assigns: assigns) == "Ada, Mila, Nina"
    end

    test "default helper fills empty values" do
      assert Stem.TestTemplate.eval_string("{{nickname |> default(\"friend\")}}",
               assigns: [nickname: nil]
             ) ==
               "friend"
    end
  end
end
