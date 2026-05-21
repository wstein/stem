---
id: 20260521214949
aliases: []
tags: ['configuration', 'syntax', 'frontmatter']
---

#### What
Stem supports hierarchical configuration via project-level `.stem.config.json` files and per-template YAML frontmatter. Frontmatter is designated using `---` delimiters at the very top of a `.stem` file. 

#### Why
This enables projects and individual templates to declare their own default settings—such as `escape` modes, `warn_on_missing_assigns`, and safe `mode`—without forcing the calling Elixir code to specify them on every invocation.

#### How
Define global project defaults by creating a `.stem.config.json` file in your project root. For template-specific overrides, add YAML frontmatter to your `.stem` files. Stem automatically discovers and resolves configuration in the following precedence order (highest to lowest): explicit API options > YAML Frontmatter > CLI flags > `.stem.config.json` > default engine settings.

#### Links
* [[HTML Escaping Behavior]] - How to set escape modes via configuration.
* [[Strict CLI Contract and Launcher]] - CLI configuration overrides.
## Links

