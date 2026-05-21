# SPDX-License-Identifier: Apache-2.0

defmodule ExampleDSLViews do
  use Stem.DSL

  handlebars(:hello, "Hello {{name}}", [:assigns])

  handlebars(
    :welcome_email,
    """
    <h1>Hello {{name}}</h1>
    {{#if is_admin}}
      <p>You have admin access.</p>
    {{else}}
      <p>Standard access.</p>
    {{/if}}
    """,
    [:assigns]
  )

  handlebars_file(:card, Path.expand("templates/card.stem", __DIR__), [:assigns])
end

IO.puts(ExampleDSLViews.hello(name: "Nina"))
IO.puts("---")
IO.puts(ExampleDSLViews.welcome_email(name: "Nina", is_admin: true))
IO.puts("---")
IO.puts(ExampleDSLViews.card(name: "Nina", id: 7))
