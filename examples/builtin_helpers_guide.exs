# SPDX-License-Identifier: Apache-2.0

# Each built-in helper and block is compiled into a named function. Runtime
# evaluation of template source is intentionally disabled, so the guide renders
# through a compiled module defined with the Stem DSL.
defmodule BuiltinHelpersGuide do
  use Stem.DSL

  handlebars(:if_block, "{{#if isActive}}active{{else}}inactive{{/if}}", [:assigns])
  handlebars(:if_truthy, "{{#if count}}non-empty{{else}}empty{{/if}}", [:assigns])
  handlebars(:unless_block, "{{#unless isActive}}inactive{{/unless}}", [:assigns])
  handlebars(:each_index, "{{#each items}}{{@index}}:{{this}};{{/each}}", [:assigns])
  handlebars(:each_key, "{{#each map}}{{@key}}: {{this}}{{/each}}", [:assigns])
  handlebars(:with_block, "{{#with story}}{{this.title}} by {{this.author}}{{/with}}", [:assigns])
  handlebars(:lookup_map, ~s({{lookup person "firstName"}}), [:assigns, :helpers])
  handlebars(:lookup_list, "{{lookup values 1}}", [:assigns, :helpers])
end

assigns = [
  isActive: true,
  count: 0,
  items: ["alpha", "beta"],
  story: %{title: "The Story", author: "A. Writer"},
  map: %{firstName: "Homer"},
  person: %{"firstName" => "Nils"},
  values: ["a", "b"]
]

IO.puts(BuiltinHelpersGuide.if_block(assigns))
IO.puts(BuiltinHelpersGuide.if_truthy(assigns))
IO.puts(BuiltinHelpersGuide.unless_block(assigns))
IO.puts(BuiltinHelpersGuide.each_index(assigns))
IO.puts(BuiltinHelpersGuide.each_key(assigns))
IO.puts(BuiltinHelpersGuide.with_block(assigns))
IO.puts(BuiltinHelpersGuide.lookup_map(assigns, []))
IO.puts(BuiltinHelpersGuide.lookup_list(assigns, []))
