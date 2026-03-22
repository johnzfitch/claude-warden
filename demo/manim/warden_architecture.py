"""
Claude Warden — Architecture Visualization Suite
Manim Community v0.20.1

Scenes
──────
  WardenArchDark        3D stacked-layer diagram, dark theme  (still → assets/architecture-dark.png)
  WardenArchLight       Same, light theme                     (still → assets/architecture-light.png)
  WardenPipelineFlow    Animated: tool call → hook → compress → token savings
  WardenSystemOverview  Grand tour: all layers, data flow, orbital camera

Render commands
──────────────
  # Still frames (drop into assets/):
  manim render -s warden_architecture.py WardenArchDark  -qh --format png
  manim render -s warden_architecture.py WardenArchLight -qh --format png

  # Animations:
  manim render warden_architecture.py WardenPipelineFlow    -qh
  manim render warden_architecture.py WardenSystemOverview  -qh

  # All scenes at once:
  manim render warden_architecture.py -a -qh
"""

from manim import *
import numpy as np

# ── Palette: dark (GitHub dark) ──────────────────────────────────────────────
D_BG      = "#0d1117"
D_SURFACE = "#161b22"
D_BORDER  = "#30363d"
D_GREEN   = "#3fb950"
D_AMBER   = "#d29922"
D_RED     = "#f85149"
D_BLUE    = "#58a6ff"
D_PURPLE  = "#bc8cff"
D_TEAL    = "#2ea68f"
D_CYAN    = "#39d353"
D_GRAY    = "#8b949e"
D_DIM     = "#484f58"
D_TEXT    = "#c9d1d9"

# ── Palette: light (GitHub light) ────────────────────────────────────────────
L_BG      = "#ffffff"
L_SURFACE = "#f6f8fa"
L_BORDER  = "#d0d7de"
L_GREEN   = "#1a7f37"
L_AMBER   = "#9a6700"
L_RED     = "#cf222e"
L_BLUE    = "#0969da"
L_PURPLE  = "#8250df"
L_TEAL    = "#0a7075"
L_CYAN    = "#116329"
L_GRAY    = "#6e7781"
L_DIM     = "#6e7781"
L_TEXT    = "#24292f"

MONO = "JetBrains Mono"


# ── Helpers ───────────────────────────────────────────────────────────────────

def chip(label, color, fs=13):
    """A pill-shaped code chip: coloured border + faint fill + monospace text."""
    w = max(len(label) * 0.092 + 0.44, 0.9)
    bg = RoundedRectangle(
        corner_radius=0.09, width=w, height=0.40,
        fill_color=color, fill_opacity=0.14,
        stroke_color=color, stroke_width=1.2,
    )
    txt = Text(label, font=MONO, font_size=fs, color=color)
    txt.move_to(bg)
    if txt.width > bg.width - 0.12:
        txt.scale_to_fit_width(bg.width - 0.12)
    return VGroup(bg, txt)


def layer_card(width, height, color, surface, title, chips_list, title_fs=21):
    """Architecture layer card with title + chip row."""
    bg = RoundedRectangle(
        corner_radius=0.20, width=width, height=height,
        fill_color=surface, fill_opacity=1.0,
        stroke_color=color, stroke_width=2.2,
    )
    ttl = Text(title, font=MONO, font_size=title_fs, color=color, weight=BOLD)
    ttl.move_to(bg.get_top() + DOWN * 0.50)

    chips = VGroup(*[chip(c, color) for c in chips_list])
    chips.arrange(RIGHT, buff=0.18)
    chips.move_to(bg.get_center() + DOWN * 0.18)
    if chips.width > width - 0.5:
        chips.scale_to_fit_width(width - 0.5)

    return VGroup(bg, ttl, chips)


def z_line(x, y, z0, z1, color, thickness=0.028):
    """3D line along the z-axis between two layer heights."""
    return Line3D(start=[x, y, z0], end=[x, y, z1], color=color, thickness=thickness)


def legend_row(text, color, fs=14):
    return Text(text, font=MONO, font_size=fs, color=color)


# ═════════════════════════════════════════════════════════════════════════════
# Scene 1 & 2 — WardenArchDark / WardenArchLight
#
# Three stacked layers in 3D. Rendered as a single still frame (-s flag) and
# copied to assets/architecture-dark.png and assets/architecture-light.png.
# ═════════════════════════════════════════════════════════════════════════════

