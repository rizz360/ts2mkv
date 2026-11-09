#!/bin/bash
# Lightweight integration smoke test for modular file processing flow

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Skipping smoke test: requires Bash 4+ (current: $BASH_VERSION)"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

INPUT_DIR="$WORK_DIR/input"
OUTPUT_DIR="$WORK_DIR/output"
LOG_DIR="$WORK_DIR/logs"
TEMP_DIR="$WORK_DIR/tmp"

mkdir -p "$INPUT_DIR/sub" "$OUTPUT_DIR" "$LOG_DIR" "$TEMP_DIR"

# Provide required globals used by file_processor.sh
DELETE_TS=false
DELETE_SKIPPED_TS=false
DELETE_SKIPPED_VERIFY_DURATION=false
DELETE_SKIPPED_DURATION_TOLERANCE_PCT=2.5
DELETE_SKIPPED_DURATION_TOLERANCE_SEC=120
CLEANUP_TEMP_ON_FAILURE=true
FLATTEN_NON_SERIES=true
SERIES_PATTERN='s[0-9]{1,2}e[0-9]{1,3}|season[ ._-]?[0-9]{1,2}|staffel[ ._-]?[0-9]{1,2}'
# Fixture files are brand new; cases 9+ exercise the age guard explicitly.
MIN_FILE_AGE_SEC=0

log_info() { :; }
log_warn() { :; }
log_error() { :; }
ntfy_send() { :; }

get_video_info() {
    local _file="$1"
    local -n info_ref="$2"
    info_ref[size_gb]=1
    info_ref[res_label]=720p
    info_ref[video_codec]=h264
    info_ref[video_bitrate]=4000000
    info_ref[duration]=60
}

# Force remux path for deterministic behavior.
should_encode() {
    return 1
}

remux_file() {
    local input_file="$1"
    local output_path="$2"
    cp "$input_file" "$output_path"
}

encode_file() {
    local input_file="$1"
    local output_path="$2"
    cp "$input_file" "$output_path"
}

source "$ROOT_DIR/app/lib/file_processor.sh"

# Case 1: Keep source file and create expected output path.
# Non-series recordings are flattened to the output root by default.
printf "smoke-data-1" > "$INPUT_DIR/sub/sample.ts"
process_file "$INPUT_DIR/sub/sample.ts"

EXPECTED_OUTPUT_1="$OUTPUT_DIR/sample.TV.720p.mkv"
if [[ ! -f "$EXPECTED_OUTPUT_1" ]]; then
    echo "Smoke test failed: expected output missing: $EXPECTED_OUTPUT_1"
    exit 1
fi

if ! grep -Fxq "$INPUT_DIR/sub/sample.ts" "$LOG_DIR/done.log"; then
    echo "Smoke test failed: done.log missing processed file entry"
    exit 1
fi

if [[ ! -f "$INPUT_DIR/sub/sample.ts" ]]; then
    echo "Smoke test failed: source should be preserved when DELETE_TS=false"
    exit 1
fi

# Case 2: Delete source file when configured.
DELETE_TS=true
printf "smoke-data-2" > "$INPUT_DIR/sub/delete_me.ts"
process_file "$INPUT_DIR/sub/delete_me.ts"

EXPECTED_OUTPUT_2="$OUTPUT_DIR/delete_me.TV.720p.mkv"
if [[ ! -f "$EXPECTED_OUTPUT_2" ]]; then
    echo "Smoke test failed: expected delete-case output missing: $EXPECTED_OUTPUT_2"
    exit 1
fi

if [[ -f "$INPUT_DIR/sub/delete_me.ts" ]]; then
    echo "Smoke test failed: source should be deleted when DELETE_TS=true"
    exit 1
fi

# Case 3: Delete skipped source when expected output already exists and safeguard passes.
DELETE_TS=false
DELETE_SKIPPED_TS=true
printf "smoke-data-3" > "$INPUT_DIR/sub/skip_delete.ts"
printf "already-converted" > "$OUTPUT_DIR/skip_delete.TV.720p.mkv"
process_file "$INPUT_DIR/sub/skip_delete.ts"

