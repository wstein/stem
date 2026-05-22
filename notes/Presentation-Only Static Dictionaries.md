---
id: 20260522191248
aliases:
  - Static Presentation Dictionaries
  - Presentation-Only Dictionaries
tags:
  - security
  - dsl
  - compile-time
---

Presentation-only static dictionaries are compile-time validated lookup tables
for template modules: they are meant to supply small bits of view data, not to
load arbitrary application state or execute host code while a template is being
declared.

## What

`defdictionary/2` accepts only static literal structures for presentation data:
maps, lists, strings, numbers, booleans, and `nil`. Module attributes are
allowed only when they expand to those literal forms at the point of declaration.
The dictionary contents are merged into template assigns in declaration order,
and explicit caller assigns still take precedence.

### Module attribute support

`defdictionary :name, @my_attr` is accepted when `@my_attr` has been set to a
literal value earlier in the same module. Elixir's two-phase compilation means
the attribute value cannot be read inside the macro expansion body; instead, a
sentinel `{:__stem_attr_ref__, :my_attr}` is stored at macro time and resolved
to the real value at render time via the compiled `__stem_dictionary__/1` lookup.
The linter still validates the attribute's value and rejects non-literals.

## Why

This keeps the feature inside Stem's compile-time security boundary. The DSL
can support small lookup tables without becoming a general host-language data
loader, which reduces the chance of side effects, surprise I/O, or hidden SSTI
gadget chains in template definitions.

## How

Treat dictionaries as presentation glue only. Use `defdictionary_merge/2` when
you need explicit composition of multiple named dictionaries, and keep values
literal so the compile-time linter can reject unsafe expressions before code
generation starts.

## Links

- [[Compile-Time-Only Security Model]] - The security boundary this feature
  must respect.
- [[Native AST Compilation Pipeline]] - Where template modules are lowered into
  compiled Elixir.
- [[Strict Model-View Separation and State Isolation]] - The architectural
  reason templates should not execute host logic.
