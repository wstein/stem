# Meeting Minutes: Stem Syntax Transition (Handlebars-inspired)

**Date**: 2026-03-05
**Team**: University Professor, Software Engineer, Technical Writer
**Goal**: Transition Stem from EEx-style tags (`<%= %>`) to Handlebars-style tags (`{{ }}`) and update branding to emphasize a robust, secure DSL for Elixir.

## Discussion Points

1.  **Vision Change**: Move away from simply "embedding Elixir safely" to "providing a robust Handlebars-compliant DSL for Elixir."
2.  **Syntax Selection**: 
    - Output expression: `{{expression}}`
    - Comments: `{{! comment }}`
    - Literal/Quotation: `{{{{content}}}}` (Handlebars raw block style)
3.  **Engine Strategy**: The internal engine will need to be refactored to parse curly braces instead of angle brackets.
4.  **No Backwards Compatibility**: Implementation will strictly follow the new syntax to avoid complexity during PoC.

## Action Items
- [x] Update project intro in working documents.
- [x] Update `README.md` with Handlebars examples.
- [x] Update `@moduledoc` in `lib/stem.ex`.
- [x] Implement new tokenizer/compiler for `{{ }}` syntax.

---

# Specification: Stem Handlebars Syntax

## 1. Overview
Stem will use a double-curly-brace syntax for its templating engine, aligning it with the Handlebars ecosystem while remaining powered by Elixir's macro system.

## 2. Grammar Rules

### 2.1 Output Expressions
- **Syntax**: `{{ expr }}`
- **Behavior**: Evaluates the Elixir expression `expr` and injects the string representation into the output.
- **Example**: `{{ name }}` or `{{ @user.name }}`.

### 2.2 Comments
- **Syntax**: `{{! comment content }}`
- **Behavior**: Content is ignored during compilation and does not appear in the final output.

### 2.3 Raw Blocks (Quotation)
- **Syntax**: `{{{{ raw content }}}}`
- **Behavior**: Returns the `raw content` as a literal string, allowing users to output handlebars-style text without evaluation.

## 3. API Changes

- `Stem.function_from_string/5` and `Stem.function_from_file/5`: compile `{{ }}` templates into functions at compile time.
- `Stem.eval_string/3` and `Stem.eval_file/3`: disabled; they raise `Stem.SecurityError` because template source is never evaluated at runtime.

## 4. Implementation Details (delivered)

The `{{ }}` syntax is compiled by a native pipeline that no longer depends on EEx:

- `Stem.Tokenizer` scans source into structural tokens.
- `Stem.Parser` matches blocks and partials into a `Stem.AST`.
- `Stem.Compiler` lowers the AST into quoted Elixir, with `Stem.Expression` translating tag contents.

The EEx tokenizer, compiler, and engine modules, along with the string preprocessor, have been removed.
