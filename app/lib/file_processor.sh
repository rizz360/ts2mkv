#!/bin/bash
# File processing workflow

create_temp_job_dir() {
    local base_path="$1"
    local safe_base="${base_path//\//_}"

    if [[ -z "$safe_base" ]]; then
        safe_base="job"
    fi

    mkdir -p "$TEMP_DIR" || return 1
    mktemp -d -- "${TEMP_DIR%/}/${safe_base}.XXXXXX"
}

# A recording is a series episode when its path (lowercased) matches
# SERIES_PATTERN — an episode tag like S01E02 or a Season/Staffel directory.
is_series_path() {
    local relative_path_lower="${1,,}"
    [[ "$relative_path_lower" =~ $SERIES_PATTERN ]]
}

get_duration_seconds() {
    local media_file="$1"
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$media_file" \
        | awk '{printf "%.0f\n", $1}' || return 1
}

delete_source_if_output_verified() {
    local source_file="$1"
    local expected_output="$2"
    local reason="$3"

    if [[ ! -f "$expected_output" ]]; then
        log_warn "Not deleting source ($reason): expected output missing at $expected_output"
        return 1
    fi

    if [[ ! -s "$expected_output" ]]; then
        log_warn "Not deleting source ($reason): expected output is empty at $expected_output"
        return 1
    fi

    if [[ "$reason" == "skip-existing-output" ]] && [[ "$DELETE_SKIPPED_VERIFY_DURATION" == "true" ]]; then
        local source_duration output_duration delta delta_pct
        source_duration="$(get_duration_seconds "$source_file" 2>/dev/null || true)"
        output_duration="$(get_duration_seconds "$expected_output" 2>/dev/null || true)"

        if [[ -z "$source_duration" || -z "$output_duration" ]]; then
            log_warn "Not deleting source ($reason): unable to read durations for verification"
            return 1
        fi

        delta=$(( source_duration - output_duration ))
        if (( delta < 0 )); then
            delta=$(( -delta ))
        fi

        delta_pct="$(awk -v d="$delta" -v s="$source_duration" 'BEGIN { if (s <= 0) { print "9999" } else { printf "%.3f", (d * 100.0) / s } }')"

        # Permit deletion when either relative or absolute tolerance is satisfied.
        if ! awk -v d="$delta" -v sec="$DELETE_SKIPPED_DURATION_TOLERANCE_SEC" -v p="$delta_pct" -v pct="$DELETE_SKIPPED_DURATION_TOLERANCE_PCT" 'BEGIN { exit ! (d <= sec || p <= pct) }'; then
            log_warn "Not deleting source ($reason): duration mismatch source=${source_duration}s output=${output_duration}s delta=${delta}s (${delta_pct}%) exceeds tolerances=${DELETE_SKIPPED_DURATION_TOLERANCE_PCT}%/${DELETE_SKIPPED_DURATION_TOLERANCE_SEC}s"
            return 1
        fi
    fi

    if ! rm -f -- "$source_file"; then
        log_warn "Failed to delete source file ($reason): $source_file"
        return 1
    fi
    log_info "Deleted source file ($reason): $source_file"
    return 0
}