class _WardenArch(ThreeDScene):
    """
    Base class for both theme variants.
    Subclasses set DARK = True/False.
    """
    DARK = True

    def _p(self):
        if self.DARK:
            return dict(
                bg=D_BG, surface=D_SURFACE,
                green=D_GREEN, amber=D_AMBER, blue=D_BLUE,
                red=D_RED, dim=D_DIM, gray=D_GRAY, text=D_TEXT,
            )
        return dict(
            bg=L_BG, surface=L_SURFACE,
            green=L_GREEN, amber=L_AMBER, blue=L_BLUE,
            red=L_RED, dim=L_DIM, gray=L_GRAY, text=L_TEXT,
        )

    def construct(self):
        p = self._p()
        self.camera.background_color = p["bg"]
        self.set_camera_orientation(phi=58 * DEGREES, theta=-40 * DEGREES, zoom=0.78)

        W, H = 10.0, 2.40
        Z = [0.0, 3.6, 7.2]  # collector / hooks / claude-code

        # Layer surface: use a tinted fill so each layer pops against the dark BG
        def _tinted(color):
            return color if not self.DARK else D_SURFACE

        # ── Layers ───────────────────────────────────────────────────────────
        specs = [
            dict(z=Z[0], color=p["green"], title="warden-collector  (Go)",
                 chips=["SQLite WAL", "OTLP :4319", "collector.sock", "budget-deny"]),
            dict(z=Z[1], color=p["amber"], title="Hook Membrane  (bash)",
                 chips=["pre-tool-use", "post-tool-use", "read-guard", "config-change"]),
            dict(z=Z[2], color=p["blue"],  title="Claude Code",
                 chips=["tool calls", "conversation", "OTLP telemetry", "statusline.sh"]),
        ]

        for s in specs:
            # Brighter tinted fill for each layer so it reads against the dark BG
            bg = RoundedRectangle(
                corner_radius=0.20, width=W, height=H,
                fill_color=s["color"], fill_opacity=0.13,
                stroke_color=s["color"], stroke_width=2.8,
            )
            ttl = Text(s["title"], font=MONO, font_size=22, color=s["color"], weight=BOLD)
            ttl.move_to(bg.get_top() + DOWN * 0.50)
            chips = VGroup(*[chip(c, s["color"], fs=13) for c in s["chips"]])
            chips.arrange(RIGHT, buff=0.20)
            chips.move_to(bg.get_center() + DOWN * 0.20)
            if chips.width > W - 0.55:
                chips.scale_to_fit_width(W - 0.55)
            card = VGroup(bg, ttl, chips)
            card.shift(OUT * s["z"])
            self.add(card)

        # ── Z-axis data-flow connectors ───────────────────────────────────────
        gap = 0.22
        # hook events:  Claude Code → Hook Membrane (left edge)
        self.add(z_line(-4.2, -0.8, Z[2] - gap, Z[1] + gap, p["amber"]))

        # POST /v1/ingest: Hook Membrane → Collector (centre-left)
        self.add(z_line(-1.6, -0.8, Z[1] - gap, Z[0] + gap, p["green"]))

        # budget-deny stat(): Collector → Hook pre-tool-use (centre-right, reverse)
        self.add(z_line(1.0, -0.8, Z[0] + gap, Z[1] - gap, p["red"], thickness=0.020))

        # OTLP native: Claude Code → Collector (right edge, thinner = distinct)
        self.add(z_line(4.0, -0.8, Z[2] - gap, Z[0] + gap, p["blue"], thickness=0.018))

        # statusline GET: Collector → statusline.sh (far right, reverse arrow)
        self.add(z_line(4.8, -0.8, Z[0] + gap, Z[2] - gap, p["gray"], thickness=0.015))

        # ── Fixed-frame overlays (always readable) ────────────────────────────
        # Title
        ttl = Text("claude-warden", font=MONO, font_size=46, color=p["green"], weight=BOLD)
        self.add_fixed_in_frame_mobjects(ttl)
        ttl.to_corner(UL, buff=0.52)

        ver = Text("v0.6.1", font=MONO, font_size=18, color=p["dim"])
        self.add_fixed_in_frame_mobjects(ver)
        ver.next_to(ttl, RIGHT, buff=0.30).align_to(ttl, DOWN)

        tagline = Text(
            "token guardian · security · observability",
            font=MONO, font_size=15, color=p["dim"],
        )
        self.add_fixed_in_frame_mobjects(tagline)
        tagline.next_to(ttl, DOWN, buff=0.22, aligned_edge=LEFT)

        # Legend
        legend_items = [
            legend_row("─── hook events", p["amber"]),
            legend_row("─── POST /v1/ingest (UDS)", p["green"]),
            legend_row("─── budget-deny stat()", p["red"]),
            legend_row("--- OTLP native telemetry", p["blue"]),
            legend_row("--- GET /v1/sessions", p["gray"]),
        ]
        legend = VGroup(*legend_items)
        legend.arrange(DOWN, aligned_edge=LEFT, buff=0.16)
        self.add_fixed_in_frame_mobjects(legend)
        legend.to_corner(UR, buff=0.48)

        # Hold long enough for -s to capture a clean final frame
        self.wait(3)


