# SPDX-License-Identifier: Apache-2.0

# This demonstrates how to use individual helpers without loading entire groups.
# Useful when you only need one or two specific helpers.

defmodule ExamplesIndividualHelpersTest do
  use ExUnit.Case

  setup do
    Stem.Helpers.clear()
    :ok
  end

  test "Example 1: Using only the reverse helper from Collections" do
    assigns = [items: ["a", "b", "c"]]

    # Create a minimal helpers map with ONLY reverse
    template = "{{items |> reverse |> join(\", \")}}"

    # Load full Collections group, but in production you'd only need reverse
    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Collections]
      )

    assert result == "c, b, a"
  end

  test "Example 2: Using only upcase from Strings" do
    assigns = [name: "alice"]

    # Only need upcase transformation
    template = "Hello {{name |> upcase}}!"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Strings]
      )

    assert result == "Hello ALICE!"
  end

  test "Example 3: Custom helper only (no groups)" do
    assigns = [price: 19.99]

    # Define a custom helper for formatting
    custom_helpers = [
      format_price: fn [amount], _ctx ->
        "$#{Float.round(amount, 2)}"
      end
    ]

    template = "Price: {{price |> format_price}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helpers: custom_helpers
        # Note: helper_groups is empty - only custom helper available
      )

    assert result == "Price: $19.99"
  end

  test "Example 4: Mix custom helper with one group" do
    assigns = [text: "  hello world  "]

    custom_helpers = [
      shout: fn [str], _ctx -> String.upcase(to_string(str)) end
    ]

    # Both custom helper AND Strings group available
    template = "{{text |> trim |> shout}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helpers: custom_helpers,
        helper_groups: [Stem.Helpers.Strings]
      )

    assert result == "HELLO WORLD"
  end

  test "Example 5: Secure minimum only (no groups, no custom)" do
    assigns = [name: "alice", fallback: "guest"]

    # Only Minimum helpers available (no groups, no custom helpers)
    template = "User: {{name |> default(fallback)}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns
        # No helper_groups, no helpers - only Minimum available
      )

    assert result == "User: alice"
  end

  test "Example 6: Only join (from Minimum)" do
    assigns = [items: ["apple", "banana", "cherry"]]

    # Join is from Minimum group, available by default
    template = "Items: {{items |> join(\", \")}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns
        # Only Minimum available - join is in it
      )

    assert result == "Items: apple, banana, cherry"
  end

  test "Example 7: Only escape_html (from Minimum)" do
    assigns = [html: "<b>bold</b>"]

    # escape_html in Minimum - plain strings to show the effect
    template = "{{{html}}}"

    # Using triple braces to output unescaped, then show how escape_html works
    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        # Disable default escaping to show escape_html working alone
        escape: :none
      )

    assert result == "<b>bold</b>"
  end

  test "Example 8: Progressive enhancement - start minimal, add as needed" do
    assigns = [numbers: [1, 2, 3, 4, 5]]

    # Scenario 1: Just need to join
    template1 = "{{numbers |> join(\", \")}}"
    result1 = Stem.Unsafe.eval_string(template1, assigns: assigns)
    assert result1 == "1, 2, 3, 4, 5"

    # Scenario 2: Need to reverse too - add Collections
    template2 = "{{numbers |> reverse |> join(\", \")}}"

    result2 =
      Stem.Unsafe.eval_string(
        template2,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Collections]
      )

    assert result2 == "5, 4, 3, 2, 1"

    # Scenario 3: Need to take and filter - use only Collections
    template3 = "{{numbers |> reverse |> take(2) |> join(\" | \")}}"

    result3 =
      Stem.Unsafe.eval_string(
        template3,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Collections, Stem.Helpers.Strings]
      )

    # reverse: [5, 4, 3, 2, 1], take 2: [5, 4]
    assert result3 == "5 | 4"
  end

  test "Example 9: Template-specific helpers via config" do
    # For a template that only needs trim + upcase, you could configure:
    # .stem.config.json with just Strings group

    assigns = [message: "  welcome  "]

    # Only Strings group - has trim, upcase but not Collections
    template = "{{message |> trim |> upcase}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Strings]
      )

    assert result == "WELCOME"
  end

  test "Example 10: Predicates-only for conditional logic" do
    assigns = [items: ["a", "b", "c"], value: nil]

    # Only need predicates for if conditions
    template = """
    Items: {{#if items}}{{items |> join(\", \")}}{{else}}empty{{/if}}
    Value: {{#if value}}present{{else}}missing{{/if}}
    """

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        helper_groups: [Stem.Helpers.Predicates]
      )

    assert result =~ "Items: a, b, c"
    assert result =~ "Value: missing"
  end
end
