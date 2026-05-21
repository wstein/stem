# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Mix.Tasks.Stem.FormatTest do
  use ExUnit.Case, async: false

  test "formats a Stem file in place" do
    path = Path.join(System.tmp_dir!(), "stem-format-#{System.unique_integer([:positive])}.stem")

    try do
      File.write!(path, "Hello {{  name  }}")
      Mix.Tasks.Stem.Format.run([path])
      assert File.read!(path) == "Hello {{name}}"
    after
      File.rm(path)
    end
  end

  test "check_formatted raises for unformatted files" do
    path = Path.join(System.tmp_dir!(), "stem-check-#{System.unique_integer([:positive])}.stem")

    try do
      File.write!(path, "Hello {{  name  }}")

      assert_raise Mix.Error, ~r/Unformatted Stem templates/, fn ->
        Mix.Tasks.Stem.Format.run(["--check-formatted", path])
      end
    after
      File.rm(path)
    end
  end

  test "check_formatted passes for already formatted files" do
    path =
      Path.join(System.tmp_dir!(), "stem-check-clean-#{System.unique_integer([:positive])}.stem")

    try do
      File.write!(path, "Hello {{name}}")
      assert Mix.Tasks.Stem.Format.run(["--check-formatted", path]) == nil
    after
      File.rm(path)
    end
  end

  test "raises on missing file arguments" do
    assert_raise Mix.Error, ~r/Usage: mix stem.format/, fn ->
      Mix.Tasks.Stem.Format.run([])
    end
  end
end
