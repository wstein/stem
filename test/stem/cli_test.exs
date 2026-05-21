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
end
