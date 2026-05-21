---
id: 20260521214949
aliases: []
tags: [configuration, syntax]
---

#### What

Stem supports project-level configuration via `.stem.config.json` files plus explicit compile or eval options supplied by the caller. Template files are compiled literally; configuration no longer lives inside `.stem` source.

#### Why

This keeps template source purely about rendering structure while giving applications one clear place to pin defaults such as `escape`, `warn_on_missing_assigns`, and compiler `mode`. Removing in-template configuration also removes a hidden override path from file-based compilation.

#### How

Define global defaults by creating a `.stem.config.json` file in your project root. Stem discovers that file automatically and merges it beneath explicit compile or eval options. The effective precedence is: explicit API options > CLI flags > `.stem.config.json` > engine defaults.

#### Links

* [[HTML Escaping Behavior]] - How to set escape modes via configuration.
* [[Strict CLI Contract and Launcher]] - CLI configuration overrides.
* [[Compile-Time-Only Security Model]] - Why projects may pin safe-mode behavior globally.
