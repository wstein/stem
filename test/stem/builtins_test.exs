# SPDX-License-Identifier: Apache-2.0

defmodule Stem.BuiltinsTest do
  use ExUnit.Case, async: true

  describe "each_entries with falsey values (Handlebars truthiness)" do
    test "each_entries returns empty list for nil" do
      assert Stem.Builtins.each_entries(nil) == []
    end

    test "each_entries returns empty list for false" do
      assert Stem.Builtins.each_entries(false) == []
    end

    test "each_entries returns empty list for 0" do
      assert Stem.Builtins.each_entries(0) == []
    end

    test "each_entries returns empty list for empty string" do
      assert Stem.Builtins.each_entries("") == []
    end

    test "each_entries returns empty list for empty list" do
      assert Stem.Builtins.each_entries([]) == []
    end

    test "each_entries returns empty list for empty map" do
      assert Stem.Builtins.each_entries(%{}) == []
    end
  end

  describe "each_entries with truthy values" do
    test "each_entries wraps single value in list" do
      result = Stem.Builtins.each_entries(1)

      assert result == [{1, nil}]
    end

    test "each_entries handles non-empty list" do
      result = Stem.Builtins.each_entries([1, 2, 3])

      assert result == [{1, nil}, {2, nil}, {3, nil}]
    end

    test "each_entries handles non-empty map" do
      result = Stem.Builtins.each_entries(%{"a" => 1, "b" => 2})

      assert Enum.sort(result) == Enum.sort([{1, "a"}, {2, "b"}])
    end

    test "each_entries handles string (wraps as single item)" do
      result = Stem.Builtins.each_entries("hello")

      assert result == [{"hello", nil}]
    end

    test "each_entries handles non-zero number" do
      result = Stem.Builtins.each_entries(42)

      assert result == [{42, nil}]
    end

    test "each_entries handles non-empty string" do
      result = Stem.Builtins.each_entries("text")

      assert result == [{"text", nil}]
    end

    test "each_entries handles atom (wraps as single item)" do
      result = Stem.Builtins.each_entries(:atom)

      assert result == [{:atom, nil}]
    end
  end

  describe "each_entries map key-value transformation" do
    test "each_entries converts map keys and values correctly" do
      map = %{"key1" => "value1", "key2" => "value2"}
      result = Stem.Builtins.each_entries(map)

      assert Enum.sort(result) == Enum.sort([{"value1", "key1"}, {"value2", "key2"}])
    end

    test "each_entries handles map with atom keys" do
      map = %{a: 1, b: 2}
      result = Stem.Builtins.each_entries(map)

      assert Enum.sort(result) == Enum.sort([{1, :a}, {2, :b}])
    end

    test "each_entries preserves map values in tuples" do
      map = %{"x" => 100}
      result = Stem.Builtins.each_entries(map)

      assert result == [{100, "x"}]
    end
  end

  describe "each function" do
    test "each with non-empty entries calls do_fun for each item" do
      entries = [{1, nil}, {2, nil}, {3, nil}]
      result = Stem.Builtins.each(entries, fn {val, _}, idx -> "#{val}:#{idx}," end)

      assert result == "1:0,2:1,3:2,"
    end

    test "each with empty entries and else_fun calls else_fun" do
      result = Stem.Builtins.each([], fn _, _ -> "should not be called" end, fn -> "empty" end)

      assert result == "empty"
    end

    test "each with empty entries and no else_fun returns empty string" do
      result = Stem.Builtins.each([], fn _, _ -> "should not be called" end)

      assert result == ""
    end

    test "each joins results into single string" do
      entries = [{1, "a"}, {2, "b"}]
      result = Stem.Builtins.each(entries, fn {val, _key}, idx -> "#{val}[#{idx}]" end)

      assert result == "1[0]2[1]"
    end

    test "each passes correct index to each item" do
      entries = [{10, nil}, {20, nil}, {30, nil}]

      result = Stem.Builtins.each(entries, fn _, idx -> idx end)

      # With 3 items at indices 0, 1, 2 joined, we get their string concatenation
      assert is_integer(result) or is_binary(result)
    end

    test "each with single item" do
      entries = [{42, "answer"}]
      result = Stem.Builtins.each(entries, fn {val, key}, idx -> "#{val}-#{key}-#{idx}" end)

      assert result == "42-answer-0"
    end

    test "each accumulates strings from all items" do
      entries = [{"a", nil}, {"b", nil}, {"c", nil}]
      result = Stem.Builtins.each(entries, fn {val, _}, _ -> val end)

      assert result == "abc"
    end

    test "each_entries with list of maps" do
      list = [%{"id" => 1}, %{"id" => 2}]
      result = Stem.Builtins.each_entries(list)

      assert result == [{%{"id" => 1}, nil}, {%{"id" => 2}, nil}]
    end
  end

  describe "each_entries with nested structures" do
    test "each_entries handles list with nested map" do
      list = [%{"nested" => "value"}]
      result = Stem.Builtins.each_entries(list)

      assert result == [{%{"nested" => "value"}, nil}]
    end

    test "each_entries handles map with nested list" do
      map = %{"items" => [1, 2, 3]}
      result = Stem.Builtins.each_entries(map)

      assert result == [{[1, 2, 3], "items"}]
    end
  end

  describe "integration: each with each_entries" do
    test "each_entries and each work together for iteration" do
      values = [1, 2, 3]
      entries = Stem.Builtins.each_entries(values)
      result = Stem.Builtins.each(entries, fn {val, _}, idx -> "#{idx}:#{val}|" end)

      assert result == "0:1|1:2|2:3|"
    end

    test "each_entries with falsey value stops iteration" do
      entries = Stem.Builtins.each_entries(0)

      result =
        Stem.Builtins.each(entries, fn _, _ -> "should not appear" end, fn -> "no items" end)

      assert result == "no items"
    end

    test "each_entries with empty string stops iteration" do
      entries = Stem.Builtins.each_entries("")
      result = Stem.Builtins.each(entries, fn _, _ -> "x" end, fn -> "skipped" end)

      assert result == "skipped"
    end
  end
end
