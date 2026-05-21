---
id: 20260521131100
aliases: [Truthiness]
tags: [semantics, logic]
---
Block conditionals in Stem follow Elixir truthiness rules: only `false` and `nil` are falsey, while all other values are truthy.

## What

In `{{#if expr}}` and `{{#unless expr}}`, the condition is checked using Elixir's native logic. Unlike JavaScript Handlebars, `0`, `""`, and `[]` are considered truthy in Stem because they are truthy in Elixir.

## Why

Mapping Handlebars to Elixir's native `if` and `case` structures ensures there is no performance penalty for "translation" at runtime. It also avoids surprising behavior for Elixir developers who expect standard language semantics.

## How

If a template needs to treat an empty list or zero as falsey, use a helper or an explicit comparison expression: `{{#if (items != [])}}` or `{{#if (count > 0)}}`. The common pattern `{{#if list}}` will execute the block if `list` is defined, even if empty.

## Links

- [[Handlebars-Inspired Philosophy]] - The rationale for choosing Elixir semantics.
- [[Iteration and Context Scoping]] - How truthiness affects `{{#each}}` and `{{else}}` blocks.