if [[ -f "$INPUT_DIR/sub/skip_delete.ts" ]]; then
    echo "Smoke test failed: skipped source should be deleted when DELETE_SKIPPED_TS=true and expected output exists"
    exit 1
fi

# Case 4: Keep skipped source when expected output is empty (safeguard).
printf "smoke-data-4" > "$INPUT_DIR/sub/skip_keep.ts"
: > "$OUTPUT_DIR/skip_keep.TV.720p.mkv"
process_file "$INPUT_DIR/sub/skip_keep.ts"

if [[ ! -f "$INPUT_DIR/sub/skip_keep.ts" ]]; then
    echo "Smoke test failed: skipped source should be preserved when expected output is empty"
    exit 1
fi

# Case 5: Delete skipped source when duration verification passes (within tolerance).
DELETE_SKIPPED_TS=true
DELETE_SKIPPED_VERIFY_DURATION=true
printf "smoke-data-5" > "$INPUT_DIR/sub/skip_verify_ok.ts"
printf "already-converted" > "$OUTPUT_DIR/skip_verify_ok.TV.720p.mkv"
# Stub get_duration_seconds to return identical durations so delta is within tolerance.
get_duration_seconds() { echo "3600"; }
process_file "$INPUT_DIR/sub/skip_verify_ok.ts"

if [[ -f "$INPUT_DIR/sub/skip_verify_ok.ts" ]]; then
    echo "Smoke test failed: skipped source should be deleted when duration verification passes"
    exit 1
fi

# Case 6: Keep skipped source when duration mismatch exceeds tolerance.
printf "smoke-data-6" > "$INPUT_DIR/sub/skip_verify_fail.ts"
printf "already-converted" > "$OUTPUT_DIR/skip_verify_fail.TV.720p.mkv"
# Stub get_duration_seconds to return a large mismatch (3600s vs 100s).
get_duration_seconds() {
    local f="$1"
    if [[ "$f" == *.ts ]]; then echo "3600"; else echo "100"; fi
}
process_file "$INPUT_DIR/sub/skip_verify_fail.ts"

if [[ ! -f "$INPUT_DIR/sub/skip_verify_fail.ts" ]]; then
    echo "Smoke test failed: skipped source should be preserved when duration mismatch exceeds tolerance"
    exit 1
fi

# Reset duration verification flags before remaining tests.
DELETE_SKIPPED_VERIFY_DURATION=false
unset -f get_duration_seconds

# Case 7: Preserve deep show/season folder structure.
mkdir -p "$INPUT_DIR/shows/Example Show/SEASON 01"
printf "smoke-data-7" > "$INPUT_DIR/shows/Example Show/SEASON 01/Some Random Recording S01E02.ts"
process_file "$INPUT_DIR/shows/Example Show/SEASON 01/Some Random Recording S01E02.ts"

EXPECTED_OUTPUT_3="$OUTPUT_DIR/shows/Example Show/SEASON 01/Some Random Recording S01E02.TV.720p.mkv"
if [[ ! -f "$EXPECTED_OUTPUT_3" ]]; then
    echo "Smoke test failed: expected nested show output missing: $EXPECTED_OUTPUT_3"
    exit 1
fi

# Case 7b: A season-style directory alone marks a recording as series, even
# without an SxxExx tag in the filename.
mkdir -p "$INPUT_DIR/shows/Another Show/Staffel 2"
printf "smoke-data-7b" > "$INPUT_DIR/shows/Another Show/Staffel 2/Pilotfolge.ts"
process_file "$INPUT_DIR/shows/Another Show/Staffel 2/Pilotfolge.ts"

if [[ ! -f "$OUTPUT_DIR/shows/Another Show/Staffel 2/Pilotfolge.TV.720p.mkv" ]]; then
    echo "Smoke test failed: season-directory recording should keep its folder structure"
    exit 1
