# Demo Assets

This directory holds the source assets used to show `claude-warden` in action.

## What is here

- `demo.tape`
  - Main product demo: stock terminal behavior vs `claude-warden`, hook rewrites, read guards, truncation, and statusline output.
- `install.tape`
  - Focused install walkthrough built around `install.sh --dry-run`.
- `render.sh`
  - Convenience wrapper for rendering the VHS demos and exporting optimized Manim GIFs.
- `optimize-gif.sh`
  - Size-capped MP4 to GIF optimizer built around `gifski`, `ffmpeg`, and optional `pngquant`.
- `demo-helper.sh`
  - Deterministic helper output so the tapes stay readable and reproducible.
- `tmux-hero.sh`
  - Split-screen hero scene used by `demo.tape`.
- `manim/`
  - Manim Community animation sources. `warden_architecture.py` is the flagship — four scenes covering the 3D architecture diagram, token-savings pipeline, and full system overview.

## Prerequisites

- `vhs`
- `ffmpeg`
- `gifski`
- `tmux`
- `figlet`
- `jq`
- `pngquant` (optional, but used when a preset needs extra compression to stay under the cap)

## Render

Render both VHS demos:

```bash
./demo/render.sh all
```

Render just the install walkthrough:

```bash
./demo/render.sh install
```

This renders `demo/install.mp4` and then regenerates `demo/install.gif` through
the optimizer, hard-capped at 10 MiB.

Render just the main product demo:

```bash
./demo/render.sh main
```

Optimize any existing MP4 into a capped GIF:

```bash
./demo/render.sh optimize demo/claude-warden-demo.mp4 demo/claude-warden-demo.gif
```

## Manim animations

Requires [Manim Community](https://www.manim.community/) v0.20+.

```bash
cd demo/manim

# Still frames → assets/ (used as README architecture images)
manim render -s warden_architecture.py WardenArchDark  -qh --format png
manim render -s warden_architecture.py WardenArchLight -qh --format png

# Full animations
manim render warden_architecture.py WardenPipelineFlow   -qh   # token savings demo
manim render warden_architecture.py WardenSystemOverview -qh   # orbital 3D showcase
```

Render a Manim scene to MP4 plus a hard-capped GIF:

```bash
./demo/render.sh manim demo/manim/warden_architecture.py WardenPipelineFlow h
./demo/render.sh manim demo/manim/warden_architecture.py WardenSystemOverview h
```

That writes optimized exports to `demo/manim/exports/`, with GIF output pushed
through the same `gifski` + optional `pngquant` cap logic used for the VHS flow.

Rendered PNGs land in `demo/manim/media/images/` (gitignored). Copy the stills
to `assets/` to update the README architecture images.

## Outputs

- `demo/claude-warden-demo.mp4`
- `demo/claude-warden-demo.gif` (optional, generated via `render.sh optimize`)
- `demo/install.mp4`
- `demo/install.gif`
- `demo/manim/exports/*.mp4`
- `demo/manim/exports/*.gif`

The generated media is intentionally kept separate from the source tapes so the
scripts can evolve without forcing large binary diffs for every edit.
