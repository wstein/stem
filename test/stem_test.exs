# SPDX-License-Identifier: Apache-2.0

Code.require_file("test_helper.exs", __DIR__)

require Stem

defmodule StemTest.Compiled do
  require Stem

  def before_compile, do: {__ENV__.line, hd(tl(get_stacktrace()))}

  Stem.function_from_string(:def, :string_sample, "{{a}}", [:assigns])

  filename = Path.join(__DIR__, "fixtures/stem_template_with_bindings.stem")
  Stem.function_from_file(:defp, :private_file_sample, filename, [:assigns])

  filename = Path.join(__DIR__, "fixtures/stem_template_with_bindings.stem")
  Stem.function_from_file(:def, :public_file_sample, filename, [:assigns])

  def file_sample(arg), do: private_file_sample(arg)

  def after_compile, do: {__ENV__.line, hd(tl(get_stacktrace()))}

  @file "unknown"
  def unknown, do: {__ENV__.line, hd(tl(get_stacktrace()))}

  defp get_stacktrace do
    try do
      :erlang.error("failed")
    rescue
      _ -> __STACKTRACE__
    end
  end
end

defmodule StemTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  doctest Stem

  setup do
    Stem.Helpers.clear()
    :ok
  end

  defp eval(template, bindings \\ [], opts \\ []) do
    Stem.TestTemplate.eval_string(template, bindings, Keyword.put_new(opts, :file, __ENV__.file))
  end

  describe "text and expressions" do
    test "plain text passes through" do
      assert eval("foo bar") == "foo bar"
    end

    test "expressions render without HTML escaping with triple braces" do
      assert eval("{{{x}}}", assigns: [x: ~s(<b>&"')]) == ~s(<b>&"')
    end

    test "expressions render with HTML escaping by default" do
      assert eval("{{x}}", assigns: [x: ~s(<b>&"')]) == ~s(&lt;b&gt;&amp;&quot;&#39;)
    end

    test "missing assigns render as empty string" do
      assert eval("x{{missing}}y", assigns: []) == "xy"
    end

    test "short and block comments are discarded" do
      assert eval("a{{! note }}b{{!-- block --}}c") == "abc"
    end

    test "nested braces are not supported" do
      assert_raise Stem.SyntaxError,
                   ~r/nested braces are not supported in Stem expressions/,
                   fn ->
                     eval("{{ {x} }}", assigns: [x: "<b>World</b>"])
                   end
    end

    test "compound Elixir expressions resolve assigns when allow_elixir_expressions: true" do
      assert eval("{{a + b}}", [assigns: [a: 1, b: 2]], allow_elixir_expressions: true) == "3"
    end

    test "arbitrary Elixir is rejected by default (allow_elixir_expressions: false)" do
      assert_raise CompileError, ~r/arbitrary Elixir expressions are not allowed/, fn ->
        eval("{{a + b}}", assigns: [a: 1, b: 2])
      end
    end

    test "whitespace control trims adjacent literal whitespace" do
      assert eval("a {{~name~}} b", assigns: [name: "Nina"]) == "aNinab"
    end

    test "one-sided whitespace control trims only one side" do
      assert eval("a {{~name}} b", assigns: [name: "Nina"]) == "aNina b"
      assert eval("a {{name~}} b", assigns: [name: "Nina"]) == "a Ninab"
    end

    test "dotted paths read nested values" do
      assert eval("{{user.name}}", assigns: [user: %{name: "Nina"}]) == "Nina"
    end

    test "pipelines compose helpers in declaration order" do
      helpers = [
        trim: fn [value], _ctx -> String.trim(to_string(value)) end,
        upcase: fn [value], _ctx -> String.upcase(to_string(value)) end,
        truncate: fn [value, count], _ctx -> String.slice(to_string(value), 0, count) end
      ]

      assert eval(
               "{{name |> trim |> upcase |> truncate(4)}}",
               [assigns: [name: "  nina  "]],
               helpers: helpers
             ) == "NINA"
    end

    test "booleans and nil pass through" do
      assert eval("{{true}} {{nil}}") == "true "
    end
  end

  describe "blocks" do
    test "if/else" do
      assert eval("{{#if ok}}yes{{else}}no{{/if}}", assigns: [ok: true]) == "yes"
      assert eval("{{#if ok}}yes{{else}}no{{/if}}", assigns: [ok: false]) == "no"
    end

    test "unless" do
      assert eval("{{#unless ok}}no{{/unless}}", assigns: [ok: false]) == "no"
      assert eval("{{#unless ok}}no{{/unless}}", assigns: [ok: true]) == ""
    end

    test "blocks follow Handlebars truthiness" do
      assert eval("{{#if v}}t{{else}}f{{/if}}", assigns: [v: 0]) == "f"
      assert eval("{{#unless v}}t{{else}}f{{/unless}}", assigns: [v: ""]) == "t"
      assert eval("{{#if v}}t{{else}}f{{/if}}", assigns: [v: []]) == "f"
      assert eval("{{#if v}}t{{else}}f{{/if}}", assigns: [v: nil]) == "f"
    end

    test "each iterates with this, @index, and @key" do
      assert eval("{{#each xs}}{{@index}}:{{this}};{{/each}}", assigns: [xs: ["a", "b"]]) ==
               "0:a;1:b;"

      assert eval("{{#each m}}{{@key}}={{this}}{{/each}}", assigns: [m: %{a: 1}]) == "a=1"
    end

    test "each else renders for empty collections" do
      assert eval("{{#each xs}}{{this}}{{else}}empty{{/each}}", assigns: [xs: []]) == "empty"
    end

    test "with binds this" do
      assigns = [story: %{title: "T", author: "A"}]

      assert eval("{{#with story}}{{this.title}} by {{this.author}}{{/with}}", assigns: assigns) ==
               "T by A"
    end

    test "nested blocks" do
      template = "{{#each rows}}{{#if this}}[{{this}}]{{/if}}{{/each}}"
      assert eval(template, assigns: [rows: [1, false, 2]]) == "[1][2]"
    end

    test "parent traversal reaches top-level assigns inside each" do
      assigns = [prefix: "Mr.", people: [%{firstname: "Nina"}]]

      assert eval("{{#each people}}{{../prefix}} {{firstname}}{{/each}}", assigns: assigns) ==
               "Mr. Nina"
    end

    test "whitespace control works around block tags" do
      assert eval(" {{~#if ok~}} yes {{~/if~}} ", assigns: [ok: true]) == "yes"
    end

    test "one-sided whitespace control works around block tags" do
      assert eval(" {{~#if ok}}yes{{/if}} ", assigns: [ok: true]) == "yes "
      assert eval(" {{#if ok~}}yes{{/if}} ", assigns: [ok: true]) == " yes "
    end

    test "each block params bind item and index" do
      assert eval("{{#each xs as |item idx|}}{{idx}}:{{item}};{{/each}}",
               assigns: [xs: ["a", "b"]]
             ) ==
               "0:a;1:b;"
    end

    test "with block params bind the subject" do
      assigns = [story: %{title: "Deep Work", author: "N"}]

      assert eval("{{#with story as |article|}}{{article.title}} by {{article.author}}{{/with}}",
               assigns: assigns
             ) ==
               "Deep Work by N"
    end
  end

  describe "helpers" do
    test "registered helper" do
      Stem.Helpers.register(:upcase, fn [v], _ctx -> String.upcase(to_string(v)) end)
      assert eval("{{upcase name}}", assigns: [name: "nina"]) == "NINA"
    end

    test "builtin lookup helper" do
      assert eval(~s({{lookup m "k"}}), assigns: [m: %{"k" => "v"}]) == "v"
    end

    test "builtin pipelines cover text and collection transforms" do
      assigns = [
        name: "  nina west  ",
        people: [%{name: "mila"}, %{name: "nina"}, %{name: "ada"}],
        flags: [true, nil, false, true]
      ]

      assert eval("{{name |> trim |> upcase |> truncate(4)}}", assigns: assigns) == "NINA"

      assert eval("{{people |> sort_by(\"name\") |> map(\"name\") |> join(\", \")}}",
               assigns: assigns
             ) == "ada, mila, nina"

      assert eval("{{flags |> compact |> uniq |> join(\",\")}}", assigns: assigns) ==
               "true,false"
    end

    test "helper with positional and keyword arguments" do
      helpers = [tag: fn [label, href: href], _ctx -> "#{label}@#{href}" end]

      assert eval(~s({{tag name href=url}}), [assigns: [name: "x", url: "u"]], helpers: helpers) ==
               "x@u"
    end

    test "subexpressions compose helpers" do
      helpers = [
        uppercase: fn [value], _ctx -> String.upcase(to_string(value)) end,
        format: fn [value], _ctx -> "[#{value}]" end
      ]

      assert eval("{{format (uppercase name)}}", [assigns: [name: "nina"]], helpers: helpers) ==
               "[NINA]"
    end
  end

  describe "partials" do
    test "expands partials from options" do
      assert eval("a {{> g}} b", [assigns: [name: "Nina"]], partials: %{g: "Hi {{name}}"}) ==
               "a Hi Nina b"
    end

    test "nested partial layouts inherit ambient assigns" do
      partials = %{
        layout: "<article>{{> header}}<main>{{> body}}</main>{{> footer}}</article>",
        header: "<h1>{{title}}</h1>",
        body: "{{content}}",
        footer: "<small>{{site_name}}</small>"
      }

      assert eval(
               "{{> layout}}",
               [assigns: [title: "Stem", content: "Hello", site_name: "Docs"]],
               partials: partials
             ) ==
               "<article><h1>Stem</h1><main>Hello</main><small>Docs</small></article>"
    end
  end

  describe "precompiled functions" do
    test "function_from_string" do
      assert StemTest.Compiled.string_sample(a: 3) == "3"
    end

    test "function_from_file (public and private)" do
      assert normalize(StemTest.Compiled.file_sample(bar: 1)) == "foo 1\n"
      assert normalize(StemTest.Compiled.public_file_sample(bar: 1)) == "foo 1\n"
    end

    test "sets the external resource attribute" do
      assert StemTest.Compiled.__info__(:attributes)[:external_resource] ==
               [Path.join(__DIR__, "fixtures/stem_template_with_bindings.stem")]
    end

    test "compiled template functions keep accurate stack metadata" do
      file = to_charlist(Path.relative_to_cwd(__ENV__.file))

      {line, frame} = StemTest.Compiled.before_compile()
      assert frame == {StemTest.Compiled, :before_compile, 0, [file: file, line: line]}

      {line, frame} = StemTest.Compiled.after_compile()
      assert frame == {StemTest.Compiled, :after_compile, 0, [file: file, line: line]}

      {line, frame} = StemTest.Compiled.unknown()
      assert frame == {StemTest.Compiled, :unknown, 0, [file: ~c"unknown", line: line]}
    end
  end

  describe "assigns" do
    test "warns on missing assigns when requested" do
      stderr =
        capture_io(:stderr, fn ->
          assert Stem.TestTemplate.eval_string("{{foo}}", [assigns: []],
                   file: __ENV__.file,
                   warn_on_missing_assigns: true
                 ) == ""
        end)

      assert stderr =~ "assign @foo not available in Stem template"
    end

    test "preserves line numbers in assign lookups" do
      ast = Stem.__compile_string__("foo\n{{hello}}")

      {_ast, line} =
        Macro.prewalk(ast, nil, fn
          {{:., _, [{:__aliases__, _, [:Stem, :Runtime]}, :fetch_assign!]}, meta, _args} = node,
          _acc ->
            {node, meta[:line]}

          node, acc ->
            {node, acc}
        end)

      assert line == 2
    end
  end

  describe "syntax errors" do
    test "invalid pipelines are rejected as Stem syntax errors" do
      assert_raise Stem.SyntaxError,
                   ~r/pipeline stages must be helper names or helper calls like trim or truncate\(20\)/,
                   fn ->
                     eval("{{name |> String.trim()}}", assigns: [name: "Nina"])
                   end
    end

    test "invalid pipelines underline the full tag span" do
      assert_raise Stem.SyntaxError,
                   ~r/1 \| \{\{name \|> String\.trim\(\)\}\}\n\s+\| \^~+/,
                   fn ->
                     Stem.__compile_string__("{{name |> String.trim()}}")
                   end
    end

    test "unterminated expression includes a snippet" do
      message = """
      nofile:1:5: expected closing '}}' for Stem expression
        |
      1 | foo {{bar
        |     ^\
      """

      assert_raise Stem.SyntaxError, message, fn ->
        Stem.__compile_string__("foo {{bar")
      end
    end

    test "honors file names" do
      assert_raise Stem.SyntaxError, ~r{^my_file\.stem:1:5:}, fn ->
        Stem.__compile_string__("foo {{bar", file: "my_file.stem")
      end
    end

    test "unclosed block" do
      assert_raise Stem.SyntaxError, ~r/expected a closing '\{\{\/if\}\}'/, fn ->
        Stem.__compile_string__("{{#if a}}yes")
      end
    end

    test "mismatched closing tag" do
      assert_raise Stem.SyntaxError, ~r/unexpected closing tag '\{\{\/each\}\}'; expected/, fn ->
        Stem.__compile_string__("{{#if a}}{{/each}}")
      end
    end

    test "stray else" do
      assert_raise Stem.SyntaxError, ~r/unexpected '\{\{else\}\}' outside of a block/, fn ->
        Stem.__compile_string__("{{else}}")
      end
    end

    test "invalid Elixir expression" do
      assert_raise TokenMissingError, fn ->
        Stem.__compile_string__("{{a + }}", allow_elixir_expressions: true)
      end
    end

    test "complex parent traversal is rejected at compile time" do
      assert_raise CompileError, ~r/unsupported parent path traversal/, fn ->
        Stem.__compile_string__("{{#each xs}}{{../a.b}}{{/each}}", allow_elixir_expressions: true)
      end
    end

    test "snippet includes preceding lines" do
      message = """
      nofile:3:1: expected closing '}}' for Stem expression
        |
      1 | a
      2 | b
      3 | {{oops
        | ^\
      """

      assert_raise Stem.SyntaxError, message, fn ->
        Stem.__compile_string__("a\nb\n{{oops")
      end
    end
  end

  describe "runtime entry points" do
    test "eval_string and compile_string work at runtime" do
      assert Stem.Unsafe.eval_string("{{x}}", assigns: [x: 1]) == "1"

      quoted = Stem.compile_string("{{x}}")
      assert is_tuple(quoted)

      {result, _binding} = Code.eval_quoted(quoted, assigns: [x: 2], helpers: [])
      assert result == "2"
    end

    test "eval_file and compile_file work at runtime" do
      file = Path.join(__DIR__, "fixtures/stem_template_with_bindings.stem")

      assert Stem.Unsafe.eval_file(file, assigns: [bar: 9]) == "foo 9\n"

      quoted = Stem.compile_file(file)
      {result, _binding} = Code.eval_quoted(quoted, assigns: [bar: 7], helpers: [])
      assert result == "foo 7\n"
    end

    test "compiling a missing file raises" do
      assert_raise File.Error, fn -> Stem.__compile_file__("does-not-exist.stem") end
    end
  end

  defp normalize(string), do: String.replace(string, "\r\n", "\n")
end
