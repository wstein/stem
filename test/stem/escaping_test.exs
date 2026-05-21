# SPDX-License-Identifier: Apache-2.0

defmodule Stem.EscapingTest do
  use ExUnit.Case, async: false

  setup do
    # Clear registry before each test
    Stem.Escaping.clear()

    on_exit(fn ->
      Stem.Escaping.clear()
    end)

    :ok
  end

  test "escape_html escapes HTML entities" do
    input = "<script>alert('xss')</script>"
    expected = "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"

    result = Stem.Escaping.escape_html(input)

    assert result == expected
  end

  test "escape with :html mode escapes HTML" do
    input = "<b>bold</b>"
    expected = "&lt;b&gt;bold&lt;/b&gt;"

    result = Stem.Escaping.escape(input, :html)

    assert result == expected
  end

  test "escape with :none mode returns unescaped" do
    input = "<raw>content</raw>"

    result = Stem.Escaping.escape(input, :none)

    assert result == input
  end

  test "escape with :xml mode escapes XML entities" do
    input = "<tag attr=\"value\">content</tag>"
    expected = "&lt;tag attr=&quot;value&quot;&gt;content&lt;/tag&gt;"

    result = Stem.Escaping.escape(input, :xml)

    assert result == expected
  end

  test "escape with :json mode escapes JSON" do
    input = "line1\nline2\t\"quoted\""
    result = Stem.Escaping.escape(input, :json)

    # JSON escape should handle quotes, newlines, tabs, backslashes
    assert String.contains?(result, "\\n")
    assert String.contains?(result, "\\t")
    assert String.contains?(result, "\\\"")
  end

  test "escape with :url mode URL-encodes" do
    input = "hello world & special=chars"

    result = Stem.Escaping.escape(input, :url)

    # URL encoding should handle spaces, ampersands, equals
    assert String.contains?(result, "%") or String.contains?(result, "+")
  end

  test "escape converts non-string values to string first" do
    result = Stem.Escaping.escape(123, :html)

    assert result == "123"
  end

  test "escape converts atom to string first" do
    result = Stem.Escaping.escape(:atom, :html)

    assert result == "atom"
  end

  test "register custom escape formatter" do
    custom_formatter = fn value -> "CUSTOM[#{value}]" end

    Stem.Escaping.register(:custom, custom_formatter)
    result = Stem.Escaping.escape("text", :custom)

    assert result == "CUSTOM[text]"
  end

  test "register with atom name" do
    custom_formatter = fn value -> "X#{value}X" end

    Stem.Escaping.register(:x_mode, custom_formatter)
    result = Stem.Escaping.escape("value", :x_mode)

    assert result == "XvalueX"
  end

  test "register with string name" do
    custom_formatter = fn value -> value <> "!" end

    Stem.Escaping.register("exclaim", custom_formatter)
    result = Stem.Escaping.escape("text", :exclaim)

    assert result == "text!"
  end

  test "unregister removes custom formatter" do
    custom_formatter = fn value -> "CUSTOM[#{value}]" end

    Stem.Escaping.register(:temporary, custom_formatter)
    assert Stem.Escaping.escape("text", :temporary) == "CUSTOM[text]"

    Stem.Escaping.unregister(:temporary)

    assert_raise ArgumentError, ~r/unknown escape mode/, fn ->
      Stem.Escaping.escape("text", :temporary)
    end
  end

  test "unregister with string name" do
    custom_formatter = fn value -> value end

    Stem.Escaping.register("temp_mode", custom_formatter)
    Stem.Escaping.unregister("temp_mode")

    assert_raise ArgumentError, ~r/unknown escape mode/, fn ->
      Stem.Escaping.escape("text", :temp_mode)
    end
  end

  test "clear removes all custom formatters" do
    Stem.Escaping.register(:custom1, fn v -> "1#{v}" end)
    Stem.Escaping.register(:custom2, fn v -> "2#{v}" end)

    Stem.Escaping.clear()

    assert_raise ArgumentError, ~r/unknown escape mode/, fn ->
      Stem.Escaping.escape("text", :custom1)
    end

    assert_raise ArgumentError, ~r/unknown escape mode/, fn ->
      Stem.Escaping.escape("text", :custom2)
    end
  end

  test "builtin modes still work after clear" do
    Stem.Escaping.clear()

    # Builtin modes should still work
    result = Stem.Escaping.escape("<tag>", :html)

    assert result == "&lt;tag&gt;"
  end

  test "escape raises on unknown mode" do
    assert_raise ArgumentError, ~r/unknown escape mode/, fn ->
      Stem.Escaping.escape("text", :unknown_mode)
    end
  end

  test "HTML escape handles ampersand first" do
    # Ampersand must be escaped first to avoid double-escaping
    input = "&lt;"
    result = Stem.Escaping.escape_html(input)

    # Should not result in &amp;lt; (double escape)
    assert result == "&amp;lt;"
  end

  test "JSON escape handles backslash" do
    input = "path\\to\\file"
    result = Stem.Escaping.escape(input, :json)

    # Backslashes should be escaped
    assert String.contains?(result, "\\\\")
  end

  test "URL escape preserves alphanumerics" do
    input = "abc123"
    result = Stem.Escaping.escape(input, :url)

    # Alphanumerics should not be encoded
    assert String.contains?(result, "abc123")
  end

  test "escape with :none mode on special characters" do
    input = "<>&\"'=!@#$%^*()[]{}|;:"
    result = Stem.Escaping.escape(input, :none)

    assert result == input
  end

  test "custom formatter receives correct value" do
    test_value = "test_input_12345"
    received_value = []

    custom_formatter = fn value ->
      # Capture the value received
      "GOT:#{value}"
    end

    Stem.Escaping.register(:capture, custom_formatter)
    result = Stem.Escaping.escape(test_value, :capture)

    assert String.contains?(result, test_value)
  end

  test "multiple custom formatters can coexist" do
    Stem.Escaping.register(:fmt1, fn v -> "A#{v}A" end)
    Stem.Escaping.register(:fmt2, fn v -> "B#{v}B" end)
    Stem.Escaping.register(:fmt3, fn v -> "C#{v}C" end)

    assert Stem.Escaping.escape("x", :fmt1) == "AxA"
    assert Stem.Escaping.escape("x", :fmt2) == "BxB"
    assert Stem.Escaping.escape("x", :fmt3) == "CxC"
  end

  test "register overwrites existing formatter" do
    Stem.Escaping.register(:mode, fn v -> "OLD#{v}" end)
    assert Stem.Escaping.escape("x", :mode) == "OLDx"

    Stem.Escaping.register(:mode, fn v -> "NEW#{v}" end)
    assert Stem.Escaping.escape("x", :mode) == "NEWx"
  end
end
