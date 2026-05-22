---
id: 20260522213128
aliases: ["Jinja2 Gap", "Inline Assignments", "Inline Logic"]
tags: ["architecture", "jinja2", "logic", "model-view-separation"]
---
Stem explicitly forbids Jinja2-style inline math operations and variable assignments within templates to guarantee strict model-view separation.

#### What
Jinja2 allows developers to perform inline mathematical calculations (e.g., `{{ 1 + 1 }}`) and mutate template state by assigning new variables using the `{% set %}` block. Stem rejects these features, requiring that templates remain purely declarative and side-effect free.

#### Why
Allowing state mutation and arbitrary math inside templates entangles generation logic with the view. This violates the functional purity principles derived from StringTemplate 4 (ST4), which state that restricting a template engine from arbitrary logic is tantamount to requiring a functional programming approach. Furthermore, Jinja2 relies on a runtime `SandboxedEnvironment` to intercept and prohibit malicious mutations. Stem avoids this runtime overhead and vulnerability surface entirely by locking the AST at compile-time and relying on the host Elixir controller for all logic.

#### How
When migrating from Jinja2, developers must shift business logic and calculations to the Elixir backend (Backend Pre-Rendering). If data needs to be shaped specifically for presentation, developers must explicitly register and pipe data through safe Elixir functions using Stem's Transformer Capability Groups.

#### Links
* [[Strict Model-View Separation and State Isolation]] - The StringTemplate-derived boundary.
* [[Compile-Time-Only Security Model]] - Why runtime state mutation is forbidden.
