#!/bin/bash
# Configuration management module

# Load and validate configuration
load_config() {
    local app_root
    app_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # Optional file-based config. Compose env/env_file is the primary runtime source.
    CONFIG_FILE="${TS_TO_MKV_CONFIG:-${CONFIG_FILE:-}}"

    if [ -n "$CONFIG_FILE" ]; then
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
        else
            printf "[%s] [ERROR] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "Configuration file $CONFIG_FILE not found. Exiting."
            exit 1
        fi
    fi

    # Set defaults for all configuration variables
    DELETE_TS="${DELETE_TS:-false}"
    DELETE_SKIPPED_TS="${DELETE_SKIPPED_TS:-false}"
    DELETE_SKIPPED_VERIFY_DURATION="${DELETE_SKIPPED_VERIFY_DURATION:-true}"
    DELETE_SKIPPED_DURATION_TOLERANCE_PCT="${DELETE_SKIPPED_DURATION_TOLERANCE_PCT:-2.5}"
    DELETE_SKIPPED_DURATION_TOLERANCE_SEC="${DELETE_SKIPPED_DURATION_TOLERANCE_SEC:-120}"
    REMUX_SIZE_GB="${REMUX_SIZE_GB:-3}"
    VIDEO_CODEC="${VIDEO_CODEC:-hevc_qsv}"
    FALLBACK_CODEC="${FALLBACK_CODEC:-libx265}"
    AUDIO_CODEC="${AUDIO_CODEC:-copy}"
    REMUX_FALLBACK_NO_SUBTITLES="${REMUX_FALLBACK_NO_SUBTITLES:-true}"

    # Processing mode settings
    MONITOR_MODE="${MONITOR_MODE:-watch}"
    POLL_INTERVAL="${POLL_INTERVAL:-300}"

    # Parallel processing settings
    ENABLE_PARALLEL_PROCESSING="${ENABLE_PARALLEL_PROCESSING:-false}"
    MAX_CONCURRENT_JOBS="${MAX_CONCURRENT_JOBS:-2}"

    # Processing logic settings
    FORCE_ENCODE_SD="${FORCE_ENCODE_SD:-true}"

    # Output layout settings
    # Series recordings keep their input folder structure; everything else
    # (movies) is written flat into the output root when this is true.
    FLATTEN_NON_SERIES="${FLATTEN_NON_SERIES:-true}"
    # ERE matched (case-insensitively, against the lowercased relative path)
    # to decide whether a recording belongs to a series.
    if [[ -z "${SERIES_PATTERN:-}" ]]; then
        SERIES_PATTERN='s[0-9]{1,2}e[0-9]{1,3}|season[ ._-]?[0-9]{1,2}|staffel[ ._-]?[0-9]{1,2}'
    fi

    # Resolution-specific bitrates
    BITRATE_1080="${BITRATE_1080:-4000k}"
    BITRATE_720="${BITRATE_720:-2500k}"
    BITRATE_576="${BITRATE_576:-1500k}"
    BITRATE_480="${BITRATE_480:-1200k}"
    BITRATE_DEFAULT="${BITRATE_DEFAULT:-2000k}"

    # CRF settings
    USE_CRF="${USE_CRF:-false}"
    CRF_1080="${CRF_1080:-23}"
    CRF_720="${CRF_720:-24}"
    CRF_576="${CRF_576:-26}"
    CRF_480="${CRF_480:-28}"
    CRF_DEFAULT="${CRF_DEFAULT:-24}"

    # Preset settings
    PRESET_HD="${PRESET_HD:-fast}"
    PRESET_SD="${PRESET_SD:-medium}"

    # Advanced settings
    SKIP_ALREADY_HEVC="${SKIP_ALREADY_HEVC:-true}"
    HEVC_BITRATE_THRESHOLD="${HEVC_BITRATE_THRESHOLD:-3000000}"

    # Temporary file management
    TEMP_DIR="${TEMP_DIR:-/tmp/ts-processing}"
    CLEANUP_TEMP_ON_FAILURE="${CLEANUP_TEMP_ON_FAILURE:-true}"

    # Directory settings
    LOG_DIR="${LOG_DIR:-$app_root/logs}"
    INPUT_DIR="/input"
    OUTPUT_DIR="/output"
}

validate_config() {
    # Validate monitor mode
    case "$MONITOR_MODE" in
        watch|poll|once)
            log_info "Running in $MONITOR_MODE mode"
            ;;
        *)
            log_error "Invalid MONITOR_MODE: $MONITOR_MODE. Must be 'watch', 'poll', or 'once'"
            exit 1
            ;;
    esac

    # Check dependencies based on monitor mode
    if [[ "$MONITOR_MODE" == "watch" ]] && ! command -v inotifywait &> /dev/null; then
        log_error "inotifywait not found. Please install inotify-tools package or use MONITOR_MODE=poll"
        exit 1
    fi
}

print_config_summary() {
    log_info "Configuration summary:"
    log_info "- Primary video codec: $VIDEO_CODEC"
    log_info "- Fallback video codec: $FALLBACK_CODEC"
    log_info "- Parallel processing: $ENABLE_PARALLEL_PROCESSING"
    if [[ "$ENABLE_PARALLEL_PROCESSING" == "true" ]]; then
        log_info "- Max concurrent jobs: $MAX_CONCURRENT_JOBS"
    fi
    log_info "- Force encode SD content: $FORCE_ENCODE_SD"
    log_info "- Flatten non-series output: $FLATTEN_NON_SERIES"
    log_info "- Use CRF mode: $USE_CRF"
    log_info "- Skip already HEVC: $SKIP_ALREADY_HEVC"
    log_info "- Delete processed sources: $DELETE_TS"
    log_info "- Delete skipped sources when expected output exists: $DELETE_SKIPPED_TS"
    log_info "- Verify skipped output duration before delete: $DELETE_SKIPPED_VERIFY_DURATION"
    log_info "- Skipped delete duration tolerance (%): $DELETE_SKIPPED_DURATION_TOLERANCE_PCT"
    log_info "- Skipped delete duration tolerance (sec): $DELETE_SKIPPED_DURATION_TOLERANCE_SEC"
}
