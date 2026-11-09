#!/bin/bash
# File monitoring and discovery

# Recordings the watch/poll loop has dealt with, keyed "<mtime>:<path>" so a
# new recording that reuses a deleted file's name is not mistaken for the old
# one. Deferred (still recording) files are never added, so every scan
# retries them until they settle.
declare -gA _HANDLED_FILES=()
declare -gA _DEFERRAL_LOGGED=()
_SCAN_PROCESSED=0

# done.log / error.log line counts before the startup scan; the monitor loop
# treats entries written after these marks as already handled.
_STARTUP_DONE_MARK=0
_STARTUP_ERROR_MARK=0

_line_count() {
    if [[ -f "$1" ]]; then
        wc -l < "$1"
    else
        echo 0
    fi
}

process_existing_files() {
    local queue_file="$LOG_DIR/queue.log"
    >"$queue_file"

    _STARTUP_DONE_MARK=$(_line_count "$LOG_DIR/done.log")
    _STARTUP_ERROR_MARK=$(_line_count "$LOG_DIR/error.log")

    log_info "Scanning $INPUT_DIR for existing .ts files..."
    find "$INPUT_DIR" -type f -name '*.ts' > "$queue_file"
    local total_files
    total_files=$(wc -l < "$queue_file")
    log_info "Found $total_files existing files to process."

    if (( total_files == 0 )); then
        log_info "No existing .ts files found to process."
        return 0
    fi

    print_config_summary

    # Process files based on parallel processing setting
    if [[ "$ENABLE_PARALLEL_PROCESSING" == "true" ]] && (( MAX_CONCURRENT_JOBS > 1 )); then
        process_files_parallel "$queue_file"
    else
        log_info "Processing existing files sequentially..."
        process_files_sequential "$queue_file"
    fi

    > "$LOG_DIR/current.log"
    log_info "Existing file processing complete."
    
    local stats
    stats=$(log_stats)
    local done_count="${stats%:*}"
    local error_count="${stats#*:}"
    
    ntfy_send "Existing files processed: $done_count successful, $error_count failed out of $total_files total files"
}

_log_scan_stats() {
    local stats
    stats=$(log_stats)
    local done_count="${stats%:*}"
    local error_count="${stats#*:}"
    log_info "Processed $_SCAN_PROCESSED new files. Total processed: $done_count successful, $error_count failed"
}

# Mark what the startup scan already converted (and, unless failures are
# retried, what it failed on) so the monitor loop does not redo that work.
# Files it skipped because the output already exists are revisited once.
_seed_handled_from_startup_scan() {
    local retry_failed="$1"
    local -a files=()
    local file mtime

    if [[ -f "$LOG_DIR/done.log" ]]; then
        mapfile -t -O "${#files[@]}" files < <(tail -n "+$(( _STARTUP_DONE_MARK + 1 ))" "$LOG_DIR/done.log")
    fi
    if [[ "$retry_failed" != "true" ]] && [[ -f "$LOG_DIR/error.log" ]]; then
        mapfile -t -O "${#files[@]}" files < <(tail -n "+$(( _STARTUP_ERROR_MARK + 1 ))" "$LOG_DIR/error.log")
    fi

    for file in "${files[@]}"; do
        if [[ -n "$file" ]] && mtime="$(file_mtime "$file")"; then
            _HANDLED_FILES["$mtime:$file"]=1
        fi
    done
}

