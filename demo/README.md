# Demo Assets

This directory holds the source assets used to show `claude-warden` in action.

## What is here

- `demo.tape`
  - Main product demo: stock terminal behavior vs `claude-warden`, hook rewrites, read guards, truncation, and statusline output.
- `install.tape`
  - Focused install walkthrough built around `install.sh --dry-run`.
- `render.sh`
  - Convenience wrapper for rendering the VHS demos.
- `demo-helper.sh`
  - Deterministic helper output so the tapes stay readable and reproducible.
- `tmux-hero.sh`
  - Split-screen hero scene used by `demo.tape`.
- `manim/`
  - Manim Community animation sources. `warden_architecture.py` is the flagship — four scenes covering the 3D architecture diagram, token-savings pipeline, and full system overview.

## Prerequisites

- `vhs`
- `ffmpeg`
- `tmux`
- `figlet`
- `jq`

## Render

Render both VHS demos:

```bash
./demo/render.sh all
```

Render just the install walkthrough:

```bash
./demo/render.sh install
```

Render just the main product demo:

```bash
./demo/render.sh main
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

Rendered PNGs land in `demo/manim/media/images/` (gitignored). Copy the stills
to `assets/` to update the README architecture images.

## Outputs

- `demo/claude-warden-demo.mp4`
- `demo/install.mp4`
- `demo/install.gif`

The generated media is intentionally kept separate from the source tapes so the
scripts can evolve without forcing large binary diffs for every edit.
