#!/bin/bash
# Video encoding and remuxing functions

# Bitstream filter that independently normalizes each stream's timestamps to
# start from zero.  Applied per-stream (-bsf:v / -bsf:a) so audio and video
# are rebased individually, removing any broadcast-clock offset that would
# otherwise cause A/V desync in the MKV output.
_BSF_NORMALIZE_TS="setts=pts=PTS-STARTPTS:dts=DTS-STARTPTS"

get_encoding_params() {
    local resolution="$1"
    local -n params_ref="$2"

    # Determine bitrate/CRF based on resolution (handles both p and i variants)
    local res_num="${resolution%[pi]}"
    
    if [[ "$USE_CRF" == "true" ]]; then
        case "$res_num" in
            1080) params_ref[quality]="-crf $CRF_1080" ;;
            720) params_ref[quality]="-crf $CRF_720" ;;
            576) params_ref[quality]="-crf $CRF_576" ;;
            480) params_ref[quality]="-crf $CRF_480" ;;
            *) params_ref[quality]="-crf $CRF_DEFAULT" ;;
        esac
        
        # Set maxrate as well for CRF
        case "$res_num" in
            1080) params_ref[quality]+=" -maxrate $BITRATE_1080 -bufsize $((${BITRATE_1080%k} * 2))k" ;;
            720) params_ref[quality]+=" -maxrate $BITRATE_720 -bufsize $((${BITRATE_720%k} * 2))k" ;;
            576) params_ref[quality]+=" -maxrate $BITRATE_576 -bufsize $((${BITRATE_576%k} * 2))k" ;;
            480) params_ref[quality]+=" -maxrate $BITRATE_480 -bufsize $((${BITRATE_480%k} * 2))k" ;;
            *) params_ref[quality]+=" -maxrate $BITRATE_DEFAULT -bufsize $((${BITRATE_DEFAULT%k} * 2))k" ;;
        esac
    else
        case "$res_num" in
            1080) params_ref[quality]="-b:v $BITRATE_1080" ;;
            720) params_ref[quality]="-b:v $BITRATE_720" ;;
            576) params_ref[quality]="-b:v $BITRATE_576" ;;
            480) params_ref[quality]="-b:v $BITRATE_480" ;;
            *) params_ref[quality]="-b:v $BITRATE_DEFAULT" ;;
        esac
    fi

    # Determine preset based on resolution
    if [[ "$res_num" -le 576 ]]; then
        params_ref[preset]="$PRESET_SD"
    else
        params_ref[preset]="$PRESET_HD"
    fi
}

remux_file() {
    local input_file="$1"
    local output_path="$2"
    local progress_log="${3:-${LOG_DIR}/ffmpeg_progress.log}"

    log_info "Attempting to remux $input_file"
    if ffmpeg -nostdin -hide_banner -loglevel error -progress "$progress_log" -stats_period 2 \
        -fflags +genpts -i "$input_file" -map 0 -c copy \
        -bsf:v "$_BSF_NORMALIZE_TS" \
        -bsf:a "$_BSF_NORMALIZE_TS" \
        "$output_path"; then
        return 0
    elif [[ "$REMUX_FALLBACK_NO_SUBTITLES" == "true" ]]; then
        log_warn "Remux failed. Retrying without subtitles..."
        rm -f "$output_path"
        if ffmpeg -y -nostdin -hide_banner -loglevel error -progress "$progress_log" -stats_period 2 \
            -fflags +genpts -i "$input_file" -map 0 -sn -c copy \
            -bsf:v "$_BSF_NORMALIZE_TS" \
            -bsf:a "$_BSF_NORMALIZE_TS" \
            "$output_path"; then
            return 0
        fi
    fi
    return 1
}

encode_file() {
    local input_file="$1"
    local output_path="$2"
    local duration_sec="$3"
    local resolution="$4"
    local progress_log="${5:-${LOG_DIR}/ffmpeg_progress.log}"

    declare -A encoding_params
    get_encoding_params "$resolution" encoding_params

    log_info "Encoding $input_file (${resolution}) with preset ${encoding_params[preset]}"
    local encode_log="$LOG_DIR/ffmpeg_encode_$(basename "$input_file").log"

    # Try primary codec first
    if try_encode_with_codec "$input_file" "$output_path" "$duration_sec" "$resolution" "$VIDEO_CODEC" "$encode_log" "$progress_log"; then
        return 0
    fi

    # If primary codec failed and it's a hardware codec, try fallback
    if [[ "$VIDEO_CODEC" =~ qsv|nvenc|vaapi ]] && [[ "$FALLBACK_CODEC" != "$VIDEO_CODEC" ]]; then
        log_warn "Hardware encoding failed for $input_file, trying fallback codec: $FALLBACK_CODEC"
        rm -f "$output_path" # Clean up failed attempt
        
        if try_encode_with_codec "$input_file" "$output_path" "$duration_sec" "$resolution" "$FALLBACK_CODEC" "$encode_log" "$progress_log"; then
            return 0
        fi
    fi

    log_error "All encoding attempts failed for $input_file. Check logs at $encode_log"
    return 1
}

try_encode_with_codec() {
    local input_file="$1"
    local output_path="$2"
    local duration_sec="$3"
    local resolution="$4"
    local codec="$5"
    local encode_log="$6"
    local progress_log="${7:-${LOG_DIR}/ffmpeg_progress.log}"

    declare -A encoding_params
    get_encoding_params "$resolution" encoding_params

    # Build ffmpeg command based on codec type
    # -nostdin: ffmpeg must never read stdin - in poll mode process_file runs
    # inside a `while read` loop and would otherwise swallow the queue file.
    local ffmpeg_cmd=(ffmpeg -nostdin -hide_banner -loglevel error)

    # Live progress output for the web dashboard
    ffmpeg_cmd+=(-progress "$progress_log" -stats_period 2)

    # Add hardware acceleration for QSV
    if [[ "$codec" == "hevc_qsv" ]]; then
        ffmpeg_cmd+=(-hwaccel qsv -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw)
    fi
    
    ffmpeg_cmd+=(-fflags +genpts -i "$input_file" -map 0 -sn -c:v "$codec" -preset "${encoding_params[preset]}")

    # Add quality parameters (either CRF or bitrate)
    read -ra quality_params <<< "${encoding_params[quality]}"
    ffmpeg_cmd+=("${quality_params[@]}")

    # Add audio codec and output
    ffmpeg_cmd+=(-c:a "$AUDIO_CODEC" \
        -bsf:v "$_BSF_NORMALIZE_TS" \
        -bsf:a "$_BSF_NORMALIZE_TS" \
        -y "$output_path")

    log_info "Attempting encoding with $codec: ${ffmpeg_cmd[*]}"
    
    if ! "${ffmpeg_cmd[@]}" > "$encode_log" 2>&1; then
        log_warn "Encoding with $codec failed for $input_file"
        return 1
    fi

    # Validate output duration
    if ! validate_output "$input_file" "$output_path" "$duration_sec" "$resolution"; then
        log_error "Output validation failed for $input_file with $codec"
        return 1
    fi

    log_info "Successfully encoded $input_file with $codec"
    return 0
}
