# SPDX-License-Identifier: Apache-2.0

# This demonstrates how to use individual transformer groups and custom transformers.
# Useful when you only need one or two specific operations.

defmodule ExamplesIndividualTransformersTest do
  use ExUnit.Case

  setup do
    Stem.Transformers.clear()
    :ok
  end

  test "Example 1: Using only the reverse transformer from Collections" do
    assigns = [items: ["a", "b", "c"]]

    template = "{{items | reverse | join \", \"}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers: Stem.Transformers.Collections.all()
      )

    assert result == "c, b, a"
  end

  test "Example 2: Using only upcase from Strings" do
    assigns = [name: "alice"]

    template = "Hello {{name | upcase}}!"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers: Stem.Transformers.Strings.all()
      )

    assert result == "Hello ALICE!"
  end

  test "Example 3: Custom transformer only (no groups)" do
    assigns = [price: 19.99]

    custom = %{"format_price" => fn [amount], _ctx -> "$#{Float.round(amount, 2)}" end}

    template = "Price: {{price | format_price}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers: custom
      )

    assert result == "Price: $19.99"
  end

  test "Example 4: Mix custom transformer with a group" do
    assigns = [text: "  hello world  "]

    custom = %{"shout" => fn [str], _ctx -> String.upcase(to_string(str)) end}

    template = "{{text | trim | shout}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers: Map.merge(Stem.Transformers.Strings.all(), custom)
      )

    assert result == "HELLO WORLD"
  end

  test "Example 5: No transformers — only built-ins" do
    assigns = [name: "alice", fallback: "guest"]

    template = "User: {{name | default fallback}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns
      )

    assert result == "User: alice"
  end

  test "Example 6: join is a built-in, no group needed" do
    assigns = [items: ["apple", "banana", "cherry"]]

    template = "Items: {{items | join \", \"}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns
      )

    assert result == "Items: apple, banana, cherry"
  end

  test "Example 7: escape mode override" do
    assigns = [html: "<b>bold</b>"]

    template = "{{{html}}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        escape: :none
      )

    assert result == "<b>bold</b>"
  end

  test "Example 8: Progressive enhancement — start minimal, add as needed" do
    assigns = [numbers: [1, 2, 3, 4, 5]]

    # Scenario 1: join is built-in
    template1 = "{{numbers | join \", \"}}"
    result1 = Stem.Unsafe.eval_string(template1, assigns: assigns)
    assert result1 == "1, 2, 3, 4, 5"

    # Scenario 2: reverse requires Collections
    template2 = "{{numbers | reverse | join \", \"}}"

    result2 =
      Stem.Unsafe.eval_string(template2,
        assigns: assigns,
        transformers: Stem.Transformers.Collections.all()
      )

    assert result2 == "5, 4, 3, 2, 1"

    # Scenario 3: reverse + take
    template3 = "{{numbers | reverse | take 2 | join \" | \"}}"

    result3 =
      Stem.Unsafe.eval_string(template3,
        assigns: assigns,
        transformers: Stem.Transformers.Collections.all()
      )

    assert result3 == "5 | 4"
  end

  test "Example 9: Template-specific transformers via config" do
    assigns = [message: "  welcome  "]

    template = "{{message | trim | upcase}}"

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers: Stem.Transformers.Strings.all()
      )

    assert result == "WELCOME"
  end

  test "Example 10: Predicates for conditional logic" do
    assigns = [items: ["a", "b", "c"], value: nil]

    template = """
    Items: {{#if items}}{{items | join \", \"}}{{else}}empty{{/if}}
    Value: {{#if value}}present{{else}}missing{{/if}}
    """

    result =
      Stem.Unsafe.eval_string(
        template,
        assigns: assigns,
        transformers: Stem.Transformers.Predicates.all()
      )

    assert result =~ "Items: a, b, c"
    assert result =~ "Value: missing"
  end
end
