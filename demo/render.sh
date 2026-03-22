#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$ROOT_DIR/demo"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

target="${1:-all}"

render_install() {
    need_cmd vhs
    need_cmd ffmpeg
    need_cmd tmux
    need_cmd figlet
    need_cmd jq
    need_cmd gifski
    printf '[demo] rendering install walkthrough\n'
    (cd "$ROOT_DIR" && vhs "$DEMO_DIR/install.tape")
    printf '[demo] optimizing install gif\n'
    (cd "$ROOT_DIR" && "$DEMO_DIR/optimize-gif.sh" "$DEMO_DIR/install.mp4" "$DEMO_DIR/install.gif")
}

render_main() {
    need_cmd vhs
    need_cmd ffmpeg
    need_cmd tmux
    need_cmd figlet
    need_cmd jq
    printf '[demo] rendering main demo\n'
    (cd "$ROOT_DIR" && WARDEN_DEMO_FAKE_CLAUDE=1 vhs "$DEMO_DIR/demo.tape")
}

optimize_existing() {
    need_cmd gifski
    local input="${2:-}"
    local output="${3:-}"

    if [[ -z "$input" ]]; then
        printf 'Usage: %s optimize <input.mp4> [output.gif]\n' "$0" >&2
        exit 1
    fi

    if [[ -z "$output" ]]; then
        output="${input%.*}.gif"
    fi

    (cd "$ROOT_DIR" && "$DEMO_DIR/optimize-gif.sh" "$input" "$output")
}

render_manim_scene() {
    need_cmd manim
    need_cmd gifski
    need_cmd ffmpeg
    need_cmd jq

    local file="${2:-$DEMO_DIR/manim/warden_architecture.py}"
    local scene="${3:-}"
    local quality="${4:-h}"
    local max_mb="${5:-10}"
    local stem base_name tmp_media rendered_mp4 export_dir export_mp4 export_gif

    if [[ -z "$scene" ]]; then
        printf 'Usage: %s manim <file.py> <SceneName> [quality] [max_mb]\n' "$0" >&2
        exit 1
    fi

    if [[ ! -f "$file" ]]; then
        printf 'Manim source not found: %s\n' "$file" >&2
        exit 1
    fi

    base_name="$(basename "${file%.py}")"
    stem="${base_name}-${scene}"
    export_dir="$DEMO_DIR/manim/exports"
    mkdir -p "$export_dir"
    tmp_media="$(mktemp -d "${TMPDIR:-/tmp}/warden-manim-XXXXXX")"
    trap 'rm -rf "$tmp_media"' RETURN

    printf '[demo] rendering manim scene %s from %s (quality=%s)\n' "$scene" "$file" "$quality"
    (cd "$ROOT_DIR" && manim render "$file" "$scene" --format mp4 -q "$quality" --media_dir "$tmp_media" -o "$stem")

    rendered_mp4="$(find "$tmp_media" -type f -name "$stem.mp4" | head -n 1)"
    if [[ -z "$rendered_mp4" ]]; then
        printf 'Could not locate rendered mp4 for %s\n' "$scene" >&2
        exit 1
    fi

    export_mp4="$export_dir/$stem.mp4"
    export_gif="$export_dir/$stem.gif"
    cp "$rendered_mp4" "$export_mp4"
    printf '[demo] optimizing manim gif -> %s\n' "$export_gif"
    (cd "$ROOT_DIR" && "$DEMO_DIR/optimize-gif.sh" "$export_mp4" "$export_gif" --max-mb "$max_mb")
    printf '[demo] wrote %s and %s\n' "$export_mp4" "$export_gif"
}

case "$target" in
    install)
        render_install
        ;;
    main)
        render_main
        ;;
    all)
        render_install
        render_main
        ;;
    optimize)
        optimize_existing "$@"
        ;;
    manim)
        render_manim_scene "$@"
        ;;
    *)
        printf 'Usage: %s [install|main|all|optimize <input.mp4> [output.gif]|manim <file.py> <SceneName> [quality] [max_mb]]\n' "$0" >&2
        exit 1
        ;;
esac
