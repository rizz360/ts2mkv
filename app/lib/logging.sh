#!/bin/bash
# Logging and notification utilities

# --- Logging Functions ---
log_info() {
    printf "[%s] [INFO] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"
}

log_warn() {
    printf "[%s] [WARN] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"
}

log_error() {
    printf "[%s] [ERROR] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1"
}

ntfy_send() {
    local message="$1"
    if [[ -n "${NTFY_URL:-}" ]]; then
        # Keep notifications best-effort and avoid blocking the processing loop.
        curl -s --connect-timeout 5 --max-time 10 -X POST -H "Title: ts2mkv" -H "Priority: default" \
            -d "$message" \
            "$NTFY_URL" > /dev/null || true
    fi
}

# Initialize logging directories
init_logging() {
    mkdir -p "$LOG_DIR"
    >"$LOG_DIR/current.log"
}

# Print "<done>:<failed>" counts. Callers capture this with $(...), so stdout
# must carry nothing else.
log_stats() {
    local done_count=0 error_count=0
    if [[ -f "$LOG_DIR/done.log" ]]; then
        done_count=$(wc -l < "$LOG_DIR/done.log")
    fi
    if [[ -f "$LOG_DIR/error.log" ]]; then
        error_count=$(wc -l < "$LOG_DIR/error.log")
    fi
    echo "$(( done_count )):$(( error_count ))"
}
