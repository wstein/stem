---
id: 20260522213129
aliases: ["Handlebars Gap", "Dynamic Block Helpers", "XSS Security"]
tags: ["architecture", "handlebars", "security", "blocks", "capabilities"]
---
Stem strictly hardcodes its structural control-flow blocks (`#if`, `#unless`, `#each`, `#with`, `#region`) and forbids the dynamic registration of custom execution blocks (Block Helpers) found in Handlebars.

#### What
Handlebars allows developers to dynamically register custom block helpers (`Handlebars.registerHelper`) that receive the block's internal content and context, effectively allowing the template to imperatively dictate execution flow. Stem rejects this mechanism.

#### Why
Handlebars' dynamic execution contexts and custom helpers frequently introduce Cross-Site Scripting (XSS) and Server-Side Template Injection (SSTI) vulnerabilities. If a custom helper carelessly returns an unescaped string, it bypasses the engine's protections—a flaw exploited in real-world platforms like Asana. By permanently locking the structural AST nodes during the compile phase and auto-escaping all `{{ }}` outputs, Stem eliminates these runtime injection vectors.

#### How
Instead of writing dynamic block helpers to filter or conditionally render data, developers using Stem must use a combination of explicitly imported Transformer Capability Groups and the hardcoded structural blocks. For example, to iterate over a filtered list, transform the data first (`{{#each users |> custom_filter}}`) and rely on the native `#each` block for secure structural rendering.

#### Links
* [[Transformer Capability Groups]] - How to safely extend template capabilities.
* [[Native AST Compilation Pipeline]] - Why blocks must be hardcoded at compile time.
* [[HTML Escaping Behavior]] - Stem's secure-by-default output guarantees.
