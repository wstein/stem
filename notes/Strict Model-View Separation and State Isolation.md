---
id: 20260522100000
title: "Strict Model-View Separation and State Isolation"
aliases: []
tags: ['security', 'architecture', 'design']
---

#### What
Stem templates act as purely declarative views. They have zero direct access to the host environment: they cannot read environment variables (e.g., `System.get_env/1`) or execute arbitrary backend queries. All necessary data must be explicitly injected into the template's `assigns` by the host Elixir controller.

#### Why
Allowing templates to access global state or execute arbitrary logic violates separation of concerns, tangling generation logic with presentation code. Enforcing a strict boundary keeps templates portable, reusable, and secure against data-exfiltration Server-Side Template Injection (SSTI) attacks. Templates act as exemplars of the desired output with holes where the programmer sticks values — nothing more.

#### How
Fetch all necessary data (API URLs, database records, configuration flags) in the Elixir controller and pass it explicitly via the `assigns` keyword list to your compiled template macros or `Stem.Unsafe` runtime functions. Do not call Elixir system or I/O functions from inside `.stem` files. The compiler's default `mode: :safe` enforces this boundary at compile time.

#### Links
- [[Handlebars-Inspired Philosophy]] - The declarative syntax that enforces this boundary.
- [[Compile-Time-Only Security Model]] - How the strict boundary protects the host application.
- [[Runtime Evaluation and Sandboxing]] - What happens when you need dynamic templates.
