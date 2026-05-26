---
id: 20260526143001
title: "Native Conformance Parity Gaps"
aliases: []
tags: ['testing', 'native', 'conformance', 'parity']
---

Cross-backend conformance is green for the core corpus, but a small set of native formatting behaviors remain tracked, explicit exceptions rather than silent drift.

## What

The native core implements the built-in transformer groups byte-for-byte where the corpus exercises them: Minimum, Strings, Collections, and Predicates are gated by capability group exactly as the BEAM dispatcher gates the `transformers:` binding (see [[Helper Capability Groups]]). The render request carries loaded groups in its `transformers` list, and a call into an unloaded group is refused before render with a group-naming message. `json` and `inspect` render natively over the JSON value domain, and `log` renders to `""`.

The `i18n` group's `t` and `translate` remain host-delegated. They are resolved through the custom-transformer hook, requiring both the group and a host translator. Host transformers live in the embedder, carry no cross-backend parity guarantee, and stay out of the conformance corpus.

## Known divergences

These are the remaining value-formatting points where the native Rust/WASM core does not yet match the BEAM oracle byte-for-byte. They are deliberately kept out of the conformance corpus and the differential fuzzer, so a green suite does not imply parity here.

- **G2 - float formatting. (Resolved.)** Floats now render byte-for-byte: the native core uses round-trippable JSON float decoding, shortest-digit formatting, and Erlang's notation policy. Float vectors are now in the corpus.
- **G4 - Unicode casing.** `upcase` and `downcase` are only verified for ASCII; locale-sensitive non-ASCII casing may still diverge.
- **G5 - map key order.** Native sorts JSON object keys, while the BEAM's map iteration order varies by key type and size, so multi-key object iteration and `json` object key order are not cross-backend stable.
- **G6 - heterogeneous `sort` and `sort_by`.** The native comparator is only an approximation of Elixir term ordering, so mixed-type lists may order differently.
- **G7 - `inspect` of maps.** Native values are string-keyed, while the BEAM conformance harness can print atom-keyed maps differently.

## How

Sequencing for these gaps is driven by the parity-matrix work: generate a per-construct, per-type match/divergent/unsupported table from the corpus generator, then rank fixes by observed frequency rather than guesswork. Until then, treat Unicode casing, large-map iteration, heterogeneous sort, and map `inspect` output from the native backend as unverified, and prefer the BEAM backend when byte parity matters.

Render-time refused features are a separate class: transformers from an unloaded group, `i18n` without a host translator, keyword args to a built-in, and `url` or custom escape modes return structured errors rather than diverging silently.

## Links

- [[Cross-Backend Conformance Spec]] - The core conformance contract this note narrows.
- [[Portable Stem Bytecode]] - Render-time refusal behavior is implemented on the bytecode/native path.
- [[Helper Capability Groups]] - Capability-group gating remains part of parity.
