# Refactoring Summary

> **Historical note:** this document describes the original modularization refactor. Some details have since been superseded — see "Current state" below.

## What changed

The project was restructured to a conventional layout:

- runtime scripts in `app/`
- validation scripts in `tests/`
- documentation in `docs/`

## Why

- clearer separation of runtime code vs tests vs docs
- easier CI targeting and tooling integration
- improved maintainability before larger future changes

## Operational updates

- Entrypoint moved to `/app/entrypoint.sh`
- Tests moved to `tests/`
- Safety checks updated for new path conventions

## Current state (updates since the refactor)

- The `config/` directory and its `.env` file were removed; the compose `environment` block in `docker-compose.yml` is the primary config source (optional file-based config via `TS_TO_MKV_CONFIG`).
- The published GHCR image bundles `app/` and `tests/`; compose no longer bind-mounts `./app` by default (a local-build fallback is documented in [DOCKER.md](DOCKER.md)).
- A web dashboard (`app/web/server.py`) was added and is started by the entrypoint — see [ARCHITECTURE.md](ARCHITECTURE.md).

## Verification

Run:

```bash
bash tests/test_safety.sh
bash tests/test_modular.sh
bash tests/test_smoke.sh
```