fi

# Case 7c: Movies recorded into their own folder are flattened to the output root.
mkdir -p "$INPUT_DIR/Some Movie (2023)"
printf "smoke-data-7c" > "$INPUT_DIR/Some Movie (2023)/Some Movie (2023).ts"
process_file "$INPUT_DIR/Some Movie (2023)/Some Movie (2023).ts"

if [[ ! -f "$OUTPUT_DIR/Some Movie (2023).TV.720p.mkv" ]]; then
    echo "Smoke test failed: movie output should be flattened to the output root"
    exit 1
fi

if [[ -e "$OUTPUT_DIR/Some Movie (2023)" ]]; then
    echo "Smoke test failed: movie folder should not be mirrored into the output"
    exit 1
fi

# Case 7d: FLATTEN_NON_SERIES=false restores full structure mirroring.
FLATTEN_NON_SERIES=false
mkdir -p "$INPUT_DIR/Other Movie"
printf "smoke-data-7d" > "$INPUT_DIR/Other Movie/Other Movie.ts"
process_file "$INPUT_DIR/Other Movie/Other Movie.ts"

if [[ ! -f "$OUTPUT_DIR/Other Movie/Other Movie.TV.720p.mkv" ]]; then
    echo "Smoke test failed: FLATTEN_NON_SERIES=false should preserve folder structure"
    exit 1
fi
FLATTEN_NON_SERIES=true

# Case 8: Temp job directory generation must be unique for same basename in different paths.
temp_a="$(create_temp_job_dir "shows/Series A/SEASON 01/Episode S01E01")"
temp_b="$(create_temp_job_dir "shows/Series B/SEASON 01/Episode S01E01")"

if [[ "$temp_a" == "$temp_b" ]]; then
    echo "Smoke test failed: temp directories should be unique per job"
    exit 1
fi

rm -rf "$temp_a" "$temp_b"

# Backdate a file's mtime by N seconds (GNU touch, BSD fallback).
set_age() {
    local epoch=$(( $(date +%s) - $2 ))
    touch -d "@$epoch" "$1" 2>/dev/null || touch -t "$(date -r "$epoch" +%Y%m%d%H%M.%S)" "$1"
}

# Case 9: A recording that was modified recently is deferred (exit 2): no
# output, no done/error entry, and the source is never deleted.
MIN_FILE_AGE_SEC=300
DELETE_TS=true
printf "still-recording" > "$INPUT_DIR/sub/recording.ts"
rc=0
process_file "$INPUT_DIR/sub/recording.ts" || rc=$?
if (( rc != PROCESS_DEFERRED )); then
    echo "Smoke test failed: recent file should be deferred (rc=$rc)"
    exit 1
fi
if [[ ! -f "$INPUT_DIR/sub/recording.ts" ]] || [[ -e "$OUTPUT_DIR/recording.TV.720p.mkv" ]] \
    || grep -Fxq "$INPUT_DIR/sub/recording.ts" "$LOG_DIR/done.log" "$LOG_DIR/error.log" 2>/dev/null; then
    echo "Smoke test failed: deferred file must be left untouched"
    exit 1
fi

# Once it has been unchanged long enough it is processed normally.
set_age "$INPUT_DIR/sub/recording.ts" 600
process_file "$INPUT_DIR/sub/recording.ts"
if [[ ! -f "$OUTPUT_DIR/recording.TV.720p.mkv" ]] || [[ -f "$INPUT_DIR/sub/recording.ts" ]]; then
    echo "Smoke test failed: settled recording should be converted and deleted"
    exit 1
fi
DELETE_TS=false

