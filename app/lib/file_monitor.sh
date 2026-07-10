#!/bin/bash
# File monitoring and discovery

process_existing_files() {
    local queue_file="$LOG_DIR/queue.log"
    >"$queue_file"

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

wait_for_new_files() {
    log_info "Starting file system monitoring for new .ts files in $INPUT_DIR"
    log_info "Waiting for new files to be added..."
    
    while true; do
        # Use inotifywait to monitor for new files
        # Monitor for: moved_to (mv command), close_write (copy completion), create (new files)
        local new_file
        new_file=$(inotifywait -r -e moved_to,close_write,create --format '%w%f' "$INPUT_DIR" 2>/dev/null | awk '/\.ts$/ { print; exit }')
        
        if [[ -n "$new_file" && -f "$new_file" ]]; then
            log_info "Detected new file: $new_file"
            
            # Wait a moment to ensure file is completely written
            sleep 5
            
            # Verify file still exists and process it
            if [[ -f "$new_file" ]]; then
                log_info "Processing newly detected file: $new_file"
                # Keep monitoring even if this file fails: under `set -e` a bare
                # nonzero return from process_file would terminate the container.
                process_file "$new_file" || log_warn "Processing failed for $new_file"

                local stats
                stats=$(log_stats)
                local done_count="${stats%:*}"
                local error_count="${stats#*:}"
                
                log_info "File processing complete. Total processed: $done_count successful, $error_count failed"
            else
                log_warn "File disappeared before processing: $new_file"
            fi
        fi
        
        # Brief sleep to prevent excessive CPU usage in case inotifywait exits unexpectedly
        sleep 1
    done
}

poll_for_new_files() {
    log_info "Starting periodic polling for new .ts files in $INPUT_DIR (every ${POLL_INTERVAL} seconds)"
    
    # Keep track of previously processed files
    local processed_files_cache="$LOG_DIR/processed_cache.log"
    touch "$processed_files_cache"
    
    while true; do
        local queue_file="$LOG_DIR/poll_queue.log"
        >"$queue_file"
        
        # Find all .ts files
        find "$INPUT_DIR" -type f -name '*.ts' > "$queue_file"
        
        # Process only new files (not in our cache)
        local new_files=0
        while IFS= read -r file; do
            if [[ -n "$file" ]] && ! grep -Fxq "$file" "$processed_files_cache"; then
                log_info "Found new file to process: $file"
                if process_file "$file"; then
                    echo "$file" >> "$processed_files_cache"
                    new_files=$((new_files + 1))
                else
                    log_warn "Processing failed for $file; leaving it out of processed cache so it can be retried"
                fi
            fi
        done < "$queue_file"
        
        if (( new_files > 0 )); then
            local stats
            stats=$(log_stats)
            local done_count="${stats%:*}"
            local error_count="${stats#*:}"
            
            log_info "Processed $new_files new files. Total processed: $done_count successful, $error_count failed"
        else
            log_info "No new files found during this scan"
        fi
        
        log_info "Waiting ${POLL_INTERVAL} seconds before next scan..."
        sleep "$POLL_INTERVAL"
    done
}