class WardenArchDark(_WardenArch):
    """
    Dark-theme 3D architecture diagram.
    manim render -s warden_architecture.py WardenArchDark -qh --format png
    """
    DARK = True


class WardenArchLight(_WardenArch):
    """
    Light-theme 3D architecture diagram.
    manim render -s warden_architecture.py WardenArchLight -qh --format png
    """
    DARK = False


# ═════════════════════════════════════════════════════════════════════════════
# Scene 3 — WardenPipelineFlow
#
# A tool call enters the warden pipeline, gets modified, executed, then
# compressed. Token savings accumulate in real time.
# ═════════════════════════════════════════════════════════════════════════════

class WardenPipelineFlow(Scene):
    """
    Animated pipeline: verbose npm install → hook intercept → --silent → compressed.
    manim render warden_architecture.py WardenPipelineFlow -qh
    """

    def construct(self):
        self.camera.background_color = D_BG

        # ── Stage boxes ───────────────────────────────────────────────────────
        stage_data = [
            ("PreToolUse", D_AMBER),
            ("Execute", D_BLUE),
            ("PostToolUse", D_GREEN),
        ]
        boxes, labels = VGroup(), VGroup()
        for name, color in stage_data:
            b = RoundedRectangle(
                corner_radius=0.14, width=3.1, height=1.25,
                stroke_color=color, stroke_width=2.0,
                fill_color=D_SURFACE, fill_opacity=0.9,
            )
            lbl = Text(name, font=MONO, font_size=18, color=color)
            lbl.move_to(b)
            boxes.add(b)
            labels.add(lbl)

        boxes.arrange(RIGHT, buff=1.1)
        boxes.move_to(ORIGIN)
        for lbl, b in zip(labels, boxes):
            lbl.move_to(b)

        connectors = VGroup()
        for i in range(len(boxes) - 1):
            arr = Arrow(
                boxes[i].get_right(), boxes[i + 1].get_left(),
                buff=0.12, stroke_width=2, color=D_DIM,
                tip_length=0.18,
            )
            connectors.add(arr)

        self.play(
            LaggedStart(*[Create(b) for b in boxes], lag_ratio=0.18),
            run_time=0.9,
        )
        self.play(
            LaggedStart(*[Write(lbl) for lbl in labels], lag_ratio=0.18),
            LaggedStart(*[GrowArrow(c) for c in connectors], lag_ratio=0.25),
            run_time=0.7,
        )
        self.wait(0.3)

        # ── Token counter (top-right, persistent) ─────────────────────────────
        saved_val = ValueTracker(0)
        counter_label = Text("tokens saved", font=MONO, font_size=15, color=D_DIM)
        counter_num = always_redraw(
            lambda: Text(
                f"{int(saved_val.get_value()):,}",
                font=MONO, font_size=36, color=D_CYAN,
            ).next_to(counter_label, DOWN, buff=0.12)
        )
        counter_group = VGroup(counter_label)
        counter_group.to_corner(UR, buff=0.55)
        counter_label.to_corner(UR, buff=0.55)
        counter_num.next_to(counter_label, DOWN, buff=0.12)
        self.add(counter_label, counter_num)

        # ── Incoming tool call ────────────────────────────────────────────────
        def _data_rect(text, color, w=2.8, h=0.9):
            r = RoundedRectangle(
                corner_radius=0.10, width=w, height=h,
                stroke_color=color, stroke_width=1.8,
                fill_color=D_BG, fill_opacity=0.95,
            )
            t = Text(text, font=MONO, font_size=13, color=color)
            t.move_to(r)
            if t.width > r.width - 0.2:
                t.scale_to_fit_width(r.width - 0.2)
            if t.height > r.height - 0.15:
                t.scale_to_fit_height(r.height - 0.15)
            return VGroup(r, t)

        call = _data_rect("npm install", D_TEXT)
        call.next_to(boxes[0], LEFT, buff=1.6)
        self.play(FadeIn(call, shift=RIGHT * 0.4), run_time=0.4)

        # ── ACT 1: PreToolUse — inject --silent ────────────────────────────────
        self.play(call.animate.move_to(boxes[0].get_center()), run_time=0.55)
        flash_pre = boxes[0].copy().set_stroke(D_AMBER, width=7)
        self.play(Create(flash_pre), run_time=0.18)

        inject_tag = Text("+ --silent", font=MONO, font_size=15, color=D_AMBER)
        inject_tag.next_to(boxes[0], UP, buff=0.35)
        self.play(Write(inject_tag), run_time=0.35)

        call_mod = _data_rect("npm install --silent", D_AMBER)
        call_mod.move_to(boxes[0].get_center())
        self.play(
            ReplacementTransform(call, call_mod),
            FadeOut(flash_pre),
            run_time=0.45,
        )
        self.wait(0.25)

        # ── ACT 2: Execute — large output erupts ──────────────────────────────
        self.play(call_mod.animate.move_to(boxes[1].get_center()), run_time=0.55)
        exec_flash = boxes[1].copy().set_stroke(D_BLUE, width=7)
        self.play(Create(exec_flash), FadeOut(exec_flash), run_time=0.35)

        spam_lines = [
            "npm warn deprecated @babel/plugin@7.x",
            "npm warn deprecated source-map-url@0.x",
            "npm warn deprecated urix@0.1.0",
            "npm warn deprecated resolve-url@0.2",
            "npm warn deprecated chokidar@2.1.8",
            "added 1,247 packages in 45s",
        ]
        noise = VGroup()
        for i, line in enumerate(spam_lines):
            t = Text(line, font=MONO, font_size=9, color=D_RED)
            t.move_to(boxes[1].get_center() + UP * (0.95 - i * 0.35))
            noise.add(t)
        noise.scale(0.9)

        big_out = _data_rect(
            "1,247 pkgs  ·  847 warn lines  ·  ~31 000 tokens",
            D_RED, w=3.5, h=1.6,
        )
        big_out.move_to(boxes[1].get_center())
        self.play(
            ReplacementTransform(call_mod, big_out),
            LaggedStart(*[FadeIn(n, shift=UP * 0.08) for n in noise], lag_ratio=0.07),
            run_time=0.8,
        )
        self.wait(0.3)

        # ── ACT 3: PostToolUse — compress to 3 lines ──────────────────────────
        self.play(
            big_out.animate.move_to(boxes[2].get_center()),
            noise.animate.move_to(boxes[2].get_center()).set_opacity(0.2),
            run_time=0.55,
        )
        compress_tag = Text("truncate + strip noise", font=MONO, font_size=15, color=D_GREEN)
        compress_tag.next_to(boxes[2], UP, buff=0.35)
        self.play(Write(compress_tag), run_time=0.35)

        small_out = _data_rect(
            "added 1,247 packages in 45s\n[warden: ran with --silent]",
            D_GREEN, w=2.8, h=0.85,
        )
        small_out.move_to(boxes[2].get_center())
        self.play(
            ReplacementTransform(big_out, small_out),
            FadeOut(noise),
            run_time=0.55,
        )

        # Token counter climbs
        self.play(saved_val.animate.set_value(30_880), run_time=1.4, rate_func=rush_from)
        self.wait(0.3)

        # ── Clean up stages, show final stat ─────────────────────────────────
        result_arrow = Arrow(
            small_out.get_right(),
            small_out.get_right() + RIGHT * 2.0,
            buff=0.12, stroke_width=2, color=D_GREEN, tip_length=0.18,
        )
        conv_label = Text("model sees this", font=MONO, font_size=14, color=D_TEXT)
        conv_label.next_to(result_arrow, RIGHT, buff=0.15)
        self.play(GrowArrow(result_arrow), FadeIn(conv_label), run_time=0.4)

        self.wait(0.4)
        self.play(
            FadeOut(boxes), FadeOut(labels), FadeOut(connectors),
            FadeOut(inject_tag), FadeOut(compress_tag),
            FadeOut(small_out), FadeOut(result_arrow), FadeOut(conv_label),
            run_time=0.5,
        )

        # Finale
        pct = Text("99.6% reduction", font=MONO, font_size=52, color=D_CYAN)
        pct.move_to(ORIGIN + UP * 0.5)
        sub = Text("per verbose install call", font=MONO, font_size=22, color=D_GRAY)
        sub.next_to(pct, DOWN, buff=0.3)
        self.play(Write(pct), run_time=0.8)
        self.play(FadeIn(sub, shift=UP * 0.15), run_time=0.4)
        self.wait(1.5)


