# ts2mkv 🧼📺

[![CI](https://github.com/rizz360/ts2mkv/actions/workflows/ci.yml/badge.svg)](https://github.com/rizz360/ts2mkv/actions/workflows/ci.yml)
[![Release](https://github.com/rizz360/ts2mkv/actions/workflows/release.yml/badge.svg)](https://github.com/rizz360/ts2mkv/actions/workflows/release.yml)
[![License: EUPL](https://img.shields.io/badge/License-EUPL-blue.svg)](LICENSE)
[![Container](https://img.shields.io/badge/Container-ghcr.io-blue?logo=docker)](https://github.com/rizz360/ts2mkv/pkgs/container/ts2mkv)

A Docker-based tool that converts `.ts` recordings to `.mkv`, preserves folder structure, and applies smart remux/encode decisions with hardware fallback.

## Requirements

- **Docker** (and Docker Compose)

## Features

- Continuous file monitoring (`watch`, `poll`, `once`)
- Resolution-aware encode parameters
- QSV-first encoding with fallback codec support
- SD force-encode and HEVC skip logic
- Remux fallback without subtitles when needed
- Parallel processing support
- Ntfy notifications
- Safety and regression checks via dedicated test scripts

## Docker Setup

1. Configure [docker-compose.yml](docker-compose.yml):
   - image pull from GHCR (default)
   - input and output host mounts
   - environment defaults grouped by category
2. Adjust environment values directly in [docker-compose.yml](docker-compose.yml)
3. Start:

```bash
docker compose pull
docker compose up -d
```

## Configuration

Primary runtime config source: [docker-compose.yml](docker-compose.yml) under `environment`.

Optional: mount and set `TS_TO_MKV_CONFIG` (or `CONFIG_FILE`) if you still want file-based config.

Important knobs:
- `MONITOR_MODE` (`watch`, `poll`, `once`)
- `DELETE_TS`, `DELETE_SKIPPED_TS`, `DELETE_SKIPPED_VERIFY_DURATION`, `DELETE_SKIPPED_DURATION_TOLERANCE_PCT`, `DELETE_SKIPPED_DURATION_TOLERANCE_SEC`
- `VIDEO_CODEC` / `FALLBACK_CODEC`
- `USE_CRF`, `CRF_*`, `BITRATE_*`
- `ENABLE_PARALLEL_PROCESSING`, `MAX_CONCURRENT_JOBS`
- `FORCE_ENCODE_SD`, `SKIP_ALREADY_HEVC`

Filename support note:
- Paths with spaces, quotes, and UTF-8 characters are supported.
- Paths containing literal newline characters are not supported.

## Contributing

Contributor setup, local validation commands, commit conventions, and release flow are documented in [CONTRIBUTING.md](CONTRIBUTING.md).

## Web Dashboard

A lightweight status dashboard is built into the container and starts automatically alongside the processor. Open `http://<host>:8080` in a browser to see:

- **Now processing** — current file, elapsed time, live progress bar, speed, and ETA
- **Queue** — remaining files to process
- **Completed** — last 30 finished files
- **Errors** — any failed files

The default compose setup publishes dashboard port `8080` on the host as `8080`. The container-side listen port can be changed with the `WEB_PORT` environment variable (remember to adjust the compose `ports` mapping accordingly).

### JSON API

The dashboard exposes a machine-readable endpoint at `http://<host>:8080/api/status` (on-demand, no auth; the dashboard JS polls it every 3 seconds). Useful for integrating with external tools:

**Homepage (gethomepage.dev) custom API widget:**

```yaml
- ts2mkv:
    icon: mdi-video-convert
    href: http://your-host:8080
    widget:
      type: customapi
      url: http://your-host:8080/api/status
      refreshInterval: 5000
      mappings:
        - field: done_count
          label: Done
        - field: queue_remaining_count
          label: Queued
        - field: error_count
          label: Errors
        - field: current_progress_pct
          label: Progress
          suffix: "%"
```

**Home Assistant REST sensors:**

```yaml
sensor:
  - platform: rest
    name: ts2mkv_done
    resource: http://your-host:8080/api/status
    value_template: "{{ value_json.done_count }}"
    scan_interval: 10
    unit_of_measurement: files

  - platform: rest
    name: ts2mkv_queued
    resource: http://your-host:8080/api/status
    value_template: "{{ value_json.queue_remaining_count }}"
    scan_interval: 10
    unit_of_measurement: files

  - platform: rest
    name: ts2mkv_current_file
    resource: http://your-host:8080/api/status
    value_template: >-
      {% if value_json.current %}
        {{ value_json.current.display_path }}
      {% else %}
        idle
      {% endif %}
    scan_interval: 10

  - platform: rest
    name: ts2mkv_progress
    resource: http://your-host:8080/api/status
    value_template: >-
      {{ value_json.current.progress_pct if value_json.current else 0 }}
    scan_interval: 10
    unit_of_measurement: "%"
```

## Logs

Runtime logs are written inside the container at `/app/logs` (configurable via `LOG_DIR`). Inspect them with `docker compose exec ts2mkv ls /app/logs` or via the web dashboard:
- `queue.log` — files found by the startup scan (`poll_queue.log` in poll mode)
- `done.log` — successfully processed files
- `error.log` — failed files
- `ffmpeg_encode_*.log` — full ffmpeg output per encode
- `ffmpeg_progress.<pid>.log` / `current_meta.<pid>.json` — live per-job progress data consumed by the dashboard

## Additional Docs

- [docs/DOCKER.md](docs/DOCKER.md)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/REFACTORING_SUMMARY.md](docs/REFACTORING_SUMMARY.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)

## Community

- [SECURITY.md](SECURITY.md)
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- [SUPPORT.md](SUPPORT.md)

## License

This project is licensed under the EUPL 1.2 — see [LICENSE](LICENSE) for details.
