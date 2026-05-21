# Claude Guidelines

This file is written for both humans and AI (Claude).
It outlines how the Estache team works so that the model’s suggestions stay on track with our conventions.

## Principles

- **Clear structure**: use headings and bullet lists.
  One sentence per line.
- **Be explicit**: describe intent, not just actions.
  Claude can reason about tasks more easily when details are available.
- **Always update docs** whenever code or process changes.
  Outdated guidance confuses both humans and AI.

## Core Rules

1. **Semantic Versioning** – follow MAJOR.MINOR.PATCH.
2. **Conventional commits** – `type(scope): description`.
3. **Documentation formats**:
   - Documentation lives primarily in source files (`src`/code comments and module docs) and is generated from those sources.
   - `docs/` is generated output, not a hand-written source of truth.
   - Prefer AsciiDoc (`.adoc`) for detailed documentation (minutes, ADRs, manuals, deep dives).
   - Never duplicate documentation text across files.
   - Reuse content via AsciiDoc include/import functions and shared common/snippet files.
   - Always include original code snippets (no rewritten pseudo-snippets).
   - All console output shown in docs must be generated and captured via CLI.
   - `README.md` is a 101 starter for newcomers.
   - `GUIDELINES.md` mirrors this file in concise bullet form.
4. **Repository layout** – only essentials (README, LICENSE,
   GUIDELINES) at root; avoid scattered markdown.

## Code Examples

- **Conventional commits**:
  - `feat(parser): add block-helper argument validation`
  - `fix(renderer): escape triple-stash fallback path`
  - `docs(adoc): extract shared warning snippet`
  - `chore(ci): fail build when generated docs drift`
- **Semantic versioning scenarios**:
  - `0.4.2 -> 0.4.3` for bug fixes with no API change.
  - `0.4.2 -> 0.5.0` for backward-compatible features.
  - `0.4.2 -> 1.0.0` (or `0.x -> 0.(x+1).0` during MVP) for breaking API changes.
- **Documentation format examples**:
  - Source-of-truth API docs in code:
    - `@moduledoc` and `@doc` live with implementation in `lib/`.
  - Detailed docs in AsciiDoc with shared includes:
    - `include::../common/snippets/error-output.adoc[]`
    - `include::../common/snippets/cli-run-example.adoc[]`
- **CI/CD snippet example**:
```yaml
steps:
  - run: mix test
  - run: mix docs
  - run: ./scripts/generate_adoc_examples.sh
  - run: git diff --exit-code docs/
```

## Documentation Generation Process

- Source documentation is maintained in code (`@moduledoc`/`@doc`) and
  AsciiDoc source files.
- Generated documentation is produced only through checked-in CLI
  commands (Mix tasks and repo scripts), never manual copy/paste.
- Code snippets must be pulled from original source files or generated
  artifacts.
- Console output must be captured from real CLI runs and stored as
  snippets/includes.
- CI/CD regenerates docs and fails when generated output drifts from the
  committed state.
- Relationship model:
  - Source docs (`lib/` + `.adoc`) are authoritative.
  - Generated output (`docs/`) is a build artifact to review and publish.

## Workflow Checklist

- **Discussion**: run ideas by the team; record minutes
  (`00001-…-topic.adoc`).
- **Development**:
  - Add examples and tests with every feature; comment them.
  - Write one logical change per commit.
  - Reference checklist items in commit messages.
- **Reviews**: all PRs need at least one approval; enforce linting and
  style.
- **Testing**:
  - Unit + regression tests.
  - Integration tests for critical paths.
  - Fuzz tests around parsing/compilation.
  - Automate via CI and track coverage.
- **Tracking**: file issues for bugs, enhancements, and discussions.
  Label accordingly.

## Delivery & Operations

- **CI/CD**: pipeline runs lint/test/build and can publish releases.
  Document publish and rollback steps.
- **Security**: treat input as untrusted, audit deps, perform threat
  modeling, rotate secrets.
- **Performance**: benchmark hot paths, profile before merging new
  features, and record expectations.
- **Observability**: use structured logs, emit metrics (compile/eval),
  and enable tracing during debugging.

## Metrics & Quality Gates

- **Coverage target**: keep line coverage at or above `90%`; block merges
  below threshold unless explicitly waived in review.
- **Documentation freshness**: every API-affecting PR must update source
  docs and produce zero doc drift after regeneration.
- **CI/CD reliability**: keep default-branch green rate at or above
  `95%` over a rolling 30-day window.
- **Performance guardrails**: require benchmark evidence for hot-path
  changes and block regressions above `5%` unless approved.

## Maintenance

- Update source docs when APIs change, then regenerate derived docs.
- Periodically review for stale information.

## Team Roles & Responsibilities

The core team includes developers and writers; additional roles may
participate:

- QA Engineer – owns automated test strategy, coverage gates, regression
  suites, and release-readiness signoff.
- DevOps Engineer – owns CI/CD pipelines, doc-generation jobs, release
  automation, and rollback procedures.
- Security Specialist – owns dependency audit policy, secure-by-default
  reviews, and threat-model updates.
- Product Owner/Manager – owns scope, prioritization, acceptance
  criteria, and release communication.
- Technical Support Specialist – owns issue triage feedback loops and
  converts repeated support cases into docs/tests/tasks.
- API Specialist – owns API consistency, compatibility policy, and public
  migration guidance.
- Data Analyst – owns quality dashboards (coverage, CI reliability,
  performance trends) and monthly reporting.
- **Role interaction model**:
  - Product defines acceptance criteria.
  - API/Engineering implement.
  - QA validates behavior and coverage.
  - DevOps enforces pipeline and release gates.
  - Security approves risk-sensitive changes.
  - Support/Data feed production learnings back into backlog and docs.

> Keep this file concise and machine‑readable.  Claude should be able to
> read and act on any section without additional context.
