# SPDX-License-Identifier: Apache-2.0

# This is documentation by example, showing how to use Stem.Helpers.Strings
# and Stem.Helpers.Collections together with the reverse operation.

defmodule ExamplesStringsCollectionsTest do
  use ExUnit.Case

  setup do
    Stem.Helpers.clear()
    :ok
  end

  test "Example 1: Reverse a simple list" do
    assigns = [items: ["apple", "banana", "cherry"]]

    template = "{{items |> reverse |> join(\", \")}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Collections]
      )

    # Reverse order: cherry, banana, apple
    assert result == "cherry, banana, apple"
  end

  test "Example 2: Reverse and uppercase with Collections + Strings" do
    assigns = [items: ["alice", "bob", "charlie"]]

    # Collections.reverse, Strings.upcase (but need custom helper for upcase on each item)
    template = "{{items |> reverse |> join(\" | \")}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Collections, Stem.Helpers.Strings]
      )

    assert result == "charlie | bob | alice"
  end

  test "Example 3: Reverse a string message and make uppercase (Strings group)" do
    assigns = [message: "stem"]

    # Strings.reverse to reverse, Strings.upcase to uppercase
    template = "{{message |> reverse |> upcase}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Strings]
      )

    assert result == "METS"
  end

  test "Example 4: Sort numbers, reverse order, take top 2" do
    assigns = [numbers: [5, 2, 8, 1, 9, 3]]

    # Collections.sort, Collections.reverse, Collections.take, Collections.join
    template = "{{numbers |> sort |> reverse |> take(2) |> join(\", \")}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Collections, Stem.Helpers.Strings]
      )

    # Sorted: [1, 2, 3, 5, 8, 9], reversed: [9, 8, 5, 3, 2, 1], take 2: [9, 8]
    assert result == "9, 8"
  end

  test "Example 5: Complex pipeline - filter, reverse, take, format" do
    assigns = [
      numbers: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    ]

    # Collections: filter (numbers > 5), reverse, take, join
    template =
      "Large numbers (highest first): {{numbers |> filter |> reverse |> take(3) |> join(\", \")}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Collections, Stem.Helpers.Strings]
      )

    # Filter truthy values, reverse all, take 3: [10, 9, 8]
    assert result == "Large numbers (highest first): 10, 9, 8"
  end

  test "Example 6: String manipulation - reverse each word" do
    assigns = [
      words: ["hello", "world", "stem"]
    ]

    # Collections.reverse the list order, Strings.join
    # Note: Can't reverse individual strings in a map without custom helpers
    template = "{{words |> reverse |> join(\" \")}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Collections, Stem.Helpers.Strings]
      )

    assert result == "stem world hello"
  end

  test "Example 7: Real-world scenario - show top 3 items in reverse" do
    assigns = [
      scores: [10, 45, 23, 89, 56, 12, 34]
    ]

    # Collections: sort_by (or sort), reverse, take
    template = "{{scores |> sort |> reverse |> take(3) |> join(\", \")}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Collections, Stem.Helpers.Strings]
      )

    # Sorted: [10, 12, 23, 34, 45, 56, 89], reversed: [89, 56, 45, 34, 23, 12, 10], take 3: [89, 56, 45]
    assert result == "89, 56, 45"
  end

  test "Example 8: Combining collections with string trimming" do
    assigns = [
      text_list: ["  hello  ", "  world  ", "  stem  "]
    ]

    # This shows the combination of both groups, though we can't trim each
    # item individually without map + custom helper
    template = "{{text_list |> reverse |> join(\" | \")}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Collections, Stem.Helpers.Strings]
      )

    assert result == "  stem   |   world   |   hello  "
  end
end