# Process every finished .ts in INPUT_DIR that has not been handled yet.
# $1 = "true": failed files are retried on later scans (poll mode);
# otherwise a failure is final until the container restarts (watch mode).
# Sets _SCAN_PROCESSED to the number of files handled successfully.
scan_input_for_new_files() {
    local retry_failed="$1"
    local queue_file="$LOG_DIR/poll_queue.log"
    local -a files=()
    local -A still_present=()
    local file mtime key rc

    _SCAN_PROCESSED=0
    find "$INPUT_DIR" -type f -name '*.ts' > "$queue_file"
    mapfile -t files < "$queue_file"

    for file in "${files[@]}"; do
        [[ -n "$file" ]] || continue
        # Vanished since the find (e.g. deleted by an earlier job): skip.
        mtime="$(file_mtime "$file")" || continue
        key="$mtime:$file"
        still_present["$key"]=1
        [[ -z "${_HANDLED_FILES["$key"]+x}" ]] || continue

        if ! recording_is_settled "$file"; then
            # Checked here as well as in process_file so an hours-long
            # recording is logged once instead of on every rescan.
            if [[ -z "${_DEFERRAL_LOGGED["$file"]+x}" ]]; then
                log_info "Waiting for $file to stay unchanged for ${MIN_FILE_AGE_SEC}s before processing (still recording?)"
                _DEFERRAL_LOGGED["$file"]=1
            fi
            continue
        fi

        log_info "Found new file to process: $file"
        rc=0
        process_file "$file" || rc=$?
        if (( rc == 0 )); then
            _SCAN_PROCESSED=$((_SCAN_PROCESSED + 1))
        elif (( rc == PROCESS_DEFERRED )); then
            continue
        elif [[ "$retry_failed" == "true" ]]; then
            log_warn "Processing failed for $file; it will be retried on the next scan"
            continue
        else
            log_warn "Processing failed for $file; not retrying until the container restarts"
        fi
        # Re-stat: a successful job may have deleted the source (DELETE_TS).
        if mtime="$(file_mtime "$file")"; then
            _HANDLED_FILES["$mtime:$file"]=1
            still_present["$mtime:$file"]=1
        fi
    done

    # Forget files that are gone so the set doesn't grow forever.
    for key in "${!_HANDLED_FILES[@]}"; do
        if [[ -z "${still_present["$key"]+x}" ]]; then
            unset '_HANDLED_FILES[$key]'
        fi
    done
}

wait_for_new_files() {
    log_info "Watching $INPUT_DIR for finished .ts recordings (full rescan at least every ${WATCH_RESCAN_SEC}s)"
    _seed_handled_from_startup_scan false

    # One long-lived watcher (-m) instead of one inotifywait per event: events
    # that arrive during a long encode wait in the pipe instead of being lost.
    # Only close_write/moved_to: `create` fires when a recording *starts*.
    # Events just trigger a rescan; the periodic rescan is the safety net for
    # deferred recordings and for network mounts that drop inotify events.
    local events_fd rc
    local watcher_alive=true
    exec {events_fd}< <(inotifywait -m -r -q -e close_write,moved_to --format '%w%f' "$INPUT_DIR")

    while true; do
        scan_input_for_new_files false
        if (( _SCAN_PROCESSED > 0 )); then
            _log_scan_stats
        fi

        if [[ "$watcher_alive" != "true" ]]; then
            sleep "$WATCH_RESCAN_SEC"
            continue
        fi

        rc=0
        read -r -t "$WATCH_RESCAN_SEC" -u "$events_fd" _ || rc=$?
        if (( rc == 0 )); then
            # Collect the rest of a burst of events for up to 2s, then rescan
            # once. Time-bounded so a steady event stream can't stall the scan.
            local deadline=$((SECONDS + 2))
            while (( SECONDS < deadline )) && read -r -t 1 -u "$events_fd" _; do
                :
            done
        elif (( rc <= 128 )); then
            # EOF: inotifywait exited (e.g. the watch limit was hit). Keep
            # going on rescans alone instead of spinning on a dead pipe.
            log_warn "inotify watcher stopped; falling back to rescanning $INPUT_DIR every ${WATCH_RESCAN_SEC}s"
            exec {events_fd}<&-
            watcher_alive=false
        fi
        # rc > 128: timeout, fall through to the periodic rescan.
    done
}

poll_for_new_files() {
    log_info "Starting periodic polling for new .ts files in $INPUT_DIR (every ${POLL_INTERVAL} seconds)"
    _seed_handled_from_startup_scan true

    while true; do
        scan_input_for_new_files true
        if (( _SCAN_PROCESSED > 0 )); then
            _log_scan_stats
        else
            log_info "No new files found during this scan"
        fi

        log_info "Waiting ${POLL_INTERVAL} seconds before next scan..."
        sleep "$POLL_INTERVAL"
    done
}
