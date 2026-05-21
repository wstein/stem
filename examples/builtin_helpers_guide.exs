# SPDX-License-Identifier: Apache-2.0

assigns = [
  isActive: true,
  count: 0,
  items: ["alpha", "beta"],
  story: %{title: "The Story", author: "A. Writer"},
  map: %{firstName: "Homer"},
  person: %{"firstName" => "Nils"},
  values: ["a", "b"]
]

IO.puts(Stem.eval_string("{{#if isActive}}active{{else}}inactive{{/if}}", assigns: assigns))

IO.puts(Stem.eval_string("{{#if count}}non-empty{{else}}empty{{/if}}", assigns: assigns))

IO.puts(Stem.eval_string("{{#unless isActive}}inactive{{/unless}}", assigns: assigns))
IO.puts(Stem.eval_string("{{#each items}}{{@index}}:{{this}};{{/each}}", assigns: assigns))
IO.puts(Stem.eval_string("{{#each map}}{{@key}}: {{this}}{{/each}}", assigns: assigns))

IO.puts(
  Stem.eval_string("{{#with story}}{{this.title}} by {{this.author}}{{/with}}",
    assigns: assigns
  )
)

IO.puts(Stem.eval_string("{{lookup person \"firstName\"}}", assigns: assigns))
IO.puts(Stem.eval_string("{{lookup values 1}}", assigns: assigns))
