"""
Claude Warden - Ripgrep Hallway

A ripgrep arrow races through a Severance-style corridor searching
for formData. It accumulates junk output that weighs it down.
A PostToolUse hook door strips the noise. Token counter shows the cost.

Render:
  manim render ripgrep_hallway.py RipgrepHallway -ql -p
  manim render ripgrep_hallway.py RipgrepHallway -qh
"""

from manim import *
import numpy as np

BG   = "#0d1117"
GRN  = "#3fb950"
AMB  = "#d29922"
RED  = "#f85149"
BLU  = "#58a6ff"
TEAL = "#2ea68f"
GRY  = "#8b949e"
DIM  = "#484f58"
TXT  = "#c9d1d9"

WALL_TOP   =  1.8
WALL_BOT   = -1.8
HALL_START  = -13
HALL_END    =  24
NARROW_X   =  7
DOOR_X     = 16
CAMERA_LEAD = 3.8

JUNK = [
    (-7,  "node_modules/react/...",     800,  UP*0.35 + RIGHT*0.15),
    (-5,  ".git/objects/pack-...",       600,  DOWN*0.25 + RIGHT*0.1),
    (-3,  "dist/vendor.bundle.js",     1800,  UP*0.55 + LEFT*0.1),
    (-1,  "package-lock.json",         4500,  DOWN*0.45),
    ( 1,  "coverage/lcov.info",        1200,  UP*0.25 + LEFT*0.2),
    ( 3,  "__pycache__/module.cpython",  900,  DOWN*0.55 + RIGHT*0.2),
    ( 5,  "build/intermediates/...",    2000,  UP*0.7),
    ( 9,  ".yarn/cache/lodash-...",     1500,  DOWN*0.35 + LEFT*0.25),
    (11,  "test/fixtures/large.json",   3000,  UP*0.45 + RIGHT*0.3),
    (13,  ".next/static/chunks/...",    2500,  DOWN*0.65),
]


