# SPDX-License-Identifier: Apache-2.0

defmodule Stem.UnsafeTest do
  use ExUnit.Case, async: false

  setup do
    Stem.Helpers.clear()
    :ok
  end

  test "Unsafe.eval_string evaluates template with assigns" do
    result = Stem.Unsafe.eval_string("Hello {{name}}", assigns: [name: "World"])

    assert result == "Hello World"
  end

  test "Unsafe.eval_string with empty assigns" do
    result = Stem.Unsafe.eval_string("Static text", assigns: [])

    assert result == "Static text"
  end

  test "Unsafe.eval_string with default bindings parameter" do
    # Default bindings is []
    result = Stem.Unsafe.eval_string("No assigns")

    assert result == "No assigns"
  end

  test "Unsafe.eval_string with escape option" do
    result = Stem.Unsafe.eval_string("{{html}}", [assigns: [html: "<b>bold</b>"]], escape: :none)

    assert result == "<b>bold</b>"
  end

  test "Unsafe.eval_string with HTML escaping default" do
    result = Stem.Unsafe.eval_string("{{html}}", assigns: [html: "<script>"])

    assert result == "&lt;script&gt;"
  end

  test "Unsafe.eval_string with conditional" do
    result = Stem.Unsafe.eval_string("{{#if show}}yes{{else}}no{{/if}}", assigns: [show: true])

    assert result == "yes"
  end

  test "Unsafe.eval_string with each block" do
    result =
      Stem.Unsafe.eval_string("{{#each items}}{{this}}{{/each}}", assigns: [items: [1, 2, 3]])

    assert result == "123"
  end

  test "Unsafe.eval_string with helpers" do
    helpers = [upcase: fn [v], _ctx -> String.upcase(to_string(v)) end]

    result =
      Stem.Unsafe.eval_string("{{upcase name}}", [assigns: [name: "hello"]], helpers: helpers)

    assert result == "HELLO"
  end

  test "Unsafe.eval_string with allow_elixir_expressions: false" do
    result =
      Stem.Unsafe.eval_string("{{name}}", [assigns: [name: "value"]],
        allow_elixir_expressions: false
      )

    assert result == "value"
  end

  test "Unsafe.eval_file evaluates template from file" do
    temp_file =
      Path.join(System.tmp_dir!(), "test_template_#{System.unique_integer([:positive])}.stem")

    File.write!(temp_file, "File: {{content}}")

    on_exit(fn -> File.rm_rf!(temp_file) end)

    result = Stem.Unsafe.eval_file(temp_file, assigns: [content: "success"])

    assert result == "File: success"
  end

  test "Unsafe.eval_file reads file contents literally" do
    temp_file =
      Path.join(System.tmp_dir!(), "literal_file_test_#{System.unique_integer([:positive])}.stem")

    File.write!(temp_file, """
    ---
    literal content
    ---
    {{html}}
    """)

    on_exit(fn -> File.rm_rf!(temp_file) end)

    result = Stem.Unsafe.eval_file(temp_file, assigns: [html: "<b>bold</b>"])

    assert result == "---\nliteral content\n---\n&lt;b&gt;bold&lt;/b&gt;\n"
  end

  test "Unsafe.eval_file with empty bindings default" do
    temp_file =
      Path.join(System.tmp_dir!(), "empty_test_#{System.unique_integer([:positive])}.stem")

    File.write!(temp_file, "Static content")

    on_exit(fn -> File.rm_rf!(temp_file) end)

    result = Stem.Unsafe.eval_file(temp_file)

    assert result == "Static content"
  end

  test "Unsafe.eval_file with default options parameter" do
    temp_file =
      Path.join(System.tmp_dir!(), "opts_test_#{System.unique_integer([:positive])}.stem")

    File.write!(temp_file, "{{value}}")

    on_exit(fn -> File.rm_rf!(temp_file) end)

    result = Stem.Unsafe.eval_file(temp_file, assigns: [value: "success"])

    assert result == "success"
  end

  test "Unsafe.eval_file respects escape option" do
    temp_file =
      Path.join(System.tmp_dir!(), "escape_test_#{System.unique_integer([:positive])}.stem")

    File.write!(temp_file, "{{text}}")

    on_exit(fn -> File.rm_rf!(temp_file) end)

    result = Stem.Unsafe.eval_file(temp_file, [assigns: [text: "<tag>"]], escape: :none)

    assert result == "<tag>"
  end

  test "Unsafe.eval_file with allow_elixir_expressions option" do
    temp_file =
      Path.join(System.tmp_dir!(), "allow_elixir_test_#{System.unique_integer([:positive])}.stem")

    File.write!(temp_file, "{{x}}")

    on_exit(fn -> File.rm_rf!(temp_file) end)

    result =
      Stem.Unsafe.eval_file(temp_file, [assigns: [x: "y"]], allow_elixir_expressions: false)

    assert result == "y"
  end

  test "Unsafe functions are named for SSTI awareness" do
    # These functions exist in the Unsafe namespace for transparency
    assert function_exported?(Stem.Unsafe, :eval_string, 3)
    assert function_exported?(Stem.Unsafe, :eval_file, 3)
  end

  test "Stem.eval_string is no longer exported" do
    refute function_exported?(Stem, :eval_string, 3)

    assert_raise UndefinedFunctionError, fn ->
      apply(Stem, :eval_string, ["{{name}}", [assigns: [name: "test"]], []])
    end
  end

  test "Stem.eval_file is no longer exported" do
    temp_file =
      Path.join(System.tmp_dir!(), "delegate_test_#{System.unique_integer([:positive])}.stem")

    File.write!(temp_file, "{{content}}")

    on_exit(fn -> File.rm_rf!(temp_file) end)

    refute function_exported?(Stem, :eval_file, 3)

    assert_raise UndefinedFunctionError, fn ->
      apply(Stem, :eval_file, [temp_file, [assigns: [content: "same"]], []])
    end
  end
end
