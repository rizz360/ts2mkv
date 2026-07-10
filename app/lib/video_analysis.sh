#!/bin/bash
# Video analysis and metadata extraction

get_video_info() {
    local file_path="$1"
    local -n info_ref="$2"

    local json_data
    if ! json_data=$(ffprobe -v quiet -print_format json -show_format -show_streams "$file_path"); then
        log_error "ffprobe failed to analyze $file_path"
        return 1
    fi

    # jq expressions must never exit nonzero: under `set -euo pipefail` a jq
    # failure on malformed metadata would kill the whole processor.
    info_ref[height]=$(echo "$json_data" | jq -r '[.streams[]? | select(.codec_type=="video")][0].height // empty')
    info_ref[scan_type]=$(echo "$json_data" | jq -r '[.streams[]? | select(.codec_type=="video")][0].field_order // "progressive"')
    info_ref[duration]=$(echo "$json_data" | jq -r '(.format.duration // "0") | (tonumber? // 0) | floor')
    info_ref[size_gb]=$(du -BG "$file_path" | cut -f1 | sed 's/G//')

    if [[ -z "${info_ref[height]}" ]]; then
        log_error "No video stream found in $file_path"
        return 1
    fi

    if [[ "${info_ref[scan_type]}" =~ (tt|bb|tb|bt) ]]; then
        info_ref[res_label]="${info_ref[height]}i"
    else
        info_ref[res_label]="${info_ref[height]}p"
    fi

    # Get additional stream info for optimization decisions
    info_ref[video_bitrate]=$(echo "$json_data" | jq -r '[.streams[]? | select(.codec_type=="video")][0].bit_rate // "0"')
    info_ref[video_codec]=$(echo "$json_data" | jq -r '[.streams[]? | select(.codec_type=="video")][0].codec_name // "unknown"')
}

should_encode() {
    local file="$1"
    local size_gb="$2"
    local resolution="$3"
    local video_codec="$4"
    local video_bitrate="$5"

    local res_num="${resolution%[pi]}"

    # Skip if already efficiently encoded with HEVC
    if [[ "$SKIP_ALREADY_HEVC" == "true" ]] && [[ "$video_codec" == "hevc" ]] && [[ "$video_bitrate" != "0" ]] && (( video_bitrate < HEVC_BITRATE_THRESHOLD )); then
        log_info "Skipping $file - already efficiently encoded with HEVC (${video_bitrate} bps)"
        return 1
    fi

    # Always encode SD content for better compression if enabled
    if [[ "$FORCE_ENCODE_SD" == "true" ]] && (( res_num <= 576 )); then
        log_info "Will encode SD content ($resolution) for better compression"
        return 0
    fi
    
    # For HD content, use size threshold
    if (( size_gb > REMUX_SIZE_GB )); then
        log_info "Will encode large file (${size_gb}GB > ${REMUX_SIZE_GB}GB threshold)"
        return 0
    fi
    
    log_info "Will remux (${size_gb}GB <= ${REMUX_SIZE_GB}GB threshold)"
    return 1
}

validate_output() {
    local original="$1"
    local encoded="$2"
    local original_duration="$3"
    local resolution="$4"

    local encoded_duration
    encoded_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$encoded" 2>/dev/null | awk '{printf "%.0f\n", $1}' || true)

    if [[ -z "$encoded_duration" ]]; then
        log_warn "Unable to read duration of encoded output $encoded - treating as invalid"
        return 1
    fi

    # More lenient duration check for SD content (often has timing irregularities)
    local tolerance=80
    local res_num="${resolution%[pi]}"
    if (( res_num <= 576 )); then
        tolerance=70
    fi
    
    if (( encoded_duration < original_duration * tolerance / 100 )); then
        log_warn "Encoded duration ($encoded_duration) is much shorter than original ($original_duration)!"
        return 1
    fi
    
    # Ensure some compression occurred (but allow for edge cases)
    local encoded_size original_size
    encoded_size=$(stat -f%z "$encoded" 2>/dev/null || stat -c%s "$encoded")
    original_size=$(stat -f%z "$original" 2>/dev/null || stat -c%s "$original")
    
    if (( encoded_size >= original_size )); then
        log_warn "Encoded file is not smaller than original - this may be expected for some content"
    fi
    
    return 0
}
