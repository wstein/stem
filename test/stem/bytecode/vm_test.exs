# SPDX-License-Identifier: Apache-2.0

Code.require_file("../../test_helper.exs", __DIR__)

defmodule Stem.Bytecode.VMTest do
  # async: false because transformer dispatch reads the process-wide registry
  # (a :persistent_term), which other suites mutate; the setup clears it so the
  # secure capability-default assertions are deterministic.
  use ExUnit.Case, async: false

  alias Stem.Bytecode
  alias Stem.Bytecode.VM

  doctest Stem.Bytecode.VM

  setup do
    Stem.Transformers.clear()
    :ok
  end

  defp render(source, bindings, opts \\ []) do
    {:ok, ast} = Stem.Parser.parse_with_spans(source, opts)
    program = Bytecode.compile(ast, opts)
    VM.render(program, bindings)
  end

  describe "render/2" do
    test "renders a text-only program with no bindings" do
      {:ok, ast} = Stem.Parser.parse_with_spans("static text")
      assert VM.render(Bytecode.compile(ast)) == "static text"
    end

    test "interleaves literal text and assigns" do
      assert render("Hello {{name}}!", assigns: [name: "Nina"]) == "Hello Nina!"
    end

    test "a missing assign resolves to an empty string" do
      assert render("[{{missing}}]", assigns: []) == "[]"
    end

    test "resolves dotted paths over maps" do
      assert render("{{user.profile.name}}", assigns: %{user: %{profile: %{name: "Nina"}}}) ==
               "Nina"
    end

    test "accessing a field on a non-map or a missing key renders empty" do
      assert render("{{user.name}}", assigns: %{user: 5}) == ""
      assert render("[{{user.name}}]", assigns: %{user: %{}}) == "[]"
    end

    test "escapes HTML by default and leaves raw triple-stash unescaped" do
      assert render("{{x}}", assigns: %{x: "<b>&"}) == "&lt;b&gt;&amp;"
      assert render("{{{x}}}", assigns: %{x: "<b>&"}) == "<b>&"
    end

    test "honors the compile-time escape mode" do
      assert render("{{x}}", [assigns: %{x: ~s(a"b)}], escape: :json) == ~s(a\\"b)
      assert render("{{x}}", [assigns: %{x: "<b>"}], escape: :none) == "<b>"
    end

    test "applies built-in transformers when their group is loaded" do
      transformers = Stem.Transformers.Strings.all()

      assert render("{{name | trim | upcase}}",
               assigns: %{name: "  nina  "},
               transformers: transformers
             ) ==
               "NINA"
    end

    test "enforces the secure capability default through the dispatcher" do
      assert_raise Stem.SyntaxError, ~r/unknown transformer 'upcase'/, fn ->
        render("{{name | upcase}}", assigns: %{name: "nina"})
      end
    end

    test "invokes custom transformers passed in the binding" do
      transformers = %{"wrap" => fn [value], _ctx -> "[#{value}]" end}
      assert render("{{wrap name}}", assigns: %{name: "x"}, transformers: transformers) == "[x]"
    end

    test "evaluates keyword arguments and appends them to the call" do
      transformers = %{
        "suffix" => fn [value | opts], _ctx -> "#{value}#{Keyword.get(opts, :with, "")}" end
      }

      assert render("{{suffix name with=\"!\"}}",
               assigns: %{name: "Nina"},
               transformers: transformers
             ) == "Nina!"
    end

    test "passes literal arguments through to transformers" do
      assert render("{{default missing \"fallback\"}}", assigns: []) == "fallback"
      assert render("{{default name \"fallback\"}}", assigns: %{name: "given"}) == "given"
    end
  end

  describe "render/2 block helpers" do
    test "renders if/unless conditionals" do
      assert render("{{#if ok}}Y{{else}}N{{/if}}", assigns: %{ok: true}) == "Y"
      assert render("{{#if ok}}Y{{else}}N{{/if}}", assigns: %{ok: false}) == "N"
      assert render("{{#unless ok}}hidden{{/unless}}", assigns: %{ok: false}) == "hidden"
    end

    test "iterates with this, @index, @key, and block parameters" do
      assert render("{{#each xs}}{{@index}}:{{@this}} {{/each}}", assigns: %{xs: ["a", "b"]}) ==
               "0:a 1:b "

      assert render("{{#each xs as |item|}}<{{item}}>{{/each}}", assigns: %{xs: ["a", "b"]}) ==
               "<a><b>"

      assert render("{{#each xs as |x i|}}{{i}}={{x}};{{/each}}", assigns: %{xs: ["a", "b"]}) ==
               "0=a;1=b;"

      assert render("{{#each m}}{{@key}}={{@this}} {{/each}}", assigns: %{m: %{a: 1}}) == "a=1 "
    end

    test "binds @index1 and the three-param each form (item, index0, index1)" do
      assert render("{{#each xs}}{{@index1}} {{/each}}", assigns: %{xs: ["a", "b"]}) == "1 2 "

      assert render("{{#each xs as |item i0 i1|}}{{item}}@{{i0}}/{{i1}};{{/each}}",
               assigns: %{xs: ["a", "b"]}
             ) == "a@0/1;b@1/2;"
    end

    test "two-param each binds the map key" do
      assert render("{{#each m as |v k|}}{{k}}={{v}} {{/each}}", assigns: %{m: %{role: "admin"}}) ==
               "role=admin "
    end

    test "renders the else branch for an empty collection" do
      assert render("{{#each xs}}{{@this}}{{else}}empty{{/each}}", assigns: %{xs: []}) == "empty"
    end

    test "binds the subject of with and falls back on a falsy subject" do
      assert render("{{#with u}}{{@this.name}}{{/with}}", assigns: %{u: %{name: "Nina"}}) ==
               "Nina"

      assert render("{{#with u as |x|}}{{x.name}}{{/with}}", assigns: %{u: %{name: "A"}}) == "A"
      assert render("{{#with u}}x{{else}}none{{/with}}", assigns: %{u: nil}) == "none"
    end

    test "reaches the parent scope from inside a loop" do
      assert render("{{#each xs}}{{@parent.sep}}{{@this}}{{/each}}",
               assigns: %{xs: ["a", "b"], sep: "-"}
             ) ==
               "-a-b"
    end

    test "inlines a yielded region" do
      assert render("{{#region b}}Hi {{name}}{{/region}}<x>{{yield b}}</x>",
               assigns: %{name: "Y"}
             ) ==
               "<x>Hi Y</x>"
    end
  end

  describe "render/2 literal variable keys" do
    test "resolves a bracketed literal assign key" do
      assert render("{{[first-name]}}", assigns: %{:"first-name" => "Ada"}) == "Ada"
    end

    test "resolves a bracketed literal path segment" do
      assert render("{{user.[first-name]}}", assigns: %{user: %{:"first-name" => "Grace"}}) ==
               "Grace"
    end

    test "resolves an uppercase block param and literal item field" do
      assert render(
               "{{#each people as |p _ I1|}}{{I1}}:{{p.[first-name]}} {{/each}}",
               assigns: %{people: [%{:"first-name" => "Ada"}, %{:"first-name" => "Grace"}]}
             ) == "1:Ada 2:Grace "
    end
  end

  describe "render/2 partial arguments" do
    test "context argument sets the partial scope" do
      assert render("{{> card user}}", [assigns: [user: %{name: "Nina"}]],
               partials: %{card: "Name: {{name}}"}
             ) == "Name: Nina"
    end

    test "hash arguments are available by name" do
      assert render(~s({{> badge label="VIP"}}), [assigns: []], partials: %{badge: "[{{label}}]"}) ==
               "[VIP]"
    end

    test "hash arguments override matching context keys" do
      assert render(~s({{> card user name="Override"}}), [assigns: [user: %{name: "Nina"}]],
               partials: %{card: "{{name}}"}
             ) == "Override"
    end

    test "context argument works inside each" do
      assert render(
               "{{#each users}}{{> card @this}}{{/each}}",
               [assigns: [users: [%{name: "A"}, %{name: "B"}]]],
               partials: %{card: "[{{name}}]"}
             ) == "[A][B]"
    end

    test "hash arguments combine with an inherited caller scope" do
      assert render(~s({{> line label="Total"}}), [assigns: [amount: 42]],
               partials: %{line: "{{label}}: {{amount}}"}
             ) == "Total: 42"
    end

    test "scalar context argument yields an empty scope" do
      assert render("{{> card greeting}}", [assigns: [greeting: "hi"]],
               partials: %{card: "[{{name}}]"}
             ) == "[]"
    end
  end
end
