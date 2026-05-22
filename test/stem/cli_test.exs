# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Mix.Tasks.StemTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "renders a template from a JSON file and template file" do
    template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

    data_path =
      Path.join(System.tmp_dir!(), "stem-data-#{System.unique_integer([:positive])}.json")

    File.write!(data_path, ~s({"bar":7}))

    try do
      output =
        capture_io(fn ->
          Mix.Tasks.Stem.run([data_path, template])
        end)

      assert output == "foo 7\n"
    after
      File.rm(data_path)
    end
  end

  test "renders a template with block helpers" do
    template = Path.expand("../fixtures/stem_template.stem", __DIR__)

    output =
      capture_io(fn ->
        Mix.Tasks.Stem.run([template])
      end)

    assert output == "foo bar.\n"
  end

  test "strict mode warns on missing assigns" do
    template = Path.expand("../fixtures/stem_template_condition.stem", __DIR__)

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            Mix.Tasks.Stem.run([template, "--strict"])
          end)

        assert stdout == "foo \n"
      end)

    assert stderr =~ "assign @print not available in Stem template"
  end

  test "supports parent traversal inside each loops" do
    template = Path.expand("../fixtures/stem_each_parent.stem", __DIR__)

    data_path =
      Path.join(System.tmp_dir!(), "stem-data-#{System.unique_integer([:positive])}.json")

    File.write!(
      data_path,
      ~s({"prefix":"Mr.","people":[{"firstname":"Nina"},{"firstname":"Joe"}]})
    )

    try do
      output =
        capture_io(fn ->
          Mix.Tasks.Stem.run([data_path, template])
        end)

      assert output == "  Mr. Nina\n  Mr. Joe\n\n"
    after
      File.rm(data_path)
    end
  end

  test "writes output to a file when requested" do
    template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

    data_path =
      Path.join(System.tmp_dir!(), "stem-data-#{System.unique_integer([:positive])}.json")

    File.write!(data_path, ~s({"bar":7}))

    output_path =
      Path.join(System.tmp_dir!(), "stem-output-#{System.unique_integer([:positive])}.txt")

    try do
      assert :ok = Mix.Tasks.Stem.run([data_path, template, "--output", output_path])
      assert File.read!(output_path) == "foo 7\n"
    after
      File.rm(output_path)
    end
  end

  test "raises on missing args" do
    assert_raise Mix.Error, ~r/Usage: stem \[options\] \[DATA_FILE\] TEMPLATE/, fn ->
      Mix.Tasks.Stem.run([])
    end
  end

  test "mix task prints help" do
    output = capture_io(fn -> Mix.Tasks.Stem.run(["--help"]) end)
    assert output =~ "Usage: stem [options] [DATA_FILE] TEMPLATE"
  end

  test "mix task prints version" do
    output = capture_io(fn -> Mix.Tasks.Stem.run(["--version"]) end)
    assert output =~ "Stem"
  end

  describe "Stem.CLI.run" do
    test "returns help and version tuples" do
      assert {:help, usage} = Stem.CLI.run(["-h"])
      assert usage =~ "Usage: stem"
      assert {:version, "Stem " <> _} = Stem.CLI.run(["-v"])
    end

    test "raises on invalid options" do
      assert_raise ArgumentError, ~r/Usage: stem/, fn -> Stem.CLI.run(["--bogus"]) end
    end

    test "renders a template with no data" do
      template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

      assert capture_io([input: ""], fn -> Stem.CLI.run([template]) end) == "foo \n"
    end

    test "renders piped JSON data" do
      template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

      assert capture_io([input: ~s({"bar":9})], fn -> Stem.CLI.run([template]) end) == "foo 9\n"
    end

    test "raises on invalid JSON data" do
      template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

      assert_raise ArgumentError, ~r/invalid JSON data/, fn ->
        capture_io([input: "not json"], fn -> Stem.CLI.run([template]) end)
      end
    end

    test "reads the template from standard input" do
      output = capture_io([input: "Hello world"], fn -> Stem.CLI.run(["-"]) end)
      assert output == "Hello world"
    end

    test "reads data from standard input" do
      template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

      output = capture_io([input: ~s({"bar":7})], fn -> Stem.CLI.run([template]) end)
      assert output == "foo 7\n"
    end

    test "reads data from standard input when the data source is dash" do
      template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

      output = capture_io([input: ~s({"bar":11})], fn -> Stem.CLI.run(["-", template]) end)
      assert output == "foo 11\n"
    end

    test "reads data from standard input with trim markers in the template" do
      template_path =
        Path.join(System.tmp_dir!(), "stem-cli-trim-#{System.unique_integer([:positive])}.stem")

      File.write!(template_path, "test - {{~name~}} \n-")

      try do
        output =
          capture_io([input: ~s({"name":"Tom"})], fn ->
            Stem.CLI.run([template_path])
          end)

        assert output == "test -Tom-"
      after
        File.rm(template_path)
      end
    end

    test "empty standard input renders an empty template" do
      assert capture_io([input: ""], fn -> Stem.CLI.run(["-"]) end) == ""
    end

    test "raises when given too many arguments" do
      assert_raise ArgumentError, ~r/Usage: stem/, fn -> Stem.CLI.run(["a", "b", "c"]) end
    end

    test "reads JSON data from a file path" do
      template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

      data_path =
        Path.join(System.tmp_dir!(), "stem-data-#{System.unique_integer([:positive])}.json")

      File.write!(data_path, ~s({"bar":42}))

      try do
        assert capture_io(fn -> Stem.CLI.run([data_path, template]) end) == "foo 42\n"
      after
        File.rm(data_path)
      end
    end

    test "loads project config while honoring CLI escape overrides" do
      temp_dir =
        Path.join(System.tmp_dir!(), "stem-cli-config-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      config_path = Path.join(temp_dir, ".stem.config.json")
      template_path = Path.join(temp_dir, "template.stem")

      File.write!(config_path, ~s({"mode":"safe"}))
      File.write!(template_path, "{{value}}")

      original_cwd = System.get_env("EXBAR_CWD")
      System.put_env("EXBAR_CWD", temp_dir)

      try do
        output =
          capture_io([input: ~s({"value":"<tag>"})], fn ->
            Stem.CLI.run(["--escape", "none", template_path])
          end)

        assert output == "<tag>"
      after
        if original_cwd do
          System.put_env("EXBAR_CWD", original_cwd)
        else
          System.delete_env("EXBAR_CWD")
        end

        File.rm_rf!(temp_dir)
      end
    end

    test "loads project config while honoring CLI permissive overrides" do
      temp_dir =
        Path.join(System.tmp_dir!(), "stem-cli-permissive-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      config_path = Path.join(temp_dir, ".stem.config.json")
      template_path = Path.join(temp_dir, "template.stem")

      File.write!(config_path, ~s({"mode":"safe"}))
      File.write!(template_path, "{{1 + 2}}")

      original_cwd = System.get_env("EXBAR_CWD")
      System.put_env("EXBAR_CWD", temp_dir)

      try do
        output =
          capture_io(fn ->
            Stem.CLI.run(["--permissive", template_path])
          end)

        assert output == "3"
      after
        if original_cwd do
          System.put_env("EXBAR_CWD", original_cwd)
        else
          System.delete_env("EXBAR_CWD")
        end

        File.rm_rf!(temp_dir)
      end
    end

    test "raises on invalid escape mode" do
      temp_dir =
        Path.join(System.tmp_dir!(), "stem-cli-escape-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      data_path = Path.join(temp_dir, "data.json")
      template = Path.join(temp_dir, "template.stem")
      File.write!(data_path, ~s({"value":"<tag>"}))
      File.write!(template, "{{value}}")

      try do
        assert_raise ArgumentError, ~r/unknown escape mode: bogus/, fn ->
          Stem.CLI.run(["--escape", "bogus", data_path, template])
        end
      after
        File.rm_rf!(temp_dir)
      end
    end

    test "accepts all supported escape modes" do
      temp_dir =
        Path.join(System.tmp_dir!(), "stem-cli-escapes-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      template = Path.join(temp_dir, "template.stem")
      File.write!(template, "{{value}}")

      original_cwd = System.get_env("EXBAR_CWD")
      System.put_env("EXBAR_CWD", temp_dir)

      try do
        assert capture_io([input: ~s({"value":"<tag>"})], fn ->
                 Stem.CLI.run(["--escape", "none", template])
               end) == "<tag>"

        assert capture_io([input: ~s({"value":"<tag>"})], fn ->
                 Stem.CLI.run(["--escape", "html", template])
               end) == "&lt;tag&gt;"

        assert capture_io([input: ~s({"value":"<tag>"})], fn ->
                 Stem.CLI.run(["--escape", "xml", template])
               end) == "&lt;tag&gt;"

        assert capture_io([input: ~s({"value":"<tag>"})], fn ->
                 Stem.CLI.run(["--escape", "json", template])
               end) == "<tag>"

        assert capture_io([input: ~s({"value":"<tag>"})], fn ->
                 Stem.CLI.run(["--escape", "url", template])
               end) == "%3Ctag%3E"
      after
        if original_cwd do
          System.put_env("EXBAR_CWD", original_cwd)
        else
          System.delete_env("EXBAR_CWD")
        end

        File.rm_rf!(temp_dir)
      end
    end

    test "writes output to a file through Stem.CLI.run" do
      temp_dir =
        Path.join(System.tmp_dir!(), "stem-cli-write-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      template = Path.join(temp_dir, "template.stem")
      output = Path.join(temp_dir, "output.txt")
      File.write!(template, "{{value}}")

      try do
        assert capture_io([input: ~s({"value":"ok"})], fn ->
                 Stem.CLI.run(["--output", output, template])
               end) == ""

        assert File.read!(output) == "ok"
      after
        File.rm_rf!(temp_dir)
      end
    end

    test "template helper detection ignores helper names without arguments" do
      assert Stem.CLI.render_template!("{{upcase}}", %{}) == ""
    end

    test "falls back to cli opts when config loading fails" do
      temp_dir =
        Path.join(System.tmp_dir!(), "stem-cli-bad-config-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      config_path = Path.join(temp_dir, ".stem.config.json")
      template = Path.join(temp_dir, "template.stem")

      File.write!(config_path, "not json")
      File.write!(template, "{{value}}")

      original_cwd = System.get_env("EXBAR_CWD")
      System.put_env("EXBAR_CWD", temp_dir)

      try do
        output = capture_io([input: ~s({"value":"ok"})], fn -> Stem.CLI.run([template]) end)

        assert output == "ok"
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

  describe "Stem.CLI.render_template!" do
    test "renders without explicit options and detects helpers" do
      assert Stem.CLI.render_template!(~s({{lookup m "k"}}), %{m: %{"k" => "v"}}) == "v"
    end

    test "ignores empty tags" do
      assert Stem.CLI.render_template!("a{{}}b", %{}) == "ab"
    end

    test "detects assigns through blocks and ignores loop variables" do
      template = "{{#each xs}}{{@index}}:{{this}};{{/each}}"
      assert Stem.CLI.render_template!(template, %{xs: ["a", "b"]}) == "0:a;1:b;"
    end
  end
end
