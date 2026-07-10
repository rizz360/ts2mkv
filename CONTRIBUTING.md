# Contributing to ts2mkv

Thanks for contributing.

## Development Setup

1. Fork and clone the repository.
2. Ensure Docker is installed and working.
3. Optional but recommended local tools:
   - `ripgrep` (`rg`)
   - `shellcheck`

## Local Validation

Run these checks before opening a pull request:

```bash
bash tests/test_safety.sh
bash tests/test_modular.sh
bash tests/test_smoke.sh
# Optional local lint
find app tests -type f -name '*.sh' -print0 | xargs -0 shellcheck -S error -e SC1091
```

Note: `tests/test_smoke.sh` requires Bash 4+ (CI uses Ubuntu Bash). The default macOS Bash 3.2 will skip this test.

## CI Expectations

CI runs:
- Shell linting via ShellCheck
- Safety checks
- Modular checks
- Smoke checks
- Docker build verification

If CI fails, please fix the root cause in your branch before requesting review.

## Commit Message Style

This repository uses release automation, so commit messages should follow Conventional Commits:

- `feat:` for new functionality
- `fix:` for bug fixes
- `docs:` for documentation-only changes
- `refactor:` for internal code changes without behavior changes
- `test:` for tests only
- `ci:` for CI/workflow changes
- `chore:` for maintenance tasks

Breaking changes:

- Use `!` after the type/scope, for example `feat!: drop legacy monitor mode`
- Or include a `BREAKING CHANGE:` footer in the commit body

## Release Process

Releases are automated with Release Please:

1. Push commit(s) to `main`.
2. The Release Please workflow updates or creates a release PR with changelog and version bump.
3. Merge that release PR to create the `ts-to-mkv-vX.Y.Z` tag and GitHub release (the component prefix comes from `release-please-config.json`; the workflows also accept legacy `v*` and `ts2mkv-v*` tags).
4. The tag triggers the publish workflow, which builds and pushes the GHCR image.

Avoid creating manual release tags unless there is an explicit emergency process.
