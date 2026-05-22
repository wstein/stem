# SPDX-License-Identifier: Apache-2.0

defmodule Examples.CapabilityGroupsExample do
  @moduledoc """
  Demonstrates Stem's capability management system for reducing SSTI attack surface.

  The capability model requires explicit opt-in to helper function groups, making
  the security boundary visible and auditable.
  """

  def example_secure_minimum do
    # Only Stem.Helpers.Minimum is available by default
    # This includes escaping and basic operations, but not data manipulation

    template = "User: {{name}}, Status: {{status}}"

    Stem.Unsafe.eval_string(
      template,
      assigns: [name: "Alice", status: "Active"]
    )

    # Output: "User: Alice, Status: Active"
    # Available: escape_html, default, lookup, join, inspect, json, escape_json, log
  end

  def example_with_strings do
    # Add string manipulation by loading Stem.Helpers.Strings

    template = "Welcome, {{name |> trim |> upcase}}!"

    Stem.Unsafe.eval_string(
      template,
      assigns: [name: " alice "],
      helper_groups: [Stem.Helpers.Strings]
    )

    # Output: "Welcome, ALICE!"
    # Adds: trim, upcase, downcase, capitalize, replace, truncate, etc.
  end

  def example_with_collections do
    # Enable collection operations for filtering and transformation

    template = """
    {{#each authors}}
      - {{name |> capitalize}} ({{books |> length}} books)
    {{/each}}
    """

    assigns = [
      authors: [
        %{"name" => "alice", "books" => ["A", "B"]},
        %{"name" => "bob", "books" => ["C"]}
      ]
    ]

    Stem.Unsafe.eval_string(
      template,
      assigns: assigns,
      helper_groups: [Stem.Helpers.Collections, Stem.Helpers.Strings]
    )

    # Output includes author names capitalized and book counts
    # Adds: map, filter, sort_by, group_by, compact, uniq, etc.
  end

  def example_with_config do
    # Load helper groups from .stem.config.json instead of repeating in each call

    # .stem.config.json:
    # {
    #   "helper_groups": "Stem.Helpers.Strings,Stem.Helpers.Collections"
    # }

    template = """
    Top authors:
    {{authors |> sort_by(book_count) |> take(3) |> map(name)}}
    """

    assigns = [
      authors: [
        %{"name" => "Alice", "book_count" => 10},
        %{"name" => "Bob", "book_count" => 5},
        %{"name" => "Charlie", "book_count" => 15}
      ]
    ]

    # No need to pass helper_groups - loaded from config
    Stem.Unsafe.eval_string(template, assigns: assigns)
  end

  def example_custom_helpers do
    # Combine capability groups with custom helpers for domain-specific operations

    template = "{{user |> format_name}} - Rating: {{rating |> star_rating}}"

    custom_helpers = [
      star_rating: fn [rating], _ctx ->
        String.duplicate("⭐", min(rating, 5))
      end,
      format_name: fn [user], _ctx ->
        "#{user["first_name"]} #{user["last_name"]}"
      end
    ]

    assigns = [
      user: %{"first_name" => "Jane", "last_name" => "Doe"},
      rating: 4
    ]

    Stem.Unsafe.eval_string(
      template,
      [assigns: assigns],
      helpers: custom_helpers,
      helper_groups: [Stem.Helpers.Strings]
    )

    # Output: "Jane Doe - Rating: ⭐⭐⭐⭐"
  end

  def security_principle do
    # The capability model enforces the principle of least privilege:
    # Templates only have access to the minimum helpers they need.

    # ❌ BAD: Expose all helpers by default
    # risk = high
    # audit trail = invisible

    # ✅ GOOD: Explicit opt-in to capability groups
    # risk = minimized
    # audit trail = visible (developer must declare groups in code or config)

    # This makes dangerous choices visible during code review:
    # If you see `helper_groups: [Stem.Helpers.Collections]`, you know
    # the template has access to powerful data operations.
  end

  def migration_strategy do
    # For existing applications using Stem helpers:

    # 1. Identify which templates need which helpers
    # 2. Add :helper_groups to eval_string/3 calls that need them
    # 3. Pin defaults in .stem.config.json to reduce boilerplate
    # 4. For compile-time templates: no changes needed
    #    (the compiler inlines all operations at build time)

    # Before:
    # Stem.Unsafe.eval_string(template, assigns: data)
    # (All helpers available)

    # After:
    # Stem.Unsafe.eval_string(template, assigns: data, helper_groups: [Stem.Helpers.Strings])
    # (Only Strings helpers available, plus the Minimum set)
  end
end
