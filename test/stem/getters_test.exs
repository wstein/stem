# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.GettersTest do
  use ExUnit.Case, async: true

  # ST4-style computed getters: a zero-arity function assign value is invoked
  # during resolution and its result rendered. The template can't pass
  # arguments, so it stays declarative — a getter is just a backend-authored
  # assign with lazy/encapsulated evaluation.

  defp render(template, assigns, transformers \\ %{}) do
    Stem.Unsafe.eval_string(template, assigns: assigns, transformers: transformers)
  end

  defp vm_render(template, assigns, transformers \\ %{}) do
    {:ok, ast} = Stem.Parser.parse_with_spans(template)
    program = Stem.Bytecode.compile(ast)
    Stem.Bytecode.VM.render(program, assigns: assigns, transformers: transformers)
  end

  describe "top-level computed getters (compiled backend)" do
    test "a zero-arity function assign is invoked and rendered" do
      assert render("{{full_name}}", %{full_name: fn -> "Ada Lovelace" end}) == "Ada Lovelace"
    end

    test "the getter result is HTML-escaped like any other value" do
      assert render("{{bio}}", %{bio: fn -> "<b>hi</b>" end}) == "&lt;b&gt;hi&lt;/b&gt;"
    end

    test "a getter feeds a transformer pipeline" do
      assert render(
               "{{name | upcase}}",
               %{name: fn -> "ada" end},
               Stem.Transformers.Strings.all()
             ) ==
               "ADA"
    end

    test "a getter is evaluated for block truthiness" do
      template = "{{#if active}}on{{else}}off{{/if}}"
      assert render(template, %{active: fn -> true end}) == "on"
      assert render(template, %{active: fn -> false end}) == "off"
    end

    test "a getter can back an each collection" do
      assert render("{{#each names}}{{this}};{{/each}}", %{names: fn -> ["a", "b"] end}) == "a;b;"
    end

    test "a getter returning a map is bound by with, including nested access" do
      assert render("{{#with user}}{{this.name}}{{/with}}", %{user: fn -> %{name: "Ada"} end}) ==
               "Ada"
    end

    test "non-function assigns are unaffected" do
      assert render("{{greeting}}", %{greeting: "hi"}) == "hi"
    end
  end

  describe "top-level computed getters (bytecode VM)" do
    test "the VM invokes a zero-arity getter assign" do
      assert vm_render("{{full_name}}", %{full_name: fn -> "Ada" end}) == "Ada"
    end

    test "the VM evaluates a getter for block truthiness and iteration" do
      assert vm_render("{{#if on}}Y{{/if}}", %{on: fn -> true end}) == "Y"
      assert vm_render("{{#each xs}}{{this}}{{/each}}", %{xs: fn -> [1, 2] end}) == "12"
    end
  end

  describe "getters at a dotted-path leaf / consumption points" do
    test "a leaf getter on a nested map is invoked when rendered" do
      assigns = %{user: %{full_name: fn -> "Ada Lovelace" end}}
      assert render("{{user.full_name}}", assigns) == "Ada Lovelace"
      assert vm_render("{{user.full_name}}", assigns) == "Ada Lovelace"
    end

    test "a leaf getter feeds a transformer pipeline" do
      assigns = %{user: %{name: fn -> "ada" end}}
      strings = Stem.Transformers.Strings.all()
      assert render("{{user.name | upcase}}", assigns, strings) == "ADA"
      assert vm_render("{{user.name | upcase}}", assigns, strings) == "ADA"
    end

    test "a leaf getter is evaluated for block truthiness" do
      assert render("{{#if user.active}}on{{else}}off{{/if}}", %{user: %{active: fn -> false end}}) ==
               "off"
    end

    test "a leaf getter returning a map is bound by with" do
      assigns = %{data: %{profile: fn -> %{name: "Ada"} end}}
      assert render("{{#with data.profile}}{{this.name}}{{/with}}", assigns) == "Ada"
    end

    test "a leaf getter passed as a transformer argument is invoked" do
      assigns = %{user: %{name: nil, fallback: fn -> "computed" end}}
      assert render("{{default user.name user.fallback}}", assigns) == "computed"
    end
  end
end