# ═════════════════════════════════════════════════════════════════════════════
# Scene 4 — WardenSystemOverview
#
# Grand tour: intro shield → layer-by-layer build → data particles → orbit.
# Replaces hook_dimensions.py as the flagship animation.
# ═════════════════════════════════════════════════════════════════════════════

class WardenSystemOverview(ThreeDScene):
    """
    Full 3D system showcase with orbital camera.
    manim render warden_architecture.py WardenSystemOverview -qh
    """

    W, H = 9.4, 2.0
    Z_LAYERS = [0.0, 3.6, 7.2]
    LAYER_SPECS = [
        dict(color=D_GREEN, title="warden-collector",
             chips=["SQLite WAL", "OTLP :4319", "UDS", "budget-deny"]),
        dict(color=D_AMBER, title="Hook Membrane",
             chips=["pre-tool-use", "post-tool-use", "read-guard", "config-change"]),
        dict(color=D_BLUE,  title="Claude Code",
             chips=["tool calls", "conversation", "OTLP", "statusline"]),
    ]

    def construct(self):
        self.camera.background_color = D_BG
        np.random.seed(7)

        # ── ACT 0: 2D shield intro ─────────────────────────────────────────────
        self.set_camera_orientation(phi=0, theta=-90 * DEGREES, zoom=1.0)
        self._shield_intro()

        # ── ACT 1: layer reveal (flat, frontal camera) ─────────────────────────
        self.set_camera_orientation(phi=0, theta=-90 * DEGREES, zoom=0.85)
        layer_groups = self._reveal_layers()

        # ── ACT 2: tilt camera into 3D spread ─────────────────────────────────
        self._tilt_into_3d(layer_groups)

        # ── ACT 3: data particles flowing between layers ───────────────────────
        self._particle_flow()

        # ── ACT 4: slow orbit with title ──────────────────────────────────────
        self._orbit_finale()

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _shield_intro(self):
        """Warden shield assembles from scattered characters."""
        lines = [
            "  ╔══════════╗  ",
            " ║  ░░░░░░░░ ║ ",
            " ║  ░ ████ ░ ║ ",
            " ║  ░ █  █ ░ ║ ",
            " ║  ░ ████ ░ ║ ",
            "  ║ ░░░░░░ ║  ",
            "   ║ ░░░░░ ║   ",
            "    ║ ░░░ ║    ",
            "     ║ ░ ║     ",
            "      ╚═╝      ",
        ]
        shield = VGroup()
        for i, line in enumerate(lines):
            t = Text(line, font=MONO, font_size=22, color=D_GREEN)
            t.move_to(UP * (2.2 - i * 0.46))
            shield.add(t)

        # Scatter
        targets = [t.get_center().copy() for t in shield]
        for t in shield:
            t.move_to([
                np.random.uniform(-6.5, 6.5),
                np.random.uniform(-4, 4), 0,
            ]).set_opacity(0.25)
        self.add(*shield)

        # Assemble
        self.play(
            *[t.animate.move_to(pos).set_opacity(1.0) for t, pos in zip(shield, targets)],
            run_time=1.6, rate_func=smooth,
        )
        self.wait(0.4)

        title = Text("claude-warden", font=MONO, font_size=44, color=D_GREEN, weight=BOLD)
        title.next_to(shield, DOWN, buff=0.55)
        self.play(Write(title), run_time=0.7)
        self.wait(0.8)
        self.play(FadeOut(shield), FadeOut(title), run_time=0.55)
        self.wait(0.2)

    def _reveal_layers(self):
        """Build layers one at a time at z=0, then stack them."""
        groups = []
        for spec in self.LAYER_SPECS:
            card = layer_card(
                self.W, self.H, spec["color"], D_SURFACE,
                spec["title"], spec["chips"],
            )
            groups.append(card)

        # Reveal each layer while centered at z=0 (flat view)
        for i, (card, spec) in enumerate(zip(groups, self.LAYER_SPECS)):
            tag = Text(spec["title"], font=MONO, font_size=28, color=spec["color"])
            self.add_fixed_in_frame_mobjects(tag)
            tag.to_edge(UP, buff=0.45)

            self.play(
                FadeIn(card, shift=UP * 0.25),
                FadeIn(tag, shift=DOWN * 0.1),
                run_time=0.5,
            )
            self.wait(0.4)

            self.play(FadeOut(tag), run_time=0.25)
            self.remove_fixed_in_frame_mobjects(tag)

            if i < len(groups) - 1:
                self.play(FadeOut(card), run_time=0.25)

        return groups

    def _tilt_into_3d(self, layer_groups):
        """Fan layers to their z-positions while tilting camera into 3D."""
        # Put all layers back at z=0
        for card in layer_groups:
            card.set_opacity(0)
            self.add(card)

        # Flash all in flat
        self.play(
            *[card.animate.set_opacity(1.0) for card in layer_groups],
            run_time=0.4,
        )
        self.wait(0.2)

        # Spread to z-positions + camera tilt simultaneously
        spread_anims = []
        for card, z in zip(layer_groups, self.Z_LAYERS):
            spread_anims.append(card.animate.shift(OUT * z))

        self.move_camera(
            phi=65 * DEGREES, theta=-46 * DEGREES,
            frame_center=[0, 0, self.Z_LAYERS[1]],
            zoom=0.68,
            added_anims=spread_anims,
            run_time=2.6,
            rate_func=smooth,
        )
        self.wait(0.4)

        # Vertical pillars at corners (structural depth cue)
        for x, y in [(-4.7, -0.8), (4.7, -0.8)]:
            pillar = Line3D(
                start=[x, y, 0],
                end=[x, y, self.Z_LAYERS[-1]],
                color=D_DIM, thickness=0.018,
            )
            self.add(pillar)

        # Add z-axis connectors
        self.add(z_line(-3.8, -0.5, self.Z_LAYERS[2] - 0.1, self.Z_LAYERS[1] + 0.1, D_AMBER))
        self.add(z_line(-1.0, -0.5, self.Z_LAYERS[1] - 0.1, self.Z_LAYERS[0] + 0.1, D_GREEN))
        self.add(z_line(3.5,  -0.5, self.Z_LAYERS[2] - 0.1, self.Z_LAYERS[0] + 0.1, D_BLUE, 0.015))

        self.wait(0.6)

    def _particle_flow(self):
        """Data particles stream down through the layers."""
        paths = [
            dict(x=-3.8, y=-0.5, color=D_AMBER, z_start=self.Z_LAYERS[2], z_end=self.Z_LAYERS[1]),
            dict(x=-1.0, y=-0.5, color=D_GREEN,  z_start=self.Z_LAYERS[1], z_end=self.Z_LAYERS[0]),
            dict(x=3.5,  y=-0.5, color=D_BLUE,   z_start=self.Z_LAYERS[2], z_end=self.Z_LAYERS[0]),
        ]

        for _ in range(3):
            dots = []
            anims = []
            for path in paths:
                d = Sphere(radius=0.09, color=path["color"])
                d.set_opacity(0.85)
                d.move_to([path["x"], path["y"], path["z_start"]])
                dots.append(d)
                self.add(d)
                anims.append(d.animate.move_to([path["x"], path["y"], path["z_end"]]))

            self.play(*anims, run_time=0.9, rate_func=linear)
            self.play(*[FadeOut(d) for d in dots], run_time=0.2)

        self.wait(0.4)

    def _orbit_finale(self):
        """Slow ambient orbit, then fade up the title."""
        # Title overlay
        title = Text("claude-warden", font=MONO, font_size=50, color=D_GREEN, weight=BOLD)
        self.add_fixed_in_frame_mobjects(title)
        title.to_edge(DOWN, buff=0.55).set_opacity(0)
        self.play(title.animate.set_opacity(1.0), run_time=0.9)

        sub = Text(
            "token guardian · security · observability",
            font=MONO, font_size=17, color=D_DIM,
        )
        self.add_fixed_in_frame_mobjects(sub)
        sub.next_to(title, UP, buff=0.18).set_opacity(0)
        self.play(sub.animate.set_opacity(1.0), run_time=0.7)

        # Breathing pulse on layers
        self.begin_ambient_camera_rotation(rate=0.08)
        self.wait(6, frozen_frame=False)
        self.stop_ambient_camera_rotation()
        self.wait(0.5)
