---
id: 20260522100002
title: "Layouts via Regions and Yields"
aliases: []
tags: ['layouts', 'templates', 'architecture']
---

#### What
Stem provides a first-class layout system through `{{#region name}}...{{/region}}` and `{{yield name}}` pairs. A partial that contains `{{yield header}}` and `{{yield body}}` acts as a layout template; the caller fills the slots by declaring matching `{{#region header}}...{{/region}}` blocks. Regions are extracted before compilation and wired into the layout at the yield sites.

#### Why
Without a dedicated slot mechanism, layout composition requires either string concatenation or outer-scope variable passing, both of which leak implementation details into the template. Named regions and yields allow layouts to stay declarative and self-describing, keeping data concerns in the controller and structural concerns inside the `.stem` files.

#### How
In the layout partial, mark the slots with `{{yield name}}`:
```handlebars
<html>
  <head><title>{{yield title}}</title></head>
  <body>{{yield body}}</body>
</html>
```
In the calling template, fill the slots with matching `{{#region name}}...{{/region}}` blocks, then include the layout partial:
```handlebars
{{#region title}}My Page{{/region}}
{{#region body}}<h1>Hello {{name}}</h1>{{/region}}
{{> layout}}
```
Unknown `{{yield name}}` targets that have no matching region expand to an empty string rather than raising.

#### Links
- [[Helper and Partial Resolution]] - How partials are expanded and how regions are extracted.
- [[Native AST Compilation Pipeline]] - Where region extraction happens in the AST walk.
