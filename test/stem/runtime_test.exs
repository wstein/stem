# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.RuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "fetch_assign! returns existing values" do
    assert Stem.Runtime.fetch_assign!([name: "Nina"], :name, true) == "Nina"
  end

  test "fetch_assign! warns when an assign is missing" do
    stderr =
      capture_io(:stderr, fn ->
        assert Stem.Runtime.fetch_assign!([name: "Nina"], :missing, true) == nil
      end)

    assert stderr =~ "assign @missing not available in Stem template"
  end

  test "fetch_assign! stays quiet when warnings are disabled" do
    stderr =
      capture_io(:stderr, fn ->
        assert Stem.Runtime.fetch_assign!([name: "Nina"], :missing, false) == nil
      end)

    assert stderr == ""
  end

  test "is_truthy matches Handlebars semantics" do
    assert Stem.Runtime.is_truthy(true)
    refute Stem.Runtime.is_truthy(false)
    refute Stem.Runtime.is_truthy(nil)
    refute Stem.Runtime.is_truthy(0)
    refute Stem.Runtime.is_truthy("")
    refute Stem.Runtime.is_truthy([])
    refute Stem.Runtime.is_truthy(%{})
    assert Stem.Runtime.is_truthy([1])
  end

  test "is_truthy with options warns before coercion" do
    stderr =
      capture_io(:stderr, fn ->
        refute Stem.Runtime.is_truthy(0,
                 warn_on_falsy_coercion: true,
                 file: "template.stem",
                 line: 3,
                 context: :condition
               )
      end)

    assert stderr =~ "template.stem:3: condition coerces 0 to falsy under Stem truthiness"
  end

  test "is_truthy with options accepts truthy values without warnings" do
    stderr =
      capture_io(:stderr, fn ->
        assert Stem.Runtime.is_truthy("value",
                 warn_on_falsy_coercion: true,
                 file: "template.stem",
                 line: 3,
                 context: :condition
               )
      end)

    assert stderr == ""
  end

  test "warn_on_falsy_coercion warns for other falsey values" do
    stderr =
      capture_io(:stderr, fn ->
        Stem.Runtime.warn_on_falsy_coercion([], warn_on_falsy_coercion: true, file: "t", line: 1)
        Stem.Runtime.warn_on_falsy_coercion(%{}, warn_on_falsy_coercion: true, file: "t", line: 2)
      end)

    assert stderr =~ "t:1: condition coerces [] to falsy under Stem truthiness"
    assert stderr =~ "t:2: condition coerces %{} to falsy under Stem truthiness"
  end

  test "warn_on_falsy_coercion default arity does not warn for truthy values" do
    stderr = capture_io(:stderr, fn -> assert Stem.Runtime.warn_on_falsy_coercion("x") == "x" end)

    assert stderr == ""
  end

  test "warn_on_falsy_coercion warns for empty strings" do
    stderr =
      capture_io(:stderr, fn ->
        Stem.Runtime.warn_on_falsy_coercion("", warn_on_falsy_coercion: true, file: "t", line: 3)
      end)

    assert stderr =~ "t:3: condition coerces \"\" to falsy under Stem truthiness"
  end

  test "the compiler defaults warn_on_falsy_coercion from application env" do
    Application.put_env(:stem, :warn_on_falsy_coercion, true)
    on_exit(fn -> Application.delete_env(:stem, :warn_on_falsy_coercion) end)

    stderr =
      capture_io(:stderr, fn ->
        # Unique template text avoids the compiled-module cache returning a
        # module built before the application env was set.
        assert Stem.TestTemplate.eval_string(
                 "s2-app-env{{#if v}}t{{else}}f{{/if}}",
                 assigns: [v: 0]
               ) == "s2-app-envf"
      end)

    assert stderr =~ "coerces 0 to falsy under Stem truthiness"
  end

  test "warn_on_falsy_coercion leaves truthy values untouched" do
    assert Stem.Runtime.warn_on_falsy_coercion("value", warn_on_falsy_coercion: true) == "value"
  end
end
