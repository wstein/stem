---
id: 20260522140000
title: "Transformer Capability Groups"
aliases: []
tags: ['security', 'transformers', 'api', 'capabilities']
---

## What

Stem uses helper capability groups to keep runtime template evaluation secure by default. Only a small minimum set is always available; richer string, collection, and predicate helpers must be opted into explicitly.

## Why

The goal is to reduce SSTI blast radius. If a template source is less trusted, it should not automatically receive helpers that can reshape collections or expose internal data. The opt-in model also makes security review easier because enabled helper groups are visible at the call site or in config.

## Groups

- `Stem.Transformers.Minimum`: always available; escaping, `default`, `lookup`, `join`, `log`, `inspect`, `json`
- `Stem.Transformers.Strings`: text helpers such as `trim`, `upcase`, `truncate`, `replace`, `take`, `drop`, `slice`, `first`, `reverse`
- `Stem.Transformers.Collections`: collection helpers such as `map`, `filter`, `sort_by`, `group_by`, `compact`, `uniq`, `flatten`, `take`, `drop`, `slice`, `first`, `reverse`
- `Stem.Transformers.Predicates`: boolean helpers such as `contains`, `empty?`, `present?`

## Loading

At runtime, pass a flat `transformers:` map to `Stem.Unsafe.eval_string/3` or `Stem.Unsafe.eval_file/3`. Build that map from one or more `.all()` calls and merge them when needed.

```elixir
Stem.Unsafe.eval_string(
  "{{name |> trim |> upcase}}",
  assigns: [name: "nina"],
  transformers: Stem.Transformers.Strings.all()
)

Stem.Unsafe.eval_string(
  "{{items |> map(author) |> take(5)}}",
  assigns: [items: books],
  transformers: Map.merge(
    Stem.Transformers.Collections.all(),
    Stem.Transformers.Strings.all()
  )
)
```

In `.stem.config.json`, enable groups with a comma-separated module list:

```json
{"transformers": "Stem.Transformers.Strings,Stem.Transformers.Collections"}
```

Custom transformers can still be registered globally with `Stem.Transformers.register/2` or merged into the runtime map.

## Migration

Existing code that already uses `Stem.Transformers` is unaffected. To adopt capability groups, choose the smallest helper set each template needs, merge the required groups at runtime, and pin defaults in config for recurring cases.