# Monitor loop scans (watch/poll share scan_input_for_new_files).
log_stats() { echo "0:0"; }
source "$ROOT_DIR/app/lib/file_monitor.sh"
INPUT_DIR="$WORK_DIR/input_monitor"
OUTPUT_DIR="$WORK_DIR/output_monitor"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
CALLS_LOG="$WORK_DIR/remux_calls.log"
: > "$CALLS_LOG"
remux_file() {
    echo "$1" >> "$CALLS_LOG"
    [[ "$1" != *broken.ts ]] || return 1
    cp "$1" "$2"
}
remux_calls() { grep -Fxc "$INPUT_DIR/$1" "$CALLS_LOG" || true; }

expect_scan() {
    local retry="$1" expected="$2" what="$3"
    scan_input_for_new_files "$retry"
    if (( _SCAN_PROCESSED != expected )); then
        echo "Smoke test failed: $what (processed $_SCAN_PROCESSED, expected $expected)"
        exit 1
    fi
}

# Case 10: In-progress recordings are skipped until they settle; finished
# ones are processed exactly once.
printf "finished" > "$INPUT_DIR/finished.ts"
set_age "$INPUT_DIR/finished.ts" 600
printf "recording" > "$INPUT_DIR/live.ts"
expect_scan false 1 "only the finished recording should be processed"
[[ ! -e "$OUTPUT_DIR/live.TV.720p.mkv" ]] || { echo "Smoke test failed: in-progress recording was processed"; exit 1; }
expect_scan false 0 "a rescan should not reprocess handled files"
set_age "$INPUT_DIR/live.ts" 600
expect_scan false 1 "a recording should be processed once it settles"
if [[ "$(remux_calls finished.ts)" != 1 ]] || [[ "$(remux_calls live.ts)" != 1 ]]; then
    echo "Smoke test failed: each recording should be converted exactly once"
    exit 1
fi

# Case 11: Watch mode does not retry failures; poll mode does.
printf "broken" > "$INPUT_DIR/broken.ts"
set_age "$INPUT_DIR/broken.ts" 600
expect_scan false 0 "a failed file is not a success"
expect_scan false 0 "watch mode rescan"
if [[ "$(remux_calls broken.ts)" != 1 ]]; then
    echo "Smoke test failed: watch mode must not retry a failed file on every rescan"
    exit 1
fi
_HANDLED_FILES=()
# The first poll scan also revisits finished/live (skipped: output exists).
expect_scan true 2 "poll scan 1"
expect_scan true 0 "poll scan 2"
# 1 earlier attempt + 1 per poll scan.
if [[ "$(remux_calls broken.ts)" != 3 ]]; then
    echo "Smoke test failed: poll mode should retry failed files on every scan"
    exit 1
fi
rm -f "$INPUT_DIR/broken.ts"

# Case 12: A new recording reusing a processed (and deleted) file's name is
# processed again instead of being mistaken for the old one.
DELETE_TS=true
printf "monday" > "$INPUT_DIR/daily.ts"
set_age "$INPUT_DIR/daily.ts" 900
expect_scan false 1 "first daily recording"
rm -f "$OUTPUT_DIR/daily.TV.720p.mkv"   # e.g. moved into the library
printf "tuesday" > "$INPUT_DIR/daily.ts"
set_age "$INPUT_DIR/daily.ts" 400
expect_scan false 1 "a re-recorded file with the same name should be processed"
if [[ "$(remux_calls daily.ts)" != 2 ]]; then
    echo "Smoke test failed: re-recorded file should be converted again"
    exit 1
fi
DELETE_TS=false

# Case 13: Startup-scan results seed the monitor loop, so it doesn't redo them.
_HANDLED_FILES=()
printf "seeded" > "$INPUT_DIR/seeded.ts"
set_age "$INPUT_DIR/seeded.ts" 600
_STARTUP_DONE_MARK=$(_line_count "$LOG_DIR/done.log")
echo "$INPUT_DIR/seeded.ts" >> "$LOG_DIR/done.log"
_seed_handled_from_startup_scan false
scan_input_for_new_files false
if [[ "$(remux_calls seeded.ts)" != 0 ]]; then
    echo "Smoke test failed: files converted by the startup scan should not be reprocessed"
    exit 1
fi

echo "Smoke test passed"
