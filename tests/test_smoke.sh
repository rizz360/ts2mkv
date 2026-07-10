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

echo "Smoke test passed"
