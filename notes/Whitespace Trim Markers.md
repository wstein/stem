---
id: 20260521165100
aliases: []
tags: [syntax, formatting]
---
Stem provides declarative, tag-level whitespace control using the `~` character to adjust spacing around rendered content.

## What

Whitespace trim markers (`~`) allow removing adjacent literal whitespace from the template around any tag boundary. Stem supports symmetric trimming (`{{~ ... ~}}`) as well as precise one-sided variants (`{{~ ... }}` and `{{ ... ~}}`). These markers act on the literal text surrounding the tag, not on the value produced by the expression itself.

## Why

Template source often requires indentation or newlines for human readability that should not appear in the final rendered output (e.g., inside lists or deep logic blocks). Without native trim markers, developers are forced to choose between readable source and correctly-formatted output.

## How

Apply a leading `~` immediately after the opening braces (`{{~`) to remove literal whitespace preceding the tag. Apply a trailing `~` immediately before the closing braces (`~}}`) to remove literal whitespace following the tag. Use these markers on both sides of logic tags (like `if` or `each`) to prevent unwanted newlines or indentation from accumulating in the output stream. For data values, use `~` to anchor the value precisely against neighboring text.

## Links

- [[Native AST Compilation Pipeline]] - Where these markers are handled at the tokenization stage.
- [[Handlebars-Inspired Philosophy]] - The stylistic origin of this whitespace control model.
