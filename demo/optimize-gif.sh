#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./demo/optimize-gif.sh <input.mp4> [output.gif] [--max-mb 10] [--keep-temp]

Searches a ladder of width/fps/quality settings and picks the highest-quality
GIF that stays within the size cap. If pngquant is available, it is used as a
secondary squeeze before the script drops to the next lower preset.
EOF
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

human_bytes() {
    awk -v bytes="$1" 'BEGIN {
        if (bytes >= 1073741824) { printf "%.2f GiB", bytes / 1073741824; exit }
        if (bytes >= 1048576) { printf "%.2f MiB", bytes / 1048576; exit }
        if (bytes >= 1024) { printf "%.1f KiB", bytes / 1024; exit }
        printf "%d B", bytes
    }'
}

build_candidates() {
    local duration="$1"
    if awk -v d="$duration" 'BEGIN { exit !(d <= 25) }'; then
        cat <<'EOF'
1280 18 95 95 100 0
1152 16 95 94 98 0
1024 14 94 92 96 0
960 14 92 90 94 0
900 12 90 88 92 1
840 12 88 86 90 1
780 10 86 84 88 1
720 10 84 82 86 1
640 8 82 78 84 1
560 8 78 74 80 1
480 6 74 70 76 1
EOF
    elif awk -v d="$duration" 'BEGIN { exit !(d <= 45) }'; then
        cat <<'EOF'
1080 14 95 92 96 0
960 12 93 90 94 0
900 12 91 88 92 0
840 10 90 86 90 1
780 10 88 84 88 1
720 10 86 82 86 1
640 8 84 78 84 1
560 8 80 74 80 1
480 6 76 70 76 1
EOF
    elif awk -v d="$duration" 'BEGIN { exit !(d <= 90) }'; then
        cat <<'EOF'
900 10 92 88 92 0
840 10 90 86 90 0
780 10 88 84 88 1
720 8 86 82 86 1
680 8 84 80 84 1
640 8 82 78 82 1
600 7 80 76 80 1
560 6 78 74 78 1
520 6 76 72 76 1
480 5 74 70 74 1
EOF
    else
        cat <<'EOF'
780 8 88 84 88 0
720 8 86 82 86 1
640 6 84 78 84 1
560 6 80 74 80 1
480 5 76 70 76 1
400 4 70 65 70 1
EOF
    fi
}

extract_frames() {
    local input="$1"
    local frame_dir="$2"
    local width="$3"
    local fps="$4"

    mkdir -p "$frame_dir"
    ffmpeg -v error -y -i "$input" \
        -vf "fps=${fps},scale=${width}:-1:flags=lanczos" \
        "$frame_dir/frame-%05d.png" \
        < /dev/null
}

