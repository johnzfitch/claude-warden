"""
Claude Warden — Hook Dimensions v2

Guided tour: one layer at a time with narration and demos.
Final zoom-out spreads flat layers into a 3D stack.

  Funnel  = UserPromptSubmit  (input filtering)
  Shield  = PreToolUse        (access guarding)
  Lens    = PostToolUse       (output observation)
  Gate    = Stop              (flow control)

Render:
  manim render hook_dimensions.py HookDimensions -ql -p   # 480p preview
  manim render hook_dimensions.py HookDimensions -qh      # 1080p
"""

from manim import *
import numpy as np

# ── Palette ──────────────────────────────────────────────────────────
BG   = "#0d1117"
GRN  = "#3fb950"
AMB  = "#d29922"
RED  = "#f85149"
BLU  = "#58a6ff"
TEAL = "#2ea68f"
GRY  = "#8b949e"
DIM  = "#484f58"
TXT  = "#c9d1d9"

# ── Layer definitions ────────────────────────────────────────────────
LAYERS = [
    {"name": "UserPromptSubmit", "color": TEAL,
     "sub": "filters input before it reaches the model"},
    {"name": "PreToolUse", "color": AMB,
     "sub": "guards every tool call"},
    {"name": "PostToolUse", "color": BLU,
     "sub": "inspects and transforms output"},
    {"name": "Stop", "color": GRN,
     "sub": "controls conversation flow"},
]

# Z-positions for the final 3D spread
FINAL_Z = [0, 2.0, 4.0, 6.0]


