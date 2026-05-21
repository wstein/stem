# SPDX-License-Identifier: Apache-2.0

# Templates are compiled into functions at compile time in this example.
# Stem also supports runtime compile/eval APIs when needed.
defmodule StemDemo do
  use Stem

  deftemplate(
    :render,
    """
    Hello {{upcase name}}
    {{#if admin}}Role: admin{{else}}Role: user{{/if}}
    Items: {{#each items}}[{{this}}]{{/each}}
    Partial: {{> signature}}
    """,
    [:assigns, :helpers],
    partials: %{signature: "Kind regards, {{name}}"}
  )
end

# Helpers resolve at render time, so registering before the call is enough.
Stem.Helpers.register(:upcase, fn [value], _ctx ->
  String.upcase(to_string(value))
end)

IO.puts(StemDemo.render([name: "nina", admin: true, items: ["a", "b"]], []))
