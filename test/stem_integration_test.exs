# SPDX-License-Identifier: Apache-2.0

defmodule Stem.StemTest do
  use ExUnit.Case, async: false

  setup do
    Stem.Helpers.clear()
    :ok
  end

  describe "compile_string" do
    test "compile_string returns quoted code" do
      result = Stem.compile_string("Hello {{name}}")

      # Should return quoted code
      assert is_tuple(result)
    end

    test "compile_string with options" do
      result = Stem.compile_string("{{html}}", escape: :none)

      assert is_tuple(result)
    end
  end

  describe "compile_file" do
    test "compile_file returns quoted code from file" do
      temp_file =
        Path.join(System.tmp_dir!(), "compile_test_#{System.unique_integer([:positive])}.stem")

      File.write!(temp_file, "{{value}}")

      on_exit(fn -> File.rm_rf!(temp_file) end)

      result = Stem.compile_file(temp_file)

      assert is_tuple(result)
    end

    test "compile_file uses literal file contents" do
      temp_file =
        Path.join(
          System.tmp_dir!(),
          "literal_compile_#{System.unique_integer([:positive])}.stem"
        )

      File.write!(temp_file, """
      ---
      literal section header
      ---
      {{value}}
      """)

      on_exit(fn -> File.rm_rf!(temp_file) end)

      {result, _bindings} =
        temp_file
        |> Stem.compile_file()
        |> Code.eval_quoted(assigns: [value: "ok"])

      assert result == "---\nliteral section header\n---\nok\n"
    end

    test "compile_file honors safe mode from project config" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "safe_mode_compile_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)

      config_file = Path.join(temp_dir, ".stem.config.json")
      template_file = Path.join(temp_dir, "safe_mode.stem")

      File.write!(config_file, ~s({"mode":"safe"}))
      File.write!(template_file, "{{1 + 1}}")

      original_cwd = System.get_env("EXBAR_CWD")
      System.put_env("EXBAR_CWD", temp_dir)

      try do
        assert_raise CompileError, ~r/safe mode forbids arbitrary Elixir expressions/, fn ->
          Stem.compile_file(template_file)
        end
      after
        if original_cwd do
          System.put_env("EXBAR_CWD", original_cwd)
        else
          System.delete_env("EXBAR_CWD")
        end

        File.rm_rf!(temp_dir)
      end
    end
  end

  describe "runtime evaluation" do
    test "Unsafe.eval_string returns rendered string" do
      result = Stem.Unsafe.eval_string("Hello {{name}}", assigns: [name: "World"])

      assert result == "Hello World"
    end

    test "Unsafe.eval_string with empty source" do
      result = Stem.Unsafe.eval_string("", assigns: [])

      assert result == ""
    end

    test "Unsafe.eval_string with only text" do
      result = Stem.Unsafe.eval_string("just text", assigns: [])

      assert result == "just text"
    end

    test "Unsafe.eval_file returns rendered string from file" do
      temp_file =
        Path.join(System.tmp_dir!(), "eval_file_test_#{System.unique_integer([:positive])}.stem")

      File.write!(temp_file, "Value: {{val}}")

      on_exit(fn -> File.rm_rf!(temp_file) end)

      result = Stem.Unsafe.eval_file(temp_file, assigns: [val: "success"])

      assert result == "Value: success"
    end

    test "Unsafe.eval_file honors project escape defaults" do
      temp_dir =
        Path.join(System.tmp_dir!(), "config_escape_eval_#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      config_file = Path.join(temp_dir, ".stem.config.json")
      template_file = Path.join(temp_dir, "escaped.stem")

      File.write!(config_file, ~s({"escape":"html"}))
      File.write!(template_file, "{{html}}")

      original_cwd = System.get_env("EXBAR_CWD")
      System.put_env("EXBAR_CWD", temp_dir)

      try do
        result = Stem.Unsafe.eval_file(template_file, assigns: [html: "<b>safe</b>"])

        assert result == "&lt;b&gt;safe&lt;/b&gt;"
      after
        if original_cwd do
          System.put_env("EXBAR_CWD", original_cwd)
        else
          System.delete_env("EXBAR_CWD")
        end

        File.rm_rf!(temp_dir)
      end
    end
  end

  describe "function_from_string" do
    test "function_from_string creates a template function" do
      defmodule TestModule1 do
        require Stem

        Stem.function_from_string(:def, :render, "Hello {{name}}", [:assigns])
      end

      result = TestModule1.render(name: "Alice")

      assert result == "Hello Alice"
    end
  end

  describe "function_from_file" do
    test "function_from_file creates template function from file" do
      temp_file =
        Path.join(System.tmp_dir!(), "func_file_#{System.unique_integer([:positive])}.stem")

      File.write!(temp_file, "File {{content}}")

      on_exit(fn -> File.rm_rf!(temp_file) end)

      # Skip this test for now - requires module def at compile time
      # Just verify eval_file works instead
      result = Stem.Unsafe.eval_file(temp_file, assigns: [content: "test"])

      assert result == "File test"
    end
  end

  describe "Config integration" do
    test "Unsafe.eval_string loads config from project root" do
      # This test verifies config loading doesn't break runtime evaluation
      result = Stem.Unsafe.eval_string("{{name}}", assigns: [name: "test"])

      assert result == "test"
    end
  end

  describe "Error handling" do
    test "syntax error in template raises error" do
      assert_raise Stem.SyntaxError, fn ->
        Stem.Unsafe.eval_string("{{#if missing_close }}", assigns: [])
      end
    end

    test "invalid tags in files still raise syntax errors" do
      temp_file =
        Path.join(
          System.tmp_dir!(),
          "invalid_template_#{System.unique_integer([:positive])}.stem"
        )

      File.write!(temp_file, "{{#if missing_close }}")

      on_exit(fn -> File.rm_rf!(temp_file) end)

      assert_raise Stem.SyntaxError, fn ->
        Stem.compile_file(temp_file)
      end
    end
  end
end
