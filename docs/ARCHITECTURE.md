# Architecture

## Runtime Entry

- `/app/entrypoint.sh`

The entrypoint loads module files from `/app/lib` and coordinates startup, config loading, dependency checks, processing, and monitoring mode loops.

## Modules

- `system.sh`: strict mode, signal handling, dependency checks
- `logging.sh`: logging and notifications
- `config.sh`: config loading/defaults/validation
- `video_analysis.sh`: ffprobe metadata extraction and decision support
- `encoding.sh`: remux/encode execution and codec fallback
- `file_processor.sh`: per-file processing flow and parallel worker management
- `file_monitor.sh`: existing/new file discovery in watch/poll/once modes

## Web Dashboard

- `app/web/server.py`: threaded HTTP server started as a background process by the entrypoint after config load; listens on `WEB_PORT` (default 8080)

The dashboard is read-only: it renders state exclusively from files in `LOG_DIR` and never talks to the shell processor directly. The contract between the two:

- `queue.log` / `poll_queue.log`: newline-delimited absolute input paths (startup scan / poll scan)
- `done.log` / `error.log`: newline-delimited absolute input paths, appended per result
- `current_meta.<pid>.json`: one JSON object per active job (`file`, `started`, `duration_sec`), written by `process_file` keyed by `BASHPID` so parallel jobs do not collide
- `ffmpeg_progress.<pid>.log`: ffmpeg `-progress` key/value output for the matching job

`GET /` serves the HTML page, `GET /api/status` serves the JSON consumed by the page and by external pollers (Home Assistant, homepage widgets).

## Config and Paths

- Config: compose `environment` block in `docker-compose.yml` (default)
- Input: `/input`
- Output: `/output`
- Logs: `/app/logs`

`config.sh` supports optional file-based config via `TS_TO_MKV_CONFIG` (or `CONFIG_FILE`).

## Test Layers

- [tests/test_safety.sh](../tests/test_safety.sh): structural and safety guardrails
- [tests/test_modular.sh](../tests/test_modular.sh): module loading, function availability, syntax, safety invocation
- [tests/test_smoke.sh](../tests/test_smoke.sh): lightweight integration flow for processing and output naming
