---
id: 20260521214949
aliases: []
tags: [configuration, syntax, frontmatter]
---

#### What

Stem supports hierarchical configuration via project-level `.stem.config.json` files and per-template YAML frontmatter. Frontmatter is designated using `---` delimiters at the very top of a `.stem` file. Projects can also set `lock_security: true` to keep template frontmatter from overriding project-level `escape` and `mode` decisions.

#### Why

This enables projects and individual templates to declare their own default settings such as `escape` modes, `warn_on_missing_assigns`, and safe `mode` without forcing the calling Elixir code to specify them on every invocation. The security lock gives teams a project-wide guardrail so one template cannot silently weaken escaping or safe-mode defaults.

#### How

Define global project defaults by creating a `.stem.config.json` file in your project root. For template-specific overrides, add YAML frontmatter to your `.stem` files. Stem automatically discovers and resolves configuration in the following precedence order from highest to lowest: explicit API options > YAML Frontmatter > CLI flags > `.stem.config.json` > default engine settings. When `lock_security` is enabled in project config, frontmatter can still override non-security settings, but `escape` and `mode` stay pinned to the project-level values.

#### Links

* [[HTML Escaping Behavior]] - How to set escape modes via configuration.
* [[Strict CLI Contract and Launcher]] - CLI configuration overrides.
* [[Compile-Time-Only Security Model]] - Why projects may pin safe-mode behavior globally.

Projects that need hard security boundaries should enable `lock_security: true` in project config.