class RipgrepHallway(MovingCameraScene):

    def construct(self):
        self.camera.background_color = BG

        corridor = self._build_corridor()
        self.add(corridor)

        arrow = self._make_arrow()
        arrow.move_to([HALL_START + 2, 0, 0])
        mass = VGroup(arrow)
        self.add(mass)

        self.camera.frame.move_to([self._camera_x_for(arrow.get_center()[0]), 0, 0])

        query = Text(
            "rg formData .", font="JetBrains Mono", font_size=18, color=TEAL
        )
        query.add_updater(lambda m: m.move_to(
            self.camera.frame.get_corner(UL) + DOWN * 0.45 + RIGHT * 1.5
        ))
        self.add(query)

        token_val = ValueTracker(500)
        token_label = Text("tokens", font="JetBrains Mono", font_size=13, color=GRY)
        token_num = DecimalNumber(
            500, num_decimal_places=0, font_size=20, color=AMB
        )
        token_num.add_updater(lambda m: m.set_value(token_val.get_value()))

        def _color_num(m):
            v = token_val.get_value()
            m.set_color(RED if v > 16000 else (AMB if v > 8000 else GRN))
        token_num.add_updater(_color_num)

        token_grp = VGroup(token_label, token_num).arrange(RIGHT, buff=0.15)
        token_grp.add_updater(lambda m: m.move_to(
            self.camera.frame.get_edge_center(DOWN) + UP * 0.45
        ))
        self.add(token_grp)

        bar_bg = RoundedRectangle(
            corner_radius=0.06, width=4, height=0.14,
            fill_color=DIM, fill_opacity=0.3, stroke_color=DIM, stroke_width=0.5,
        )
        bar_bg.add_updater(lambda m: m.move_to(
            self.camera.frame.get_edge_center(DOWN) + UP * 0.2
        ))
        self.add(bar_bg)

        bar_fill = always_redraw(lambda: Rectangle(
            width=max(0.01, min(3.96, (token_val.get_value() / 25000) * 3.96)),
            height=0.12,
            fill_color=RED if token_val.get_value() > 16000 else (
                AMB if token_val.get_value() > 8000 else GRN),
            fill_opacity=0.7, stroke_width=0,
        ).move_to(bar_bg.get_center()).align_to(bar_bg, LEFT).shift(RIGHT * 0.02))
        self.add(bar_fill)

        self.wait(0.3, frozen_frame=False)

        running_tokens = 500
        for i, (jx, label, cost, offset) in enumerate(JUNK):
            dx = jx - arrow.get_center()[0]
            n_attached = len(mass.submobjects) - 1
            speed = max(0.2, 0.65 - n_attached * 0.04)

            half_cost = cost * 0.5
            running_tokens += half_cost
            self.play(
                mass.animate.shift(RIGHT * dx),
                self.camera.frame.animate.set_x(
                    self._camera_x_for(arrow.get_center()[0] + dx)
                ),
                token_val.animate.set_value(running_tokens),
                run_time=speed,
            )

            wall_y = WALL_TOP - 0.25 if i % 2 == 0 else WALL_BOT + 0.25
            junk = self._junk_rect(label)
            junk.move_to([arrow.get_center()[0] + 1.5, wall_y, 0])
            self.add(junk)

            running_tokens += half_cost
            self.play(
                junk.animate.move_to(arrow.get_center() + offset).scale(0.65),
                token_val.animate.set_value(running_tokens),
                run_time=0.2,
            )
            mass.add(junk)

            if i == 6:
                self._wall_scrape(mass)

        door_dx = DOOR_X - arrow.get_center()[0]
        self.play(
            mass.animate.shift(RIGHT * door_dx),
            self.camera.frame.animate.set_x(
                self._camera_x_for(arrow.get_center()[0] + door_dx)
            ),
            run_time=1.5,
            rate_func=rush_from,
        )
        self.wait(0.2, frozen_frame=False)

        peak_tokens = running_tokens
        self._door_strip(mass, arrow, token_val)

        result = self._make_result()
        result.next_to(arrow, RIGHT, buff=0.15)
        self.play(FadeIn(result, shift=LEFT * 0.2), run_time=0.3)
        mass.add(result)

        self.play(
            mass.animate.shift(RIGHT * 3),
            self.camera.frame.animate.set_x(
                self._camera_x_for(arrow.get_center()[0] + 3)
            ),
            run_time=0.8,
        )

        saved_n = int(peak_tokens - 800)
        saved = Text(
            f"saved {saved_n:,} tokens",
            font="JetBrains Mono", font_size=24, color=GRN,
        )
        saved.move_to(arrow.get_center() + UP * 2.2)
        self.play(FadeIn(saved, shift=DOWN * 0.15), run_time=0.5)
        self.wait(0.8, frozen_frame=False)

        title = Text("claude-warden", font="Graphik", font_size=48, color=GRN)
        title.move_to(arrow.get_center() + DOWN * 1.5)
        self.play(FadeOut(saved), Write(title), run_time=0.8)
        self.wait(1.5, frozen_frame=False)

    def _build_corridor(self):
        g = VGroup()
        for y in [WALL_TOP, WALL_BOT]:
            g.add(Line(
                [HALL_START, y, 0], [HALL_END, y, 0],
                stroke_color=DIM, stroke_width=2.5,
            ))
        for x in range(HALL_START, HALL_END, 3):
            for y in [WALL_TOP, WALL_BOT]:
                g.add(Line(
                    [x, y, 0], [x, y - np.sign(y) * 0.15, 0],
                    stroke_color=DIM, stroke_width=1, stroke_opacity=0.4,
                ))
        for x in range(HALL_START, HALL_END, 2):
            g.add(Line(
                [x, WALL_BOT, 0], [x, WALL_TOP, 0],
                stroke_color=DIM, stroke_width=0.3, stroke_opacity=0.06,
            ))
        for sec, x in enumerate(range(-10, 20, 5)):
            for y in [WALL_TOP + 0.3, WALL_BOT - 0.3]:
                g.add(Text(
                    f"SEC.{sec + 1}", font="JetBrains Mono",
                    font_size=8, color=DIM,
                ).move_to([x, y, 0]).set_opacity(0.35))
        for sign, base_y in [(1, WALL_TOP), (-1, WALL_BOT)]:
            g.add(Polygon(
                [NARROW_X - 1, base_y, 0],
                [NARROW_X,     base_y - sign * 0.9, 0],
                [NARROW_X + 2, base_y - sign * 0.9, 0],
                [NARROW_X + 3, base_y, 0],
                stroke_color=AMB, stroke_width=2, stroke_opacity=0.6,
                fill_color=AMB, fill_opacity=0.02,
            ))
        for y in [WALL_TOP, WALL_BOT]:
            g.add(Rectangle(
                width=0.25, height=0.7,
                fill_color=GRN, fill_opacity=0.12,
                stroke_color=GRN, stroke_width=2,
            ).move_to([DOOR_X, y - np.sign(y) * 0.35, 0]))
        g.add(Text(
            "PostToolUse", font="JetBrains Mono", font_size=12, color=GRN,
        ).move_to([DOOR_X, WALL_TOP + 0.4, 0]))
        g.add(DashedLine(
            [DOOR_X, WALL_TOP - 0.7, 0], [DOOR_X, WALL_BOT + 0.7, 0],
            dash_length=0.15, stroke_color=GRN, stroke_width=1, stroke_opacity=0.4,
        ))
        return g

    def _make_arrow(self):
        head = Polygon(
            [0.5, 0, 0], [-0.25, 0.3, 0], [-0.25, -0.3, 0],
            fill_color=TEAL, fill_opacity=0.85,
            stroke_color=TEAL, stroke_width=2,
        )
        lbl = Text("rg", font="JetBrains Mono", font_size=13,
                    color=BG, weight=BOLD)
        lbl.move_to(head.get_center() + LEFT * 0.07)
        return VGroup(head, lbl)

    def _junk_rect(self, text):
        w = min(len(text) * 0.055 + 0.3, 1.6)
        rect = RoundedRectangle(
            corner_radius=0.03, width=w, height=0.2,
            fill_color=GRY, fill_opacity=0.25,
            stroke_color=GRY, stroke_width=1,
        )
        lbl = Text(text, font="JetBrains Mono", font_size=7, color=GRY)
        lbl.move_to(rect)
        if lbl.width > rect.width - 0.04:
            lbl.scale_to_fit_width(rect.width - 0.04)
        return VGroup(rect, lbl)

    def _make_result(self):
        rect = RoundedRectangle(
            corner_radius=0.05, width=1.3, height=0.3,
            fill_color=GRN, fill_opacity=0.15,
            stroke_color=GRN, stroke_width=2,
        )
        lbl = Text("formData", font="JetBrains Mono", font_size=12, color=GRN)
        lbl.move_to(rect)
        return VGroup(rect, lbl)

    def _camera_x_for(self, arrow_x):
        return arrow_x + CAMERA_LEAD

    def _wall_scrape(self, mass):
        flash = Rectangle(
            width=0.6, height=WALL_TOP - WALL_BOT,
            fill_color=AMB, fill_opacity=0.25, stroke_width=0,
        ).move_to([NARROW_X + 1, 0, 0])
        self.add(flash)
        self.play(mass.animate.shift(UP * 0.2), flash.animate.set_opacity(0), run_time=0.12)
        self.play(mass.animate.shift(DOWN * 0.35), run_time=0.1)
        self.play(mass.animate.shift(UP * 0.15), run_time=0.08)
        self.remove(flash)
        sparks = VGroup(*[
            Circle(radius=0.03, fill_color=AMB, fill_opacity=0.8, stroke_width=0)
            .move_to(mass.get_center() + np.array([
                np.random.uniform(-0.5, 0.5),
                np.random.uniform(-0.3, 0.3), 0
            ]))
            for _ in range(6)
        ])
        self.add(sparks)
        self.play(
            *[s.animate.shift(
                np.array([np.random.uniform(-1, 1), np.random.uniform(-1, 1), 0])
            ).set_opacity(0) for s in sparks],
            run_time=0.3,
        )
        self.remove(sparks)

    def _door_strip(self, mass, arrow, token_val):
        junk_items = [m for m in mass.submobjects if m is not arrow]
        fall_anims = []
        for j in junk_items:
            dx = np.random.uniform(-1.5, 1.5)
            fall_anims.append(
                j.animate.shift(DOWN * 3.5 + RIGHT * dx).set_opacity(0)
            )
        self.play(*fall_anims, run_time=0.7, rate_func=rush_into)
        for j in junk_items:
            mass.remove(j)
            self.remove(j)
        self.play(token_val.animate.set_value(800), run_time=0.6, rate_func=rush_from)
        flash = Rectangle(
            width=0.8, height=WALL_TOP - WALL_BOT,
            fill_color=GRN, fill_opacity=0.2, stroke_width=0,
        ).move_to([DOOR_X, 0, 0])
        self.add(flash)
        self.play(flash.animate.set_opacity(0), run_time=0.4)
        self.remove(flash)