class HookDimensions(ThreeDScene):

    def construct(self):
        self.camera.background_color = BG
        np.random.seed(42)

        # Start flat, centered, close
        self.set_camera_orientation(phi=0, theta=-90 * DEGREES, zoom=0.9)

        # ═══ INTRO ═══
        self._intro()

        # ═══ LAYER-BY-LAYER TOUR (all at z=0, one at a time) ═══
        for i, cfg in enumerate(LAYERS):
            self._tour_layer(i, cfg)

        # ═══ ZOOM OUT: flat → 3D spread ═══
        self._zoom_out()

    # ──────────────────────────────────────────────────────────────
    # INTRO
    # ──────────────────────────────────────────────────────────────
    def _intro(self):
        title = Text("claude-warden", font="Graphik", font_size=56, color=GRN)
        self.add_fixed_in_frame_mobjects(title)
        title.move_to(ORIGIN)
        self.play(Write(title), run_time=1.0)
        self.wait(0.8)
        self.play(FadeOut(title), run_time=0.5)
        self.remove_fixed_in_frame_mobjects(title)
        self.wait(0.2)

    # ──────────────────────────────────────────────────────────────
    # SINGLE LAYER TOUR
    # ──────────────────────────────────────────────────────────────
    def _tour_layer(self, idx, cfg):
        color = cfg["color"]

        # Background plane
        plane = Rectangle(
            width=12, height=7,
            fill_color=color, fill_opacity=0.04,
            stroke_color=color, stroke_width=1.5, stroke_opacity=0.25,
        )

        # Three hook shapes: side · HERO · side
        shapes = self._shapes_row(idx, color)

        # Reveal
        self.play(FadeIn(plane), run_time=0.3)
        self.play(
            LaggedStart(*[GrowFromCenter(s) for s in shapes], lag_ratio=0.12),
            run_time=0.5,
        )

        # ── Tag (hook event name, top center) ──
        tag = Text(cfg["name"], font="JetBrains Mono", font_size=30, color=color)
        self.add_fixed_in_frame_mobjects(tag)
        tag.to_edge(UP, buff=0.5)
        self.play(FadeIn(tag, shift=DOWN * 0.1), run_time=0.3)

        # ── Layer progress dots (top right) ──
        dots = self._progress_dots(idx)
        self.add_fixed_in_frame_mobjects(dots)
        dots.next_to(tag, RIGHT, buff=0.6)
        self.play(FadeIn(dots), run_time=0.15)

        # ── Subtitle (bottom center) ──
        sub = Text(cfg["sub"], font="Graphik", font_size=22, color=TXT)
        self.add_fixed_in_frame_mobjects(sub)
        sub.to_edge(DOWN, buff=0.6)
        self.play(FadeIn(sub, shift=UP * 0.1), run_time=0.3)

        self.wait(0.3)

        # ── Demo animation ──
        demos = [self._demo_funnel, self._demo_shield,
                 self._demo_lens, self._demo_gate]
        demos[idx](shapes[1], color)

        # Cleanup
        self.play(FadeOut(tag), FadeOut(sub), FadeOut(dots), run_time=0.3)
        self.remove_fixed_in_frame_mobjects(tag, sub, dots)
        self.play(FadeOut(plane), FadeOut(shapes), run_time=0.4)
        self.wait(0.15)

    # ──────────────────────────────────────────────────────────────
    # ZOOM OUT REVEAL
    # ──────────────────────────────────────────────────────────────
    def _zoom_out(self):
        # Recreate all layers at z=0
        planes, shape_grps = [], []
        for i, cfg in enumerate(LAYERS):
            p = Rectangle(
                width=10, height=6,
                fill_color=cfg["color"], fill_opacity=0.08,
                stroke_color=cfg["color"], stroke_width=1, stroke_opacity=0.3,
            )
            s = self._shapes_row(i, cfg["color"], hero_scale=0.9, side_scale=0.55)
            planes.append(p)
            shape_grps.append(s)

        # Flash them all in at z=0 (stacked, flat)
        self.play(
            *[FadeIn(p) for p in planes],
            *[FadeIn(s) for s in shape_grps],
            run_time=0.4,
        )
        self.wait(0.2)

        # Spread to z-positions + camera tilt (the dramatic reveal)
        spread = []
        for i in range(4):
            z = FINAL_Z[i]
            spread.append(planes[i].animate.shift(OUT * z))
            spread.append(shape_grps[i].animate.shift(OUT * z))

        self.move_camera(
            phi=65 * DEGREES, theta=-50 * DEGREES,
            frame_center=[0, 0, 3],
            zoom=0.45,
            added_anims=spread,
            run_time=3.0,
            rate_func=smooth,
        )
        self.wait(0.3)

        # Vertical pillars
        pillars = VGroup()
        for x, y in [(-4, -2.5), (4, -2.5), (-4, 2.5), (4, 2.5)]:
            line = Line3D(start=[x, y, 0], end=[x, y, 6],
                          color=DIM, thickness=0.02)
            line.set_opacity(0.15)
            pillars.add(line)
        self.play(
            LaggedStart(*[Create(p) for p in pillars], lag_ratio=0.05),
            run_time=0.5,
        )

        # Breathing pulse
        self.play(
            *[p.animate.set_stroke(opacity=0.7) for p in planes], run_time=0.4,
        )
        self.play(
            *[p.animate.set_stroke(opacity=0.3) for p in planes], run_time=0.4,
        )

        # Slow orbit
        self.begin_ambient_camera_rotation(rate=0.1)
        self.wait(5, frozen_frame=False)
        self.stop_ambient_camera_rotation()

        # Finale title
        title = Text("claude-warden", font="Graphik", font_size=52, color=GRN)
        self.add_fixed_in_frame_mobjects(title)
        title.to_edge(DOWN, buff=0.8).set_opacity(0)
        self.play(title.animate.set_opacity(1), run_time=1.0)
        self.wait(2.0)

    # ──────────────────────────────────────────────────────────────
    # SHAPE BUILDERS
    # ──────────────────────────────────────────────────────────────
    def _shapes_row(self, layer_idx, color, hero_scale=1.3, side_scale=0.85):
        """Three shapes: left (small) · center hero (large) · right (small)."""
        makers = [self._funnel, self._shield, self._lens, self._gate]
        maker = makers[layer_idx]
        g = VGroup()
        for x, sc in [(-3.5, side_scale), (0, hero_scale), (3.5, side_scale)]:
            s = maker(color)
            s.scale(sc).move_to(RIGHT * x)
            g.add(s)
        return g

    def _progress_dots(self, active_idx):
        """Four small dots showing which layer we're on."""
        g = VGroup()
        for j in range(4):
            d = Circle(
                radius=0.06,
                fill_color=LAYERS[j]["color"] if j == active_idx else DIM,
                fill_opacity=1.0 if j == active_idx else 0.3,
                stroke_width=0,
            )
            d.shift(RIGHT * (j - 1.5) * 0.25)
            g.add(d)
        return g

    def _funnel(self, c):
        body = Polygon(
            [-0.6, 0.5, 0], [0.6, 0.5, 0],
            [0.18, -0.5, 0], [-0.18, -0.5, 0],
            fill_color=c, fill_opacity=0.18,
            stroke_color=c, stroke_width=3,
        )
        # Small down-arrow inside to reinforce "narrowing"
        arrow = Triangle(fill_color=c, fill_opacity=0.3, stroke_width=0)
        arrow.scale(0.15).rotate(PI).move_to(body.get_center() + DOWN * 0.05)
        return VGroup(body, arrow)

    def _shield(self, c):
        body = Polygon(
            [-0.5, 0.6, 0], [0.5, 0.6, 0],
            [0.5, -0.15, 0], [0, -0.6, 0], [-0.5, -0.15, 0],
            fill_color=c, fill_opacity=0.15,
            stroke_color=c, stroke_width=3,
        )
        # Horizontal bar across the shield
        bar = Line(LEFT * 0.3, RIGHT * 0.3, stroke_color=c, stroke_width=2)
        bar.move_to(body.get_center() + UP * 0.05)
        return VGroup(body, bar)

    def _lens(self, c):
        outer = Ellipse(width=1.0, height=0.5,
                        fill_color=c, fill_opacity=0.08,
                        stroke_color=c, stroke_width=3)
        # Inner pupil dot
        pupil = Circle(radius=0.08, fill_color=c, fill_opacity=0.35, stroke_width=0)
        return VGroup(outer, pupil)

    def _gate(self, c):
        g = VGroup()
        # Two vertical bars
        for dx in [-0.25, 0.25]:
            g.add(Rectangle(
                width=0.1, height=0.7,
                fill_color=c, fill_opacity=0.25,
                stroke_color=c, stroke_width=3,
            ).shift(RIGHT * dx))
        # Cross bar
        g.add(Rectangle(
            width=0.6, height=0.08,
            fill_color=c, fill_opacity=0.2,
            stroke_color=c, stroke_width=2,
        ))
        return g

    # ──────────────────────────────────────────────────────────────
    # DEMO ANIMATIONS
    # ──────────────────────────────────────────────────────────────
    def _demo_funnel(self, hero, color):
        """Data enters wide, some filtered, rest exits narrow."""
        dots = VGroup()
        for i in range(6):
            d = Circle(radius=0.1, fill_color=TXT, fill_opacity=0.7, stroke_width=0)
            d.move_to(LEFT * 5.5 + UP * (0.75 - i * 0.3))
            dots.add(d)

        self.play(FadeIn(dots), run_time=0.2)
        # Slide toward funnel
        self.play(*[d.animate.shift(RIGHT * 3.5) for d in dots], run_time=0.6)

        # Split: 4 pass through (narrow), 2 rejected upward
        anims = []
        pass_idx, reject_idx = [0, 1, 3, 5], [2, 4]
        for j, d in enumerate(dots):
            if j in reject_idx:
                anims.append(
                    d.animate.shift(UP * 1.5 + RIGHT * 0.3)
                    .set_color(RED).set_opacity(0)
                )
            else:
                slot = pass_idx.index(j)
                anims.append(
                    d.animate.move_to(RIGHT * 2.8 + UP * (0.2 - slot * 0.13))
                    .set_color(color).scale(0.65)
                )
        self.play(*anims, run_time=0.7)
        self.wait(0.5)
        self.play(FadeOut(dots), run_time=0.3)

    def _demo_shield(self, hero, color):
        """Tool call approaches — shield allows or blocks."""
        # ── ALLOW ──
        t1 = RoundedRectangle(
            corner_radius=0.05, width=0.5, height=0.3,
            fill_color=GRN, fill_opacity=0.5, stroke_color=GRN, stroke_width=1.5,
        ).move_to(LEFT * 5.5)
        lbl1 = Text("Bash", font="JetBrains Mono", font_size=12, color=GRN)
        lbl1.move_to(t1)
        tool1 = VGroup(t1, lbl1)

        self.play(FadeIn(tool1), run_time=0.15)
        self.play(tool1.animate.move_to(LEFT * 1.2), run_time=0.5)
        self.play(
            hero[0].animate.set_stroke(GRN, width=5, opacity=1),
            tool1.animate.move_to(RIGHT * 3.5).set_opacity(0.3),
            run_time=0.4,
        )
        self.play(hero[0].animate.set_stroke(color, width=3, opacity=1), run_time=0.2)

        # ── BLOCK ──
        t2 = RoundedRectangle(
            corner_radius=0.05, width=0.5, height=0.3,
            fill_color=RED, fill_opacity=0.5, stroke_color=RED, stroke_width=1.5,
        ).move_to(LEFT * 5.5)
        lbl2 = Text("rm -rf", font="JetBrains Mono", font_size=10, color=RED)
        lbl2.move_to(t2)
        tool2 = VGroup(t2, lbl2)

        self.play(FadeIn(tool2), run_time=0.15)
        self.play(tool2.animate.move_to(LEFT * 1.2), run_time=0.5)

        # Block flash
        self.play(
            hero[0].animate.set_stroke(RED, width=5, opacity=1),
            tool2.animate.shift(LEFT * 3).set_opacity(0),
            run_time=0.4,
        )
        # Blocked label
        blk = Text("blocked", font="JetBrains Mono", font_size=16, color=RED)
        blk.next_to(hero, DOWN, buff=0.4)
        self.play(
            hero[0].animate.set_stroke(color, width=3, opacity=1),
            FadeIn(blk, shift=UP * 0.1),
            run_time=0.3,
        )
        self.wait(0.3)
        self.play(FadeOut(tool1), FadeOut(tool2), FadeOut(blk), run_time=0.2)

    def _demo_lens(self, hero, color):
        """Data passes through, lens inspects, output tagged."""
        data = RoundedRectangle(
            corner_radius=0.05, width=0.7, height=0.3,
            fill_color=TXT, fill_opacity=0.4, stroke_color=TXT, stroke_width=1.5,
        ).move_to(LEFT * 5.5)

        self.play(FadeIn(data), run_time=0.15)
        self.play(data.animate.move_to(LEFT * 0.2), run_time=0.5)

        # Lens inspects: iris pulse
        self.play(
            hero[0].animate.scale(1.3).set_fill(opacity=0.25),
            hero[1].animate.scale(1.5),
            run_time=0.3,
        )
        self.play(
            hero[0].animate.scale(1 / 1.3).set_fill(opacity=0.08),
            hero[1].animate.scale(1 / 1.5),
            run_time=0.3,
        )

        # Data exits with context ring
        ring = Circle(radius=0.28, stroke_color=color, stroke_width=2, fill_opacity=0)
        ring.move_to(RIGHT * 3.5)
        ctx = Text("+context", font="JetBrains Mono", font_size=12, color=color)
        ctx.move_to(RIGHT * 3.5 + DOWN * 0.4)

        self.play(
            data.animate.move_to(RIGHT * 3.5).set_color(color),
            FadeIn(ring), FadeIn(ctx),
            run_time=0.6,
        )
        self.wait(0.4)
        self.play(FadeOut(data), FadeOut(ring), FadeOut(ctx), run_time=0.25)

    def _demo_gate(self, hero, color):
        """Flow passes or gets blocked by gate."""
        bars = [hero[0], hero[1]]

        # ── Flow 1: allowed ──
        f1 = Arrow(LEFT * 5.5, LEFT * 1, buff=0,
                    stroke_color=TXT, stroke_width=2.5)
        self.play(GrowArrow(f1), run_time=0.4)

        # Gate opens
        self.play(
            bars[0].animate.shift(LEFT * 0.2),
            bars[1].animate.shift(RIGHT * 0.2),
            run_time=0.25,
        )
        self.play(f1.animate.shift(RIGHT * 5.5).set_color(color), run_time=0.5)
        # Gate closes
        self.play(
            bars[0].animate.shift(RIGHT * 0.2),
            bars[1].animate.shift(LEFT * 0.2),
            run_time=0.25,
        )

        # ── Flow 2: blocked ──
        f2 = Arrow(LEFT * 5.5, LEFT * 1, buff=0,
                    stroke_color=RED, stroke_width=2.5)
        self.play(GrowArrow(f2), run_time=0.35)

        ex = Text("exit 2", font="JetBrains Mono", font_size=18, color=RED)
        ex.next_to(hero, UP, buff=0.4)
        rej = Text("reinject to model", font="Graphik", font_size=14, color=RED)
        rej.next_to(ex, DOWN, buff=0.15)

        self.play(FadeIn(ex, shift=DOWN * 0.1), FadeIn(rej, shift=DOWN * 0.1),
                  run_time=0.3)
        self.wait(0.5)
        self.play(FadeOut(f1), FadeOut(f2), FadeOut(ex), FadeOut(rej), run_time=0.3)
