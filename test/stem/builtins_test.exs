# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.BuiltinsTest do
  use ExUnit.Case, async: true

  alias Stem.Builtins

  describe "each_entries/1" do
    test "nil becomes an empty list" do
      assert Builtins.each_entries(nil) == []
    end

    test "maps pair each value with its key" do
      assert Builtins.each_entries(%{a: 1}) == [{1, :a}]
    end

    test "lists pair each value with a nil key" do
      assert Builtins.each_entries([1, 2]) == [{1, nil}, {2, nil}]
    end

    test "other terms are wrapped" do
      assert Builtins.each_entries("x") == [{"x", nil}]
    end
  end

  describe "each/3" do
    test "empty collection with an else function" do
      assert Builtins.each([], fn _e, _i -> "x" end, fn -> "empty" end) == "empty"
    end

    test "empty collection without an else function" do
      assert Builtins.each([], fn _e, _i -> "x" end) == ""
    end

    test "non-empty collection joins rendered entries with index" do
      entries = Builtins.each_entries(["a", "b"])
      render = fn {value, _key}, index -> "#{index}:#{value};" end
      assert Builtins.each(entries, render) == "0:a;1:b;"
    end
  end
end