encode_gif() {
    local frame_dir="$1"
    local output="$2"
    local width="$3"
    local fps="$4"
    local quality="$5"
    local motion_quality="$6"
    local lossy_quality="$7"
    local -a frames

    shopt -s nullglob
    frames=( "$frame_dir"/frame-*.png )
    shopt -u nullglob

    if [[ ${#frames[@]} -eq 0 ]]; then
        printf 'No frames extracted into %s\n' "$frame_dir" >&2
        return 1
    fi

    gifski \
        --quiet \
        --repeat 0 \
        --fps "$fps" \
        --width "$width" \
        --quality "$quality" \
        --motion-quality "$motion_quality" \
        --lossy-quality "$lossy_quality" \
        --output "$output" \
        "${frames[@]}" \
        < /dev/null
}

input=""
output=""
max_bytes=$((10 * 1024 * 1024))
keep_temp=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-mb)
            [[ $# -ge 2 ]] || { usage >&2; exit 1; }
            max_bytes=$(( $2 * 1024 * 1024 ))
            shift 2
            ;;
        --keep-temp)
            keep_temp=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$input" ]]; then
                input="$1"
            elif [[ -z "$output" ]]; then
                output="$1"
            else
                printf 'Unexpected argument: %s\n' "$1" >&2
                usage >&2
                exit 1
            fi
            shift
            ;;
    esac
done

[[ -n "$input" ]] || { usage >&2; exit 1; }
[[ -f "$input" ]] || { printf 'Input file not found: %s\n' "$input" >&2; exit 1; }

if [[ -z "$output" ]]; then
    output="${input%.*}.gif"
fi

need_cmd jq
need_cmd ffmpeg
need_cmd ffprobe
need_cmd gifski

pngquant_available=false
if command -v pngquant >/dev/null 2>&1; then
    pngquant_available=true
fi

probe_json=$(ffprobe -v error \
    -show_entries stream=width,height,r_frame_rate,codec_type \
    -show_entries format=duration \
    -of json "$input")

# Select the first video stream (not audio/subtitle) for dimensions
src_width=$(printf '%s' "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].width')
src_height=$(printf '%s' "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].height')
src_fps_expr=$(printf '%s' "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].r_frame_rate')
duration=$(printf '%s' "$probe_json" | jq -r '.format.duration | tonumber')

[[ "$src_width" != "null" && "$src_height" != "null" ]] || {
    printf 'Could not probe video dimensions for %s\n' "$input" >&2
    exit 1
}

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/warden-gif-XXXXXX")
cleanup() {
    if [[ "$keep_temp" == false ]]; then
        rm -rf "$tmp_root"
    else
        printf '[gif-opt] kept temp dir: %s\n' "$tmp_root"
    fi
}
trap cleanup EXIT

printf '[gif-opt] input: %s (%sx%s, duration %.2fs, source fps %s)\n' \
    "$input" "$src_width" "$src_height" "$duration" "$src_fps_expr"
printf '[gif-opt] target: %s (cap %s)\n' "$output" "$(human_bytes "$max_bytes")"
if [[ "$pngquant_available" == true ]]; then
    printf '[gif-opt] pngquant: enabled for secondary compression passes\n'
else
    printf '[gif-opt] pngquant: not found, using gifski-only ladder\n'
fi

best_candidate_path=""
best_candidate_size=0
attempt=0

while read -r width fps quality motion_quality lossy_quality quantize_hint; do
    [[ -n "${width:-}" ]] || continue
    attempt=$(( attempt + 1 ))
    capped_width="$width"
    if (( capped_width > src_width )); then
        capped_width=$src_width
    fi

    frame_dir="$tmp_root/frames-$attempt"
    candidate_path="$tmp_root/candidate-$attempt.gif"

    printf '[gif-opt] attempt %d: width=%s fps=%s quality=%s motion=%s lossy=%s\n' \
        "$attempt" "$capped_width" "$fps" "$quality" "$motion_quality" "$lossy_quality"

    extract_frames "$input" "$frame_dir" "$capped_width" "$fps"
    encode_gif "$frame_dir" "$candidate_path" "$capped_width" "$fps" "$quality" "$motion_quality" "$lossy_quality"

    candidate_size=$(wc -c < "$candidate_path" | tr -d '[:space:]')
    printf '[gif-opt] raw size: %s\n' "$(human_bytes "$candidate_size")"

    if (( best_candidate_size == 0 || candidate_size < best_candidate_size )); then
        best_candidate_size=$candidate_size
        best_candidate_path="$candidate_path"
    fi

    if (( candidate_size <= max_bytes )); then
        mv "$candidate_path" "$output"
        printf '[gif-opt] selected raw candidate (%s)\n' "$(human_bytes "$candidate_size")"
        exit 0
    fi

    if [[ "$pngquant_available" == true && "$quantize_hint" == "1" ]]; then
        printf '[gif-opt] pngquant squeeze on attempt %d\n' "$attempt"
        pngquant --force --ext .png --skip-if-larger --strip --speed 1 --quality=75-95 \
            "$frame_dir"/frame-*.png >/dev/null 2>&1 < /dev/null || true

        quant_path="$tmp_root/candidate-$attempt-quant.gif"
        encode_gif "$frame_dir" "$quant_path" "$capped_width" "$fps" "$quality" "$motion_quality" "$lossy_quality"
        quant_size=$(wc -c < "$quant_path" | tr -d '[:space:]')
        printf '[gif-opt] pngquant size: %s\n' "$(human_bytes "$quant_size")"

        if (( quant_size < best_candidate_size )); then
            best_candidate_size=$quant_size
            best_candidate_path="$quant_path"
        fi

        if (( quant_size <= max_bytes )); then
            mv "$quant_path" "$output"
            printf '[gif-opt] selected pngquant candidate (%s)\n' "$(human_bytes "$quant_size")"
            exit 0
        fi
    fi
done 3< <(build_candidates "$duration") <&3

if [[ -n "$best_candidate_path" ]]; then
    printf '[gif-opt] no candidate fit under %s; smallest attempt was %s\n' \
        "$(human_bytes "$max_bytes")" "$(human_bytes "$best_candidate_size")" >&2
fi
exit 1
