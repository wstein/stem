# SPDX-License-Identifier: Apache-2.0

Stem.Helpers.clear()

Stem.Helpers.register(:upcase, fn [value], _ctx ->
  String.upcase(to_string(value))
end)

template = """
Hello {{upcase name}}
{{#if admin}}Role: admin{{else}}Role: user{{/if}}
Items: {{#each items}}[{{this}}]{{/each}}
Partial: {{> signature}}
"""

output =
  Stem.eval_string(
    template,
    assigns: [name: "nina", admin: true, items: ["a", "b"]],
    partials: %{signature: "Kind regards, {{{name}}}"}
  )

IO.puts(output)
