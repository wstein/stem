---
id: 20260527000633
aliases: []
tags: ['compiler', 'parser', 'semantics', 'native', 'design', 'spec', 'v0-4-0']
---

**Spec for ADR-0010 (targets 0.4.0, not yet implemented).** Replaces the `first`/`last`/`take`/`drop`/`slice` transformers and the unified `items.[2]` path-index with a bracket selector. Breaking.

## Grammar

Lists use a **bare** bracket; maps use the **dotted** bracket; one rule governs the bracket *content*:

- **number** → literal index or slice bound.
- **`"quoted"`** (or `'…'`) → literal key.
- **bare identifier/path** → resolve it (dynamic indirection).

A bare `map.key` is a literal identifier key (unchanged).

| form | meaning |
|---|---|
| `list[2]` | literal index 2 (0-based) |
| `list[-1]` | last (negative counts from the end) |
| `list[a..b]` | inclusive slice, indices a..b |
| `list[a..]` / `list[..b]` | open bound → start/end |
| `list[1..m]` | dynamic upper bound: resolve `m` to an int |
| `list[i]` | dynamic index: resolve `i` to an int |
| `map.key` / `map.["my key"]` | literal key (identifier / quoted for spaces) |
| `map.[k]` | dynamic key: resolve `k`, use its value as the key |

## Semantics (must be byte-identical on both backends)

- **index** — list + int → element (Elixir `Enum.at`, negatives from end); map + string/atom → key lookup (atom-preferred, string fallback); otherwise empty (`nil`).
- **slice** — list only, **inclusive** (`Enum.slice(list, s..e)`); open start defaults 0, open end defaults `-1`; negatives from the end; out-of-range **clamps**; returns a **list**. Non-list base → empty.
- **Bounds and index follow the same content rule:** each is an integer literal, a resolved identifier/path, or (for a bound) empty/open. So `list[i]`, `list[1..m]`, `list[i..]`, `list[a..b]` all resolve their numeric parts the same way. A resolved value that isn't an integer → empty.
- **Strict by syntax (recommended, confirm at impl):** a *bare* `[…]` accesses lists only (map base → empty); a *dotted* `.[…]` accesses maps only (list base → empty). This is the "distinguish list-index from map-key" benefit; the lenient alternative (resolve by runtime type regardless of bracket) is the fallback if strict proves awkward.

## Wire shape (additive)

Plain dotted identifier paths (`a.b.c`) keep the existing `get`/path-segment representation. Bracket access adds two ops to `stem-ast/v1` and `stem-bc/v1`:

- `{"t":"index","base":<op>,"key":<op>}` — `key` is a value op (lit int, lit string, or a resolved path).
- `{"t":"slice","base":<op>,"start":<op|null>,"end":<op|null>}` — inclusive; null = open bound; `start`/`end` may be lit ints or resolved paths.

## Removed transformers

`first`, `last`, `take`, `drop`, `slice` (subsumed: `first`=`[0]`, `last`=`[-1]`, `rest`=`[1..]`, butlast=`[..-2]`, `take n`=`[..n-1]`, `drop n`=`[n..]`). **Keep** the `@first`/`@last` iteration vars and `reverse`/`sort`/`sort_by`/`filter`/`map`/`group_by`/`compact`/`flatten`/`uniq`/`join`/`split`. Index/slice are core language (no capability gate); removal shrinks the Format/Transform groups.

## Migration (0.3.0 → 0.4.0)

- `items.[2]` → `items[2]`
- `user.[full name]` → `user.["full name"]`
- `x | first` → `x[0]`; `| last` → `x[-1]`; `| take 3` → `x[..2]`; `| drop 2` → `x[2..]`; `| slice 1 3` → `x[1..3]`

## Phases (each gated by compile_diff / verify / fuzz)

1. Elixir parse + AST + VM (spec oracle) + tests.
2. Rust parse (`np_expr`) + lower + VM (byte-parity).
3. Remove the five transformers (both backends + group registrations).
4. Conformance vectors for index/slice/dynamic.
5. Examples, cheat-sheet, playground, changelog (0.4.0), migration guide.


## Links

- [[Handlebars Expression Resolution]] — the resolution model this extends.
- [[Iteration and Context Scoping]] — `@first`/`@last` vars (kept) vs the removed transformers.
- [[Transformer Capability Groups]] — the groups that shrink when the five go.
- [[Portable Stem Bytecode]] — the wire format gaining `index`/`slice`.
