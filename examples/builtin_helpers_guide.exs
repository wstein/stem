# SPDX-License-Identifier: Apache-2.0

# Each built-in transformer and block is compiled into a named function.
# Stem also supports runtime eval/compile APIs, but this guide demonstrates
# compiled functions through the Stem DSL.
defmodule BuiltinHelpersGuide do
  use Stem

  deftemplate(:if_block, "{{#if isActive}}active{{else}}inactive{{/if}}", [:assigns])
  deftemplate(:if_truthy, "{{#if count}}non-empty{{else}}empty{{/if}}", [:assigns])
  deftemplate(:unless_block, "{{#unless isActive}}inactive{{/unless}}", [:assigns])
  deftemplate(:each_index, "{{#each items}}{{@index}}:{{this}};{{/each}}", [:assigns])
  deftemplate(:each_key, "{{#each map}}{{@key}}: {{this}}{{/each}}", [:assigns])

  deftemplate(:with_block, "{{#with story}}{{this.title}} by {{this.author}}{{/with}}", [:assigns])

  deftemplate(:lookup_map, ~s({{lookup person "firstName"}}), [:assigns, :transformers])
  deftemplate(:lookup_list, "{{lookup values 1}}", [:assigns, :transformers])

  deftemplate(:pipeline_name, "{{name | trim | upcase | truncate 4}}", [
    :assigns,
    :transformers
  ])

  deftemplate(
    :pipeline_people,
    "{{people | sort_by \"name\" | map \"name\" | join \", \"}}",
    [:assigns, :transformers]
  )

  deftemplate(:pipeline_default, "{{nickname | default \"friend\"}}", [:assigns, :transformers])
end

assigns = [
  isActive: true,
  count: 0,
  items: ["alpha", "beta"],
  story: %{title: "The Story", author: "A. Writer"},
  map: %{firstName: "Homer"},
  person: %{"firstName" => "Nils"},
  values: ["a", "b"],
  name: "  nina  ",
  nickname: nil,
  people: [%{name: "Mila"}, %{name: "Ada"}, %{name: "Nina"}]
]

IO.puts(BuiltinHelpersGuide.if_block(assigns))
IO.puts(BuiltinHelpersGuide.if_truthy(assigns))
IO.puts(BuiltinHelpersGuide.unless_block(assigns))
IO.puts(BuiltinHelpersGuide.each_index(assigns))
IO.puts(BuiltinHelpersGuide.each_key(assigns))
IO.puts(BuiltinHelpersGuide.with_block(assigns))
IO.puts(BuiltinHelpersGuide.lookup_map(assigns, %{}))
IO.puts(BuiltinHelpersGuide.lookup_list(assigns, %{}))
IO.puts(BuiltinHelpersGuide.pipeline_name(assigns, %{}))
IO.puts(BuiltinHelpersGuide.pipeline_people(assigns, %{}))
IO.puts(BuiltinHelpersGuide.pipeline_default(assigns, %{}))
