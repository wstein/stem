# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Conformance do
  @moduledoc """
  Canonical cross-backend conformance corpus for Stem.

  Each vector pairs a template and JSON-serializable data with the output the
  reference (BEAM) backend produces. The corpus is the single source of truth
  for `conformance/vectors.json`, the portable artifact a non-BEAM
  implementation can validate against. Regenerate the file with:

      mix stem.conformance

  The Elixir test suite uses the same corpus to assert that both the compiled
  backend (`Stem.compile_string/2`) and the bytecode VM (`Stem.Bytecode.VM`)
  reproduce every `expected` output exactly.

  ## Vector shape

  A corpus vector is a map with:

    * `:name` — a unique, human-readable label.
    * `:template` — the Stem source.
    * `:data` — the assigns, as JSON-serializable values. Assign resolution is by
      name, so a host maps these keys onto its own convention (the BEAM backend
      uses atom keys; the JSON artifact uses string keys).
    * `:transformers` — the built-in capability groups to load, by name.
    * `:escape` — the default escape mode (defaults to `:html`).

  `vectors/0` adds the computed `:expected` output; `to_json/0` serializes them.
  """

  @corpus [
    %{name: "plain text", template: "Just text, no tags.", data: %{}, transformers: []},
    %{
      name: "escaped assign",
      template: "<p>{{body}}</p>",
      data: %{body: "<script>x</script>"},
      transformers: []
    },
    %{
      name: "raw assign",
      template: "<p>{{{body}}}</p>",
      data: %{body: "<b>ok</b>"},
      transformers: []
    },
    %{name: "missing assign", template: "[{{nope}}]", data: %{}, transformers: []},
    %{
      name: "nested path",
      template: "{{user.name}} <{{user.email}}>",
      data: %{user: %{name: "Nina", email: "n@x.io"}},
      transformers: []
    },
    %{name: "parent path", template: "{{../title}}", data: %{title: "Home"}, transformers: []},
    %{
      name: "string pipeline",
      template: "{{name |> trim |> upcase}}",
      data: %{name: "  nina  "},
      transformers: [:strings]
    },
    %{
      name: "collection join",
      template: "{{tags |> join(\", \")}}",
      data: %{tags: ["a", "b", "c"]},
      transformers: [:minimum]
    },
    %{
      name: "selector map",
      template: "{{users |> map(\"name\") |> join(\", \")}}",
      data: %{users: [%{name: "A"}, %{name: "B"}]},
      transformers: [:minimum, :collections]
    },
    %{
      name: "default with literal",
      template: "{{default missing \"none\"}}",
      data: %{},
      transformers: [:minimum]
    },
    %{
      name: "builtin subexpression",
      template: "{{upcase (downcase name)}}",
      data: %{name: "NiNa"},
      transformers: [:strings]
    },
    %{
      name: "predicate",
      template: "{{contains tags \"a\"}}",
      data: %{tags: ["a", "b"]},
      transformers: [:predicates]
    },
    %{
      name: "json escape mode",
      template: "{{x}}",
      data: %{x: "quote \" here"},
      transformers: [],
      escape: :json
    },
    %{name: "numeric assign", template: "n={{n}}", data: %{n: 42}, transformers: []},
    %{
      name: "if/else true",
      template: "{{#if active}}on{{else}}off{{/if}}",
      data: %{active: true},
      transformers: []
    },
    %{
      name: "if/else false",
      template: "{{#if active}}on{{else}}off{{/if}}",
      data: %{active: false},
      transformers: []
    },
    %{
      name: "unless",
      template: "{{#unless active}}hidden{{/unless}}",
      data: %{active: false},
      transformers: []
    },
    %{
      name: "each with this and index",
      template: "{{#each items}}{{@index}}:{{this}} {{/each}}",
      data: %{items: ["x", "y"]},
      transformers: []
    },
    %{
      name: "each with block params",
      template: "{{#each items as |item idx|}}{{idx}}={{item}};{{/each}}",
      data: %{items: ["a", "b"]},
      transformers: []
    },
    %{
      name: "each with one-based index",
      template: "{{#each items as |item i0 i1|}}{{i0}}/{{i1}}:{{item}} {{/each}}",
      data: %{items: ["a", "b"]},
      transformers: []
    },
    # A single-entry map keeps the stored `:expected` deterministic — multi-key
    # map iteration order is not stable across BEAM instances, which would make
    # the checked-in vector flap. (In-process differential parity still holds for
    # any map, since both backends iterate the same map identically.)
    %{
      name: "each over a map with key",
      template: "{{#each rows}}{{@key}}={{this}} {{/each}}",
      data: %{rows: %{role: "admin"}},
      transformers: []
    },
    %{
      name: "each empty else",
      template: "{{#each items}}{{this}}{{else}}none{{/each}}",
      data: %{items: []},
      transformers: []
    },
    %{
      name: "each with transformer",
      template: "{{#each names}}{{this |> upcase}} {{/each}}",
      data: %{names: ["a", "b"]},
      transformers: [:strings]
    },
    %{
      name: "with this-field",
      template: "{{#with user}}{{this.name}}{{/with}}",
      data: %{user: %{name: "Nina"}},
      transformers: []
    },
    %{
      name: "with block param and else",
      template: "{{#with user as |u|}}{{u.name}}{{else}}none{{/with}}",
      data: %{user: %{name: "A"}},
      transformers: []
    },
    %{
      name: "nested each and if",
      template: "{{#each items}}{{#if this}}<{{this}}>{{/if}}{{/each}}",
      data: %{items: ["a", "", "b"]},
      transformers: []
    },
    %{
      name: "region and yield",
      template: "{{#region body}}Hi {{name}}{{/region}}<main>{{yield body}}</main>",
      data: %{name: "Nina"},
      transformers: []
    }
  ]

  @doc "The canonical corpus of conformance vectors (without computed output)."
  @spec corpus() :: [map()]
  def corpus, do: @corpus

  @doc "The corpus with each vector's reference `:expected` output computed."
  @spec vectors() :: [map()]
  def vectors do
    Enum.map(@corpus, fn vector -> Map.put(vector, :expected, render_with_compiler(vector)) end)
  end

  @doc "Serializes the computed vectors to a JSON array, one vector per line."
  @spec to_json() :: binary()
  def to_json do
    body =
      vectors()
      |> Enum.map_join(",\n", fn vector -> "  " <> JSON.encode!(to_json_vector(vector)) end)

    "[\n" <> body <> "\n]\n"
  end

  @doc "Renders a vector through the compiled backend (`Stem.compile_string/2`)."
  @spec render_with_compiler(map()) :: binary()
  def render_with_compiler(vector) do
    quoted = Stem.compile_string(vector.template, escape: escape(vector))

    {result, _binding} =
      Code.eval_quoted(quoted,
        assigns: vector.data,
        transformers: groups_to_transformers(vector.transformers)
      )

    result
  end

  @doc "Renders a vector through the bytecode VM (`Stem.Bytecode.VM`)."
  @spec render_with_vm(map()) :: binary()
  def render_with_vm(vector) do
    {:ok, ast} = Stem.Parser.parse_with_spans(vector.template)
    program = Stem.Bytecode.compile(ast, escape: escape(vector))

    Stem.Bytecode.VM.render(program,
      assigns: vector.data,
      transformers: groups_to_transformers(vector.transformers)
    )
  end

  @doc "Builds the merged transformer map for a list of built-in group names."
  @spec groups_to_transformers([atom()]) :: map()
  def groups_to_transformers(groups) do
    registry = Stem.Transformers.groups()
    Enum.reduce(groups, %{}, fn group, acc -> Map.merge(acc, registry[group].all()) end)
  end

  @doc """
  Parses a JSON-decoded vector into the internal form `render_*` expects.

  String data keys become atoms (assign resolution is by name) and the group
  and escape names become atoms.
  """
  @spec vector_from_json(map()) :: map()
  def vector_from_json(json) do
    %{
      name: json["name"],
      template: json["template"],
      data: atomize(json["data"]),
      transformers: Enum.map(json["transformers"], &String.to_atom/1),
      escape: String.to_atom(json["escape"]),
      expected: json["expected"]
    }
  end

  defp to_json_vector(vector) do
    %{
      "name" => vector.name,
      "template" => vector.template,
      "data" => vector.data,
      "transformers" => Enum.map(vector.transformers, &Atom.to_string/1),
      "escape" => Atom.to_string(escape(vector)),
      "expected" => vector.expected
    }
  end

  defp escape(vector), do: Map.get(vector, :escape, :html)

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {String.to_atom(key), atomize(value)} end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(other), do: other
end
