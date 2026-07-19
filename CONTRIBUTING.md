# Contributing

## Commit subjects

Every commit subject must have this exact form:

```text
feat|doc|fix|chore: lowercase-kebab-case
```

Examples:

```text
feat: add-testing-distribution
fix: preserve-package-history
doc: explain-key-rotation
chore: pin-pages-actions
```

## Branch names

Work on a typed branch using the same four types:

```text
feat|doc|fix|chore/lowercase-kebab-case
```

Examples include `feat/apt-repository` and `fix/release-indexes`. Keep changes
focused, run `shellcheck scripts/*.sh`, and validate a local repository before
merging to `main`.
