---
id: 20260526143002
title: "Transformer Capability Group Operations"
aliases: []
tags: ['security', 'transformers', 'operations', 'capabilities']
---

Loading and auditing transformer capability groups is operational policy layered on top of the core capability model in [[Helper Capability Groups]].

## Loading groups

Runtime APIs take a flat `transformers:` function map; call `.all()` on each group and `Map.merge/2` to combine them.

```elixir
# Explicit opt-in for Strings
Stem.Unsafe.eval_string("{{name | trim | upcase}}",
  assigns: [name: "nina"],
  transformers: Stem.Transformers.Strings.all())

# Multiple groups
Stem.Unsafe.eval_string("{{items | map author | take 5}}",
  assigns: [items: books],
  transformers: Map.merge(
    Stem.Transformers.Collections.all(),
    Stem.Transformers.Strings.all()
  ))
```

Pin defaults in `.stem.config.json` as comma-separated module names:

```json
{ "transformers": "Stem.Transformers.Strings,Stem.Transformers.Collections" }
```

## Discovering the right group

`Stem.Transformers.Standard.all/0` bundles Minimum plus Strings for common string work. When a template uses a transformer from an unloaded group, `invoke/3` raises a `Stem.SyntaxError` naming the providing group and how to enable it. Each group's side-effect-free `names/0` powers that lookup.

## Auditing and extension

`Collections.all/0` emits an audit signal: a `[:stem, :capability_group, :loaded]` telemetry event when `:telemetry` is present, else a `Logger.warning`. Custom transformers can be registered globally with `Stem.Transformers.register/2`, or passed per call by merging into the `transformers:` map.

## Migration

To adopt groups, add `transformers: SomeGroup.all()` or a `Map.merge/2` of groups to `eval_string/3` or `eval_file/3`, and pin defaults in `.stem.config.json`. Compile-time templates inline operations at build time and need no migration.

## Links

- [[Helper Capability Groups]] - Core capability model and threat framing.
- [[Runtime Evaluation and Sandboxing]] - The runtime APIs that accept transformer maps.
- [[CI Security Gates]] - Audit-task background.
