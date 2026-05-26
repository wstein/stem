---
id: 20260523140000
aliases: [bracket keys, literal keys, anonymous block param, underscore wildcard]
tags: [compiler, semantics, blocks, parser]
---

Stem can read data keys that are not valid identifiers — `first-name`, `a.b`, leading-digit or uppercase names — via **bracketed literal segments**, and treats `_` as an **anonymous/wildcard** block parameter. Neither feature requires the key or param to be a legal Elixir variable.

## What

- **Bracketed literal keys**: `{{[first-name]}}`, `{{user.[first-name]}}`, `{{[a.b]}}`. A `[...]` segment escapes any character a bare identifier cannot carry (dashes, spaces, dots, leading digits, reserved words like `this`). Segments compose with dots and with bare segments.
- **Uppercase / mixed-case bare names**: `{{Item1}}`, `as |Item|`, `as |I1|`. Bare names accept any leading letter; dashes/spaces still require brackets.
- **Anonymous param `_`**: in `as |...|` it skips a positional slot and may repeat (`as |_ _ i1|` reads only the one-based index). It is exempt from the uniqueness check and from the unused-parameter warning. Named params must still be unique.
- **`_` is only special as a param.** As an expression, `_` is an ordinary key, so a data key named `_` stays readable: `{{_}}`, `{{[_]}}`, and `{{@this.[_]}}` all resolve `{"_": 99}` to `99`.

## Why

The data model is key-by-name (assigns are atom-keyed; JSON keys are atomized), so any string is a representable key. The only obstacle was the compiled BEAM backend lowering keys/params back through *Elixir identifier source* — `@first-name` or a `first-name` variable are not valid syntax. Brackets and gensym binding remove that obstacle without a name-mangling scheme, so Unicode/dashes/uppercase "just work" and stay consistent across the compiled, bytecode, and native backends.

## How

- A reference is parsed as a dotted chain of segments, each a bare identifier or a `[..]` literal; the brackets are stripped to recover the key (`Stem.Expression`'s `reference_expression`, mirrored in the native `compile.rs`).
- Compiled backend: a literal assign key lowers to `@(:"first-name")` (an `@` on a quoted atom) which `Stem.Compiler.rewrite_assign/2` turns into `fetch_assign!`; a literal path member lowers to `current."first-name"` (atom-keyed dot access). Block params bind to gensyms (see [[Template Variable Hygiene]]).
- Bytecode/native backends are already key-by-string in the wire form, so a literal key is just `{"t":"assign","name":"first-name"}` / a `get` segment, and `_` stays a positional param in the wire `params` list. Parity is enforced by `mix stem.native.compile_diff`.

## Links

- [[Handlebars Expression Resolution]] - The resolution order brackets plug into.
- [[Each Index Variables and Block Params]] - Block-param forms and the `_` wildcard.
- [[Template Variable Hygiene]] - Gensym block params and the `@(:atom)` marker.
- [[Cross-Backend Conformance Spec]] - How the three backends are kept in lockstep.
