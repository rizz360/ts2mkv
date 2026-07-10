# Notes for AI / Future Maintainers

## Handling filenames safely in shell scripts

To avoid issues with special characters (e.g., German umlauts, spaces, quotes), always:

1. Use `mapfile -t array < filelist.txt` instead of `while read`.
2. Quote all variables: `"$var"`, not `$var`.
3. Use `-print0` with `find` and `xargs -0` to handle null-delimited filenames.
4. Prefer arrays over line-based iteration when possible.

This avoids bugs where valid filenames become corrupted or unfindable.

## Strict mode (`set -euo pipefail`) pitfalls

`system.sh` enables strict mode for the whole processor. Rules that keep one bad file from killing the container:

1. **Never call a function that can legitimately fail as a bare statement.** `process_file`, `get_video_info`, etc. must be called inside a condition (`if ! fn; then …`) or with an explicit `|| true` / `|| log_warn …`. A bare nonzero return terminates the shell — and the container. Note that parallel (`&`) and condition contexts disable `errexit` inside the callee, which is why such bugs can appear only in some monitor modes.
2. **`jq` expressions must never exit nonzero under `pipefail`.** Use null-safe forms: `.streams[]?`, `// "default"` fallbacks, and `tonumber? // 0` instead of `tonumber`. A jq error inside `var=$(… | jq …)` fails the assignment and, in a bare context, kills the script.
3. **Handle ffprobe failure explicitly** (`if ! json=$(ffprobe …); then return 1; fi`). Corrupt or still-recording `.ts` files make ffprobe fail; that must mean "log to error.log and skip", never "crash".
4. **Guard arithmetic against empty variables.** `(( empty_var < x ))` is an arithmetic error; inside an `if` it silently evaluates false, which can invert the intended safety check. Test for emptiness first.

## ffmpeg invocations

- Always pass `-nostdin`. In poll mode, `process_file` runs inside a `while read … done < queue_file` loop; without `-nostdin`, ffmpeg inherits the queue file as stdin and consumes queued entries.
- Live progress is emitted with `-progress "$progress_log" -stats_period 2`; the dashboard depends on it (see below).

## Web dashboard contract

`app/web/server.py` is read-only over `LOG_DIR` files; the shell side must preserve these formats (see docs/ARCHITECTURE.md for the full list):

- `current_meta.<pid>.json` + `ffmpeg_progress.<pid>.log` are written per job, keyed by `BASHPID`, and removed when the job ends.
- `queue.log`, `poll_queue.log`, `done.log`, `error.log` are newline-delimited absolute input paths. The dashboard computes "remaining queue" as queue minus done/error/active, so entries must match exactly (no rewriting/normalizing of paths).

## Releases and tags

- Conventional Commits drive Release Please; release tags are `ts-to-mkv-vX.Y.Z` (component from `release-please-config.json`). Don't create manual tags.
- The GitHub repo is `rizz360/ts2mkv` (renamed from `ts-to-mkv`; the release-please component keeps the legacy name on purpose).

## Validation before a PR

```bash
bash tests/test_safety.sh    # needs ripgrep (rg)
bash tests/test_modular.sh
bash tests/test_smoke.sh     # needs Bash 4+
find app tests -type f -name '*.sh' -print0 | xargs -0 shellcheck -S error -e SC1091
```
