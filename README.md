# myproject

This project was bootstrapped with `cx init`.

## Documentation

The repository includes a minimal Antora documentation site under `docs/`
with these first-class surfaces:

- `onboarding`: entrypoint and team orientation
- `manual`: operator-focused workflows and commands
- `architecture`: arc42-based system documentation

Useful entrypoints:

- `antora-playbook.yml`
- `docs/README.md`
- `docs/modules/onboarding/pages/index.adoc`
- `docs/modules/manual/pages/index.adoc`
- `docs/modules/architecture/pages/index.adoc`

## Context Bundling

`cx.toml` is already configured to treat `docs/**`, `notes/**`, and
repository markdown as the docs section.

## Next Steps

1. Replace placeholder text in the Antora pages with project-specific content.
2. Adjust `site.url` in `antora-playbook.yml` before publishing the docs site.
3. Use `cx docs export` or `cx bundle --include-doc-exports` once the docs
   become part of your review workflow.
