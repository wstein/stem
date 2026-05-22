# SPDX-License-Identifier: Apache-2.0

Code.require_file("../../test_helper.exs", __DIR__)

defmodule Stem.Bytecode.VMTest do
  # async: false because transformer dispatch reads the process-wide registry
  # (a :persistent_term), which other suites mutate; the setup clears it so the
  # secure capability-default assertions are deterministic.
  use ExUnit.Case, async: false
  use ExUnitProperties

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

    test "accessing a field on a non-map raises" do
      assert_raise ArgumentError, ~r/not a map/, fn ->
        render("{{user.name}}", assigns: %{user: 5})
      end
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

      assert render("{{name |> trim |> upcase}}",
               assigns: %{name: "  nina  "},
               transformers: transformers
             ) ==
               "NINA"
    end

    test "enforces the secure capability default through the dispatcher" do
      assert_raise Stem.SyntaxError, ~r/unknown transformer 'upcase'/, fn ->
        render("{{name |> upcase}}", assigns: %{name: "nina"})
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

  # ── Differential conformance: VM output must equal the compiled backend ──────

  describe "conformance with the compiled backend" do
    # Built at runtime: transformer maps hold closures, which cannot live in a
    # module attribute.
    defp conformance_transformers do
      Stem.Transformers.Standard.all()
      |> Map.merge(Stem.Transformers.Collections.all())
      |> Map.merge(%{"exclaim" => fn [v], _ctx -> "#{v}!" end})
    end

    @vectors [
      {"plain text only", "Just text, no tags.", %{}, []},
      {"escaped assign", "<p>{{body}}</p>", %{body: "<script>x</script>"}, []},
      {"raw assign", "<p>{{{body}}}</p>", %{body: "<b>ok</b>"}, []},
      {"missing assign", "[{{nope}}]", %{}, []},
      {"nested path", "{{user.name}} <{{user.email}}>", %{user: %{name: "Nina", email: "n@x.io"}},
       []},
      {"parent path resolves to top-level", "{{../title}}", %{title: "Home"}, []},
      {"string pipeline", "{{name |> trim |> upcase}}", %{name: "  nina  "}, []},
      {"collection pipeline", "{{tags |> join(\", \")}}", %{tags: ["a", "b", "c"]}, []},
      {"selector map", "{{users |> map(\"name\") |> join(\", \")}}",
       %{users: [%{name: "A"}, %{name: "B"}]}, []},
      {"default with literal", "{{default missing \"none\"}}", %{}, []},
      {"subexpression", "{{exclaim (upcase name)}}", %{name: "nina"}, []},
      {"json escape mode", "{{x}}", %{x: ~s(quote " here)}, [escape: :json]},
      {"numeric assign", "n={{n}}", %{n: 42}, []}
    ]

    for {label, source, assigns, opts} <- @vectors do
      test "matches for: #{label}" do
        source = unquote(source)
        assigns = unquote(Macro.escape(assigns))
        opts = unquote(opts)
        bindings = [assigns: assigns, transformers: conformance_transformers()]

        assert render_via_vm(source, bindings, opts) ==
                 render_via_compiler(source, bindings, opts)
      end
    end

    property "matches the compiled backend for random string pipelines" do
      transformers = Stem.Transformers.Strings.all()
      stages = StreamData.member_of(~w(trim upcase downcase capitalize reverse))

      check all(
              value <- StreamData.string(:printable, max_length: 16),
              pipeline <- StreamData.list_of(stages, max_length: 4)
            ) do
        source = "{{#{Enum.join(["s" | pipeline], " |> ")}}}"
        bindings = [assigns: %{s: value}, transformers: transformers]

        assert render_via_vm(source, bindings, []) ==
                 render_via_compiler(source, bindings, [])
      end
    end
  end

  defp render_via_vm(source, bindings, opts) do
    {:ok, ast} = Stem.Parser.parse_with_spans(source, opts)
    program = Bytecode.compile(ast, opts)
    {:ok, VM.render(program, bindings)}
  rescue
    _ -> :error
  end

  defp render_via_compiler(source, bindings, opts) do
    quoted = Stem.compile_string(source, opts)
    {result, _binding} = Code.eval_quoted(quoted, bindings)
    {:ok, result}
  rescue
    _ -> :error
  end
end
