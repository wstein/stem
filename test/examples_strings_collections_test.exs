# SPDX-License-Identifier: Apache-2.0

# Documentation by example: combining Stem.Transformers.Strings
# and Stem.Transformers.Collections in realistic pipelines.

defmodule ExamplesStringsCollectionsTest do
  use ExUnit.Case

  setup do
    Stem.Transformers.clear()
    :ok
  end

  test "Example 1: Reverse a simple list" do
    assigns = [items: ["apple", "banana", "cherry"]]

    template = "{{items | reverse | join \", \"}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers: Stem.Transformers.Collections.all()
      )

    assert result == "cherry, banana, apple"
  end

  test "Example 2: Reverse list order and join" do
    assigns = [items: ["alice", "bob", "charlie"]]

    template = "{{items | reverse | join \" | \"}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers:
          Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
      )

    assert result == "charlie | bob | alice"
  end

  test "Example 3: Reverse a string then uppercase" do
    assigns = [message: "stem"]

    template = "{{message | reverse | upcase}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers: Stem.Transformers.Strings.all()
      )

    assert result == "METS"
  end

  test "Example 4: Sort numbers, reverse order, take top 2" do
    assigns = [numbers: [5, 2, 8, 1, 9, 3]]

    template = "{{numbers | sort | reverse | take 2 | join \", \"}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers:
          Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
      )

    # sorted: [1,2,3,5,8,9], reversed: [9,8,5,3,2,1], take 2: [9,8]
    assert result == "9, 8"
  end

  test "Example 5: Filter truthy values, reverse, take top 3" do
    assigns = [numbers: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]]

    template =
      "Large numbers (highest first): {{numbers | filter | reverse | take 3 | join \", \"}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers:
          Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
      )

    assert result == "Large numbers (highest first): 10, 9, 8"
  end

  test "Example 6: Reverse list order" do
    assigns = [words: ["hello", "world", "stem"]]

    template = "{{words | reverse | join \" \"}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers:
          Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
      )

    assert result == "stem world hello"
  end

  test "Example 7: Real-world — show top 3 scores" do
    assigns = [scores: [10, 45, 23, 89, 56, 12, 34]]

    template = "{{scores | sort | reverse | take 3 | join \", \"}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers:
          Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
      )

    # sorted: [10,12,23,34,45,56,89], reversed, take 3: [89,56,45]
    assert result == "89, 56, 45"
  end

  test "Example 8: Combining collections — reverse preserves whitespace" do
    assigns = [text_list: ["  hello  ", "  world  ", "  stem  "]]

    template = "{{text_list | reverse | join \" | \"}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers:
          Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
      )

    assert result == "  stem   |   world   |   hello  "
  end
end