process_file() {
    local file="$1"

    if [ ! -e "$file" ]; then
        log_warn "File no longer exists, skipping: $file"
        return
    fi

    log_info "===================="

    local relative_path="${file#${INPUT_DIR}/}"
    local base_path="${relative_path%.ts}"

    declare -A video_info
    if ! get_video_info "$file" video_info; then
        log_error "Failed to analyze $file - skipping"
        echo "$file" >> "$LOG_DIR/error.log"
        return 1
    fi

    local suffix="TV.${video_info[res_label]}"
    local output_rel="${base_path}.${suffix}.mkv"
    if [[ "$FLATTEN_NON_SERIES" == "true" ]] && ! is_series_path "$relative_path"; then
        output_rel="$(basename "$base_path").${suffix}.mkv"
    fi
    local output_path="${OUTPUT_DIR}/${output_rel}"

    if [[ -f "$output_path" ]]; then
        log_info "Skipping, final file already exists: $file"

        if [[ "$DELETE_SKIPPED_TS" == "true" ]]; then
            delete_source_if_output_verified "$file" "$output_path" "skip-existing-output" || true
        fi

        return
    fi

    # Use a unique temporary directory for each job to avoid collisions.
    local temp_job_dir
    if ! temp_job_dir="$(create_temp_job_dir "$base_path")"; then
        log_error "Unable to create temporary job directory for $file"
        echo "$file" >> "$LOG_DIR/error.log"
        return 1
    fi
    local temp_output_path="${temp_job_dir}/$(basename "$output_path")"

    # Cleanup function for the temporary directory
    cleanup() {
        if [[ "$CLEANUP_TEMP_ON_FAILURE" != "true" ]] && [[ "${1:-}" == "failure" ]]; then
            log_warn "Temporary files for failed job kept at $temp_job_dir"
        else
            rm -rf "$temp_job_dir"
        fi
    }

    # Ensure temp and output directories exist
    mkdir -p "$(dirname "$output_path")"

    log_info "Processing ${file} (${video_info[size_gb]}GB, ${video_info[res_label]}, ${video_info[video_codec]}, ${video_info[video_bitrate]} bps)"
    log_info "Using temporary directory: $temp_job_dir"

    # Write per-job metadata for the web dashboard, keyed by PID to avoid
    # collisions when ENABLE_PARALLEL_PROCESSING=true.
    local progress_log="${LOG_DIR}/ffmpeg_progress.${BASHPID}.log"
    local meta_file="${LOG_DIR}/current_meta.${BASHPID}.json"
    > "$progress_log"
    if command -v jq &>/dev/null; then
        jq -nc \
            --arg file "$file" \
            --argjson started "$(date +%s)" \
            --argjson duration "${video_info[duration]:-0}" \
            '{file: $file, started: $started, duration_sec: $duration}' \
            > "$meta_file"
    fi

    local success=false

    if should_encode "$file" "${video_info[size_gb]}" "${video_info[res_label]}" "${video_info[video_codec]}" "${video_info[video_bitrate]}"; then
        if encode_file "$file" "$temp_output_path" "${video_info[duration]}" "${video_info[res_label]}" "$progress_log"; then
            success=true
        fi
    else
        if remux_file "$file" "$temp_output_path" "$progress_log"; then
            success=true
        fi
    fi

    if [[ "$success" == "true" ]]; then
        log_info "Processing successful, moving to final destination."
        mv "$temp_output_path" "$output_path"
        cleanup "success"

        log_info "Successfully created $output_path"
        echo "$file" >> "$LOG_DIR/done.log"

        local in_size_mb out_size_mb
        in_size_mb=$(du -m "$file" | cut -f1)
        out_size_mb=$(du -m "$output_path" | cut -f1)

        local ntfy_message
        if (( in_size_mb > 0 )); then
            local percent_saved=$(( 100 - (out_size_mb * 100 / in_size_mb) ))
            log_info "Size reduced from ${in_size_mb}MB to ${out_size_mb}MB (${percent_saved}% reduction)."
            ntfy_message="$(basename "$output_path") - Size reduced from ${in_size_mb}MB to ${out_size_mb}MB (${percent_saved}% reduction)"
        else
            ntfy_message="$(basename "$output_path") - Finished processing"
        fi

        ntfy_send "$ntfy_message"

        if [[ "$DELETE_TS" == "true" ]]; then
            delete_source_if_output_verified "$file" "$output_path" "post-success" || true
        fi
        rm -f "$progress_log" "$meta_file"
        return 0
    else
        log_error "Failed to process $file"
        echo "$file" >> "$LOG_DIR/error.log"
        cleanup "failure"
        rm -f "$progress_log" "$meta_file"
        return 1
    fi
}

process_files_sequential() {
    local -a file_list
    
    # Read newline-delimited queue entries safely (spaces/UTF-8 are supported; newlines are not).
    mapfile -t file_list < "$1"
    
    for file in "${file_list[@]}"; do
        if [ -z "$file" ]; then
            continue
        fi
        # Never let one failed file abort the whole run: under `set -e` a bare
        # nonzero return from process_file would terminate the container.
        process_file "$file" || true
    done
}

process_files_parallel() {
    local -a file_list
    local -a pids=()
    local job_count=0
    
    # Read newline-delimited queue entries safely (spaces/UTF-8 are supported; newlines are not).
    mapfile -t file_list < "$1"
    
    log_info "Processing files with up to $MAX_CONCURRENT_JOBS concurrent jobs"
    
    for file in "${file_list[@]}"; do
        if [ -z "$file" ]; then continue; fi
        
        # Wait for a slot if we're at max capacity
        while (( job_count >= MAX_CONCURRENT_JOBS )); do
            # Check if any jobs have completed
            local new_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                else
                    job_count=$((job_count - 1))
                fi
            done
            pids=("${new_pids[@]}")
            
            # Brief sleep to avoid busy waiting
            if (( job_count >= MAX_CONCURRENT_JOBS )); then
                sleep 1
            fi
        done
        
        # Start new job
        process_file "$file" &
        local new_pid=$!
        pids+=("$new_pid")
        job_count=$((job_count + 1))
        
    done
    
    # Wait for remaining jobs to complete
    log_info "Waiting for remaining $job_count jobs to complete..."
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done
}
