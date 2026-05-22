---
id: 20260522181822
aliases: []
tags: ['architecture', 'design', 'security', 'rationale']
---

#### What
Stem's core constraints — strict model-view separation, capability-grouped transformers, and compiler-enforced auto-escaping — are ecosystem-independent. They would benefit a template engine in any language, not just Elixir.

#### Why these principles are universal
- **Strict model-view separation**: From Terence Parr's StringTemplate research — forbidding arbitrary code in templates keeps the view from mutating application state. Logic stays in the backend controller; the template is only an "exemplar of the desired output," making it portable, maintainable, and unable to leak business logic (see [[Strict Model-View Separation and State Isolation]]).
- **Defeating SSTI via capability management**: Server-Side Template Injection chains powerful operations to exfiltrate data. Stem applies the Principle of Least Privilege through opt-in transformer capability groups (`Stem.Transformers.Minimum` is always on; `Strings`, `Collections`, `Predicates` are explicitly loaded; the CLI gates them with `--transformers`). Isolating powerful operations like `map`/`filter`/`group_by` shrinks the gadget chains an attacker can reach. This capability-based sandboxing transfers to Node.js, Python, or the JVM (see [[Transformer Capability Groups]] and [[Execution Modes Overview]]).
- **Secure-by-default escaping**: Manual escaping invites XSS through human fatigue. Stem auto-escapes every `{{ expression }}` at compile time and requires explicit `{{{ expression }}}` for raw output — security guaranteed without runtime overhead (see [[HTML Escaping Behavior]]).
- **The "output grammar" paradigm**: Treating generation as an inverted grammar (rather than imperative print statements) keeps output structured. This scales universally — HTML in Elixir, C in Python, XML in Java.

#### How to apply
When evaluating or extending Stem features, preserve these invariants regardless of host-language convenience: keep templates side-effect free, default to escaped output, and add powerful transformers only behind explicit capability groups. These are the portable parts of the design; the Elixir specifics (see [[Elixir as Host Language vs LISP Clojure]]) are the implementation, not the philosophy.

#### Links
- [[Strict Model-View Separation and State Isolation]] - The StringTemplate-derived boundary
- [[Transformer Capability Groups]] - The opt-in transformer modules that bound SSTI gadgets
- [[Execution Modes Overview]] - Safe vs. permissive enforcement of these constraints
- [[HTML Escaping Behavior]] - Compiler-enforced secure-by-default output
- [[Elixir as Host Language vs LISP Clojure]] - The host-specific counterpart to these portable ideas

## Links
