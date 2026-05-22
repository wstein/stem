# SPDX-License-Identifier: Apache-2.0

Code.require_file("../../test_helper.exs", __DIR__)

defmodule Mix.Tasks.Stem.AuditTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    tmp = System.tmp_dir!() |> Path.join("stem_audit_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "passes when no production config files exist" do
    # Run in a temp dir with no config files — should pass silently
    output =
      capture_io(fn ->
        Mix.Tasks.Stem.Audit.run(["--paths", Path.join(System.tmp_dir!(), "nonexistent.exs")])
      end)

    assert output =~ "passed"
  end

  test "passes when production config contains allow_elixir_expressions: false", %{tmp: tmp} do
    path = Path.join(tmp, "prod.exs")
    File.write!(path, "config :stem, allow_elixir_expressions: false\n")
    output = capture_io(fn -> Mix.Tasks.Stem.Audit.run(["--paths", path]) end)
    assert output =~ "passed"
  end

  test "fails when production config contains allow_elixir_expressions: true", %{tmp: tmp} do
    path = Path.join(tmp, "prod.exs")
    File.write!(path, "config :stem, allow_elixir_expressions: true\n")

    assert_raise Mix.Error, ~r/Stem audit failed.*1 violation/, fn ->
      capture_io(fn -> Mix.Tasks.Stem.Audit.run(["--paths", path]) end)
    end
  end

  test "detects multiple violations across files", %{tmp: tmp} do
    p1 = Path.join(tmp, "prod.exs")
    p2 = Path.join(tmp, "runtime.exs")

    File.write!(p1, "config :stem, allow_elixir_expressions: true\n")
    File.write!(p2, "# dangerous\nconfig :other, allow_elixir_expressions: true\n")

    assert_raise Mix.Error, ~r/2 violation/, fn ->
      capture_io(fn -> Mix.Tasks.Stem.Audit.run(["--paths", p1, "--paths", p2]) end)
    end
  end

  test "detects violation with extra whitespace around colon", %{tmp: tmp} do
    path = Path.join(tmp, "prod.exs")
    File.write!(path, "config :stem, allow_elixir_expressions :  true\n")

    assert_raise Mix.Error, ~r/Stem audit failed/, fn ->
      capture_io(fn -> Mix.Tasks.Stem.Audit.run(["--paths", path]) end)
    end
  end
end
