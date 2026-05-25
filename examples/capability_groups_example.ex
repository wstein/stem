# SPDX-License-Identifier: Apache-2.0

defmodule Examples.CapabilityGroupsExample do
  @moduledoc """
  Demonstrates Stem's capability management system for reducing SSTI attack surface.

  The capability model requires explicit opt-in to transformer groups, making
  the security boundary visible and auditable.
  """

  def example_secure_minimum do
    # Only built-in transformers (Stem.Transformers.Minimum) are available by default.
    # This includes escaping and basic operations, but not data manipulation.

    template = "User: {{name}}, Status: {{status}}"

    Stem.Unsafe.eval_string(
      template,
      assigns: [name: "Alice", status: "Active"]
    )

    # Output: "User: Alice, Status: Active"
    # Available: escape_html, default, lookup, join, inspect, json, escape_json, log
  end

  def example_with_strings do
    # Add string manipulation by loading Stem.Transformers.Strings.

    template = "Welcome, {{name | trim | upcase}}!"

    Stem.Unsafe.eval_string(
      template,
      assigns: [name: " alice "],
      transformers: Stem.Transformers.Strings.all()
    )

    # Output: "Welcome, ALICE!"
    # Adds: trim, upcase, downcase, capitalize, replace, truncate, etc.
  end

  def example_with_collections do
    # Enable collection operations for filtering and transformation.

    template = """
    {{#each authors}}
      - {{name | capitalize}} ({{books | length}} books)
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
      transformers: Map.merge(Stem.Transformers.Collections.all(), Stem.Transformers.Strings.all())
    )

    # Output includes author names capitalized and book counts.
    # Adds: map, filter, sort_by, group_by, compact, uniq, etc.
  end

  def example_with_config do
    # Load transformer groups from .stem.config.json instead of repeating in each call.

    # .stem.config.json:
    # {
    #   "transformers": "Stem.Transformers.Strings,Stem.Transformers.Collections"
    # }

    template = """
    Top authors:
    {{authors | sort_by book_count | take 3 | map name}}
    """

    assigns = [
      authors: [
        %{"name" => "Alice", "book_count" => 10},
        %{"name" => "Bob", "book_count" => 5},
        %{"name" => "Charlie", "book_count" => 15}
      ]
    ]

    # No need to pass transformers: — loaded from config.
    Stem.Unsafe.eval_string(template, assigns: assigns)
  end

  def example_custom_transformers do
    # Combine a group with custom transformers for domain-specific operations.

    template = "{{user | format_name}} - Rating: {{rating | star_rating}}"

    custom = %{
      "star_rating" => fn [rating], _ctx ->
        String.duplicate("⭐", min(rating, 5))
      end,
      "format_name" => fn [user], _ctx ->
        "#{user["first_name"]} #{user["last_name"]}"
      end
    }

    assigns = [
      user: %{"first_name" => "Jane", "last_name" => "Doe"},
      rating: 4
    ]

    Stem.Unsafe.eval_string(
      template,
      assigns: assigns,
      transformers: Map.merge(Stem.Transformers.Strings.all(), custom)
    )

    # Output: "Jane Doe - Rating: ⭐⭐⭐⭐"
  end

  def security_principle do
    # The capability model enforces the principle of least privilege:
    # templates only have access to the transformers they actually need.

    # ❌ BAD: Expose all transformers by default
    # risk = high
    # audit trail = invisible

    # ✅ GOOD: Explicit opt-in via transformers: map
    # risk = minimized
    # audit trail = visible (developer must declare groups in code or config)

    # This makes dangerous choices visible during code review:
    # If you see `transformers: Stem.Transformers.Collections.all()`, you know
    # the template has access to powerful data operations.
    :ok
  end

  def migration_strategy do
    # For existing applications:

    # 1. Identify which templates need which transformers
    # 2. Add `transformers:` to eval_string/3 calls that need them
    # 3. Pin defaults in .stem.config.json to reduce boilerplate
    # 4. For compile-time templates: no changes needed
    #    (the compiler inlines all operations at build time)

    # Before:
    # Stem.Unsafe.eval_string(template, assigns: data)
    # (All built-in transformers available)

    # After (adding Strings group):
    # Stem.Unsafe.eval_string(template, assigns: data,
    #   transformers: Stem.Transformers.Strings.all())
    :ok
  end
end
