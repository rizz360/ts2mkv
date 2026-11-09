# Docker Runtime Guide

This project uses a single modular runtime entrypoint.
Primary runtime flow is pulling the published GHCR image.

## Compose Requirements

Use the following mount pattern in [docker-compose.yml](../docker-compose.yml):

```yaml
image: ghcr.io/rizz360/ts2mkv:latest
pull_policy: always
volumes:
  - /your/input/path:/input
  - /your/output/path:/output
```

Use the compose `environment` block as the primary runtime config source.
All supported variables with defaults are listed directly in `docker-compose.yml`.

## Permissions

The container runs as **root**: files written to `/output` are owned by `root:root`, and source deletion (`DELETE_TS`) runs with root privileges. `PUID`/`PGID` (LinuxServer.io convention) are **not** supported. If you need different ownership, adjust it on the host (e.g. a periodic `chown`, or NAS share permissions).

## Start

```bash
docker compose down
docker compose pull
docker compose up -d
```

## Local Development Fallback

If you are changing scripts locally and want live-mounted code, temporarily switch to local build mode:

```yaml
build: .
volumes:
  - ./app:/app
  - ./tests:/tests:ro
```

If you prefer explicit file sourcing inside the container, set `TS_TO_MKV_CONFIG` to a mounted file path.

## Verify

```bash
docker compose logs -f ts2mkv
```

Expected startup message pattern:
- `[YYYY-MM-DD HH:MM:SS] [INFO] Running in [mode] mode`

The web dashboard also logs its listen address on startup:
- `[dashboard] Listening on http://0.0.0.0:8080`

Optional ntfy-only startup notification (only when `NTFY_URL` is set):
- `ts2mkv processor starting in [mode] mode...`

## Filename Support

- Paths with spaces, quotes, and UTF-8 characters are supported.
- Paths containing literal newline characters are not supported.

## Validate

Run these checks from the repository root on the host (or in CI), not inside the runtime container. They validate repository files such as `docker-compose.yml`, `README.md`, and `docs/DOCKER.md`, which are not mounted by the compose setup shown above.

```bash
bash tests/test_safety.sh
bash tests/test_modular.sh
```

## Troubleshooting

### Entrypoint syntax

```bash
docker compose exec ts2mkv bash -n /app/entrypoint.sh
```

### Confirm active monitor mode

```bash
docker compose exec ts2mkv bash -c 'source /app/lib/config.sh && load_config && echo "$MONITOR_MODE"'
```

Watch mode rescans the input every `WATCH_RESCAN_SEC` (default 60 s) in addition to reacting to inotify events, so files are still found if your storage backend (e.g. an NFS/SMB mount) drops events. `MONITOR_MODE=poll` remains available if you prefer pure polling.

Recordings are only processed after they have gone `MIN_FILE_AGE_SEC` (default 300 s) without being modified; the log shows `Waiting for … (still recording?)` until then. If files appear to never get processed, check that the clocks of the recording host and the ts2mkv host are in sync — a modification time in the future keeps a file deferred.
