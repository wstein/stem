# SPDX-License-Identifier: Apache-2.0

Code.require_file("../../test_helper.exs", __DIR__)

defmodule Stem.Transformers.I18nTest do
  # async: false — these tests mutate the global :stem application env.
  use ExUnit.Case, async: false

  alias Stem.Transformers.I18n

  setup do
    on_exit(fn ->
      Application.delete_env(:stem, :translator)
      Application.delete_env(:stem, :default_locale)
    end)

    :ok
  end

  # Invoke the "t" transformer directly with a ctx map.
  defp t(args, ctx \\ %{assigns: %{}}), do: I18n.all()["t"].(args, ctx)

  def sample_translate(locale, msgid, _bindings), do: "#{locale}::#{msgid}"

  test "all/0 exposes only the translation transformers" do
    assert I18n.all() |> Map.keys() |> Enum.sort() == ["t", "translate"]
  end

  test "translates a msgid via the configured function translator" do
    Application.put_env(:stem, :translator, fn locale, msgid, _bindings ->
      "#{locale}/#{msgid}"
    end)

    assert t(["greeting"], %{assigns: %{locale: "de"}}) == "de/greeting"
  end

  test "passes named bindings (from template kwargs) to the translator" do
    Application.put_env(:stem, :translator, fn _locale, msgid, bindings ->
      String.replace(msgid, "%{name}", to_string(bindings[:name]))
    end)

    # Template kwargs lower to a keyword list as the second argument.
    assert t(["Hi %{name}", [name: "Nina"]], %{assigns: %{}}) == "Hi Nina"
  end

  test "falls back to the configured default locale when assigns has none" do
    Application.put_env(:stem, :default_locale, "fr")
    Application.put_env(:stem, :translator, fn locale, msgid, _ -> "#{locale}:#{msgid}" end)

    assert t(["x"], %{assigns: %{}}) == "fr:x"
  end

  test "uses 'en' when no default locale is configured" do
    Application.put_env(:stem, :translator, fn locale, msgid, _ -> "#{locale}:#{msgid}" end)

    assert t(["x"]) == "en:x"
  end

  test "supports a {module, function} translator" do
    Application.put_env(:stem, :translator, {__MODULE__, :sample_translate})

    assert t(["k"], %{assigns: %{locale: "es"}}) == "es::k"
  end

  test "coerces non-binary translator output to a string" do
    Application.put_env(:stem, :translator, fn _l, _m, _b -> :ok end)

    assert t(["x"]) == "ok"
  end

  test "raises a helpful error when no translator is configured" do
    assert_raise ArgumentError, ~r/no translator configured/, fn -> t(["x"]) end
  end

  test "raises for an invalid translator value" do
    Application.put_env(:stem, :translator, "not a function")

    assert_raise ArgumentError, ~r/translator must be a 3-arity function/, fn -> t(["x"]) end
  end

  test "raises for the wrong number of arguments" do
    Application.put_env(:stem, :translator, fn _l, _m, _b -> "x" end)

    assert_raise ArgumentError, ~r/t expects 1 or 2 arguments/, fn -> t(["a", "b", "c"]) end
  end

  test "treats a non-map, non-keyword bindings argument as empty" do
    Application.put_env(:stem, :translator, fn _l, msgid, bindings ->
      "#{msgid}:#{map_size(bindings)}"
    end)

    assert t(["x", 5]) == "x:0"
  end

  test "resolves the default locale when the ctx carries no assigns" do
    Application.put_env(:stem, :translator, fn locale, msgid, _ -> "#{locale}:#{msgid}" end)

    assert t(["x"], %{}) == "en:x"
  end

  test "works end-to-end in a safe-mode template" do
    Application.put_env(:stem, :translator, fn locale, msgid, _ -> "#{locale}:#{msgid}" end)

    result =
      Stem.Unsafe.eval_string(
        ~s({{t "greeting"}}),
        assigns: [locale: "de"],
        transformers: I18n.all()
      )

    assert result == "de:greeting"
  end
end
