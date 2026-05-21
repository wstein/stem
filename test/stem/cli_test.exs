# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Mix.Tasks.StemTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "renders a template from a file and inline JSON data" do
    template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

    output =
      capture_io(fn ->
        Mix.Tasks.Stem.run([template, ~s({"bar":7})])
      end)

    assert output == "foo 7\n"
  end

  test "renders a template with block helpers" do
    template = Path.expand("../fixtures/stem_template.stem", __DIR__)

    output =
      capture_io(fn ->
        Mix.Tasks.Stem.run([template, "{}"])
      end)

    assert output == "foo bar.\n"
  end

  test "strict mode warns on missing assigns" do
    template = Path.expand("../fixtures/stem_template_condition.stem", __DIR__)

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            Mix.Tasks.Stem.run([template, "{}", "--strict"])
          end)

        assert stdout == "foo \n"
      end)

    assert stderr =~ "assign @print not available in Stem template"
  end

  test "supports parent traversal inside each loops" do
    template = Path.expand("../fixtures/stem_each_parent.stem", __DIR__)

    output =
      capture_io(fn ->
        Mix.Tasks.Stem.run([
          template,
          ~s({"prefix":"Mr.","people":[{"firstname":"Nina"},{"firstname":"Joe"}]})
        ])
      end)

    assert output == "  Mr. Nina\n  Mr. Joe\n\n"
  end

  test "writes output to a file when requested" do
    template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

    output_path =
      Path.join(System.tmp_dir!(), "stem-output-#{System.unique_integer([:positive])}.txt")

    try do
      assert :ok = Mix.Tasks.Stem.run([template, ~s({"bar":7}), "--output", output_path])
      assert File.read!(output_path) == "foo 7\n"
    after
      File.rm(output_path)
    end
  end

  test "raises on missing args" do
    assert_raise Mix.Error, ~r/Usage: stem \[options\] TEMPLATE \[DATA\]/, fn ->
      Mix.Tasks.Stem.run([])
    end
  end

  test "mix task prints help" do
    output = capture_io(fn -> Mix.Tasks.Stem.run(["--help"]) end)
    assert output =~ "Usage: stem [options] TEMPLATE [DATA]"
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
      assert capture_io(fn -> Stem.CLI.run([template]) end) == "foo \n"
    end

    test "renders inline JSON string data" do
      template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)
      assert capture_io(fn -> Stem.CLI.run([template, ~s({"bar":9})]) end) == "foo 9\n"
    end

    test "raises on invalid JSON data" do
      template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)

      assert_raise ArgumentError, ~r/invalid JSON data/, fn ->
        Stem.CLI.run([template, "not json"])
      end
    end

    test "reads the template from standard input" do
      output = capture_io([input: "Hello world"], fn -> Stem.CLI.run(["-"]) end)
      assert output == "Hello world"
    end

    test "reads data from standard input" do
      template = Path.expand("../fixtures/stem_template_with_bindings.stem", __DIR__)
      output = capture_io([input: ~s({"bar":7})], fn -> Stem.CLI.run([template, "-"]) end)
      assert output == "foo 7\n"
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
        assert capture_io(fn -> Stem.CLI.run([template, data_path]) end) == "foo 42\n"
      after
        File.rm(data_path)
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
