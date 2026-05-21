---
id: 20260521165200
title: "Strict CLI Contract and Launcher"
aliases: []
tags: ['cli', 'dev-tooling']
---

#### What
The Stem CLI supports two primary rendering modes modeled after standard Mustache conventions:
1. **File + File**: Providing two arguments (`bin/stem data.json template.stem`) binds the template to data read from the first file.
2. **Stdin + File**: Providing one argument (`echo '...' | bin/stem template.stem`) binds the template to JSON read from standard input.
It also natively supports configuration flags, such as `--escape MODE` (`none`, `html`, `xml`, `json`, `url`), which override project defaults. 

#### Why
Earlier versions allowed flexible "inline" JSON strings directly in positional arguments, which created security-sensitive ambiguity between data values and file paths. By restricting the CLI to file-backed or pipe-backed JSON, Stem reinforces its security model of explicit input boundaries.

#### How
Use `bin/stem` for local development, shell pipelines, and testing template rendering. Pipe JSON from tools like `jq` or `curl` directly into the single-argument form for dynamic testing. Pass `--escape <mode>` to alter escaping behavior at runtime. The CLI explicitly rejects positional JSON strings to prevent accidental execution of untrusted data fragments.

#### Links
* [[Compile-Time-Only Security Model]] - The architecture this CLI contract protects.
* [[Configuration and Frontmatter]] - How CLI flags interact with config hierarchies.

## Links
