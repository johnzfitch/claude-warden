"""
Claude Warden — Life of a Hook
Manim Community v0.20.1

One hook, birth to death. No text walls. Shapes and color tell the story.

Render:
  manim render life_of_a_hook.py LifeOfAHook -qh         # 1080p
  manim render life_of_a_hook.py LifeOfAHook -qk         # 4K
  manim render life_of_a_hook.py LifeOfAHook -ql          # 480p preview
"""

from manim import *
import numpy as np

# Palette
BG = "#0d1117"
SURFACE = "#161b22"
GREEN = "#3fb950"
AMBER = "#d29922"
RED = "#f85149"
BLUE = "#58a6ff"
CYAN = "#39d353"
GRAY = "#8b949e"
DIM = "#484f58"
TEXT_COLOR = "#c9d1d9"
TERMINAL_BAR = "#2d333b"
DOT_RED = "#ff5f57"
DOT_YELLOW = "#febc2e"
DOT_GREEN = "#28c840"
SALMON = "#d08770"


class TerminalFrame(VGroup):
    """macOS-style terminal window chrome."""

    def __init__(self, width=12, height=7, **kwargs):
        super().__init__(**kwargs)

        # Window body
        body = RoundedRectangle(
            corner_radius=0.2, width=width, height=height,
            stroke_color=DIM, stroke_width=1.5,
            fill_color=BG, fill_opacity=1.0
        )

        # Title bar
        bar = Rectangle(
            width=width - 0.05, height=0.5,
            stroke_width=0, fill_color=TERMINAL_BAR, fill_opacity=1.0
        )
        bar.move_to(body.get_top() - DOWN * 0.25)

        # Traffic light dots
        dots = VGroup()
        for i, color in enumerate([DOT_RED, DOT_YELLOW, DOT_GREEN]):
            dot = Circle(radius=0.08, fill_color=color, fill_opacity=1.0, stroke_width=0)
            dot.move_to(bar.get_left() + RIGHT * (0.4 + i * 0.3))
            dots.add(dot)

        self.add(body, bar, dots)
        self.body = body
        self.bar = bar
        self.content_center = body.get_center() + DOWN * 0.2


class HookShape(VGroup):
    """A hook — shaped like a puzzle piece / key that fits a slot."""

    def __init__(self, color=AMBER, label_text="", **kwargs):
        super().__init__(**kwargs)

        # Main body — rounded rectangle with a notch on the right side
        body = RoundedRectangle(
            corner_radius=0.12, width=1.6, height=0.9,
            stroke_color=color, stroke_width=2.5,
            fill_color=color, fill_opacity=0.15
        )

        # Notch tab on right (the "key" part)
        tab = RoundedRectangle(
            corner_radius=0.06, width=0.35, height=0.35,
            stroke_color=color, stroke_width=2.5,
            fill_color=color, fill_opacity=0.25
        )
        tab.next_to(body, RIGHT, buff=-0.05)

        self.add(body, tab)
        self.body_rect = body
        self.tab = tab
        self.color = color

        if label_text:
            label = Text(label_text, font="JetBrains Mono", font_size=14, color=color)
            label.move_to(body)
            if label.width > body.width - 0.2:
                label.scale_to_fit_width(body.width - 0.2)
            self.add(label)


class SlotShape(VGroup):
    """A slot that a hook fits into — the matcher."""

    def __init__(self, color=DIM, **kwargs):
        super().__init__(**kwargs)

        # Outline matching hook shape but as a cutout
        body = RoundedRectangle(
            corner_radius=0.12, width=1.7, height=1.0,
            stroke_color=color, stroke_width=2,
            stroke_opacity=0.6,
            fill_color=BG, fill_opacity=0.5
        )

        # Tab cutout
        tab = RoundedRectangle(
            corner_radius=0.06, width=0.4, height=0.4,
            stroke_color=color, stroke_width=2,
            stroke_opacity=0.6,
            fill_color=BG, fill_opacity=0.5
        )
        tab.next_to(body, RIGHT, buff=-0.08)

        # Dashed border effect
        body.set_stroke(opacity=0.4)
        tab.set_stroke(opacity=0.4)

        self.add(body, tab)


class LifeOfAHook(Scene):
    """The complete lifecycle of a single hook call."""

    def construct(self):
        self.camera.background_color = BG

        # === TERMINAL FRAME (persistent stage) ===
        terminal = TerminalFrame(width=13, height=7.5)
        terminal.move_to(ORIGIN)
        self.play(FadeIn(terminal, scale=0.95), run_time=0.6)
        self.wait(0.3)

        # === ACT 1: EVENT FIRES ===
        # A pulse ripples out from center
        event_dot = Circle(
            radius=0.15, fill_color=BLUE, fill_opacity=1.0, stroke_width=0
        )
        event_dot.move_to(terminal.content_center + UP * 2)

        event_label = Text("event", font="Graphik", font_size=20, color=BLUE)
        event_label.next_to(event_dot, UP, buff=0.2)

        self.play(GrowFromCenter(event_dot), FadeIn(event_label, shift=DOWN * 0.1), run_time=0.4)

        # Ripple
        for i in range(2):
            ripple = Circle(radius=0.15, stroke_color=BLUE, stroke_width=2, fill_opacity=0)
            ripple.move_to(event_dot)
            self.play(
                ripple.animate.scale(4).set_stroke(opacity=0),
                run_time=0.5,
                rate_func=linear
            )
            self.remove(ripple)

        # === ACT 2: NO MATCH (hook flops gray) ===
        # Slot appears
        slot = SlotShape(color=GREEN)
        slot.move_to(terminal.content_center + LEFT * 2.5)

        self.play(FadeIn(slot, shift=UP * 0.3), run_time=0.4)

        # Wrong-shaped hook tries to fit
        wrong_hook = HookShape(color=RED)
        wrong_hook.move_to(terminal.content_center + UP * 2 + LEFT * 2.5)
        wrong_hook.scale(0.7)  # Wrong size

        self.play(FadeIn(wrong_hook, shift=DOWN * 0.3), run_time=0.3)

        # Try to fit — bounce off
        self.play(wrong_hook.animate.move_to(slot.get_center()), run_time=0.4)
        # Bounce back
        self.play(
            wrong_hook.animate.shift(UP * 0.8).set_opacity(0.2),
            Flash(slot.get_center(), color=RED, line_length=0.3, num_lines=8, run_time=0.3),
            run_time=0.5
        )

        # Gray out
        self.play(
            wrong_hook.animate.set_color(GRAY).set_opacity(0.15),
            run_time=0.3
        )

        # "no match" micro-label
        no_match = Text("no match", font="Graphik", font_size=14, color=GRAY)
        no_match.next_to(wrong_hook, RIGHT, buff=0.2)
        self.play(FadeIn(no_match), run_time=0.2)
        self.wait(0.4)

        # Fade out the miss
        self.play(
            FadeOut(wrong_hook), FadeOut(no_match),
            run_time=0.3
        )

        # === ACT 3: MATCH — slides into slot, lights up ===
        right_hook = HookShape(color=AMBER)
        right_hook.move_to(terminal.content_center + UP * 2 + LEFT * 2.5)

        self.play(FadeIn(right_hook, shift=DOWN * 0.2), run_time=0.3)

        # Slide into slot — perfect fit
        self.play(
            right_hook.animate.move_to(slot.get_center()),
            run_time=0.6,
            rate_func=rush_into
        )

        # Lock in — flash green
        self.play(
            Flash(slot.get_center(), color=GREEN, line_length=0.4, num_lines=12, run_time=0.4),
            right_hook.animate.set_color(GREEN).set_opacity(1.0),
            slot.animate.set_stroke(GREEN, width=3, opacity=1.0),
            run_time=0.4
        )

        # Merge hook+slot
        matched = VGroup(right_hook, slot)

        self.wait(0.3)

        # Clean up event dot
        self.play(FadeOut(event_dot), FadeOut(event_label), run_time=0.2)

        # === ACT 4: EXECUTION — data streams out ===
        # Move matched hook to center-left
        self.play(matched.animate.move_to(terminal.content_center + LEFT * 3.5), run_time=0.4)

        # Data particles streaming right
        particles = VGroup()
        particle_targets = []
        for i in range(15):
            p = Circle(
                radius=np.random.uniform(0.03, 0.08),
                fill_color=GREEN if i % 3 != 0 else CYAN,
                fill_opacity=0.8,
                stroke_width=0
            )
            p.move_to(matched.get_right() + RIGHT * 0.2)
            y_offset = np.random.uniform(-0.8, 0.8)
            target = matched.get_right() + RIGHT * (2 + np.random.uniform(0, 3)) + UP * y_offset
            particles.add(p)
            particle_targets.append(target)

        # Stream particles out
        self.add(*particles)
        anims = []
        for p, t in zip(particles, particle_targets):
            anims.append(p.animate.move_to(t).set_opacity(0.3))
        self.play(*anims, run_time=1.0, rate_func=rush_from)

        # === Build outputs from the data stream ===

        # Bar chart (metrics/observability)
        bars = VGroup()
        bar_heights = [0.6, 1.0, 0.8, 1.3, 0.5, 0.9]
        for i, h in enumerate(bar_heights):
            bar = Rectangle(
                width=0.2, height=h,
                fill_color=CYAN, fill_opacity=0.7,
                stroke_width=0
            )
            bar.move_to(
                terminal.content_center + RIGHT * (0.5 + i * 0.35) + UP * (h / 2 - 0.5)
            )
            bars.add(bar)

        self.play(
            *[GrowFromEdge(bar, DOWN) for bar in bars],
            FadeOut(particles),
            run_time=0.6
        )

        # Shield icon (security pass)
        shield = VGroup()
        shield_body = Polygon(
            [-0.4, 0.5, 0], [0.4, 0.5, 0],
            [0.4, -0.1, 0], [0, -0.5, 0], [-0.4, -0.1, 0],
            fill_color=GREEN, fill_opacity=0.3,
            stroke_color=GREEN, stroke_width=2
        )
        check = VGroup(
            Line([-0.15, 0, 0], [0, -0.15, 0], stroke_color=GREEN, stroke_width=3),
            Line([0, -0.15, 0], [0.2, 0.15, 0], stroke_color=GREEN, stroke_width=3),
        )
        shield.add(shield_body, check)
        shield.scale(0.6)
        shield.move_to(terminal.content_center + RIGHT * 3.5 + UP * 1)

        self.play(GrowFromCenter(shield), run_time=0.4)

        # Code lines (being written)
        code_lines = VGroup()
        line_widths = [2.0, 1.5, 2.3, 1.2, 1.8]
        for i, w in enumerate(line_widths):
            line = Rectangle(
                width=w, height=0.08,
                fill_color=AMBER, fill_opacity=0.5,
                stroke_width=0
            )
            line.move_to(
                terminal.content_center + RIGHT * 3 + DOWN * (0.8 + i * 0.25)
                + LEFT * ((2.3 - w) / 2)
            )
            code_lines.add(line)

        for line in code_lines:
            self.play(
                GrowFromEdge(line, LEFT),
                run_time=0.12
            )

        self.wait(0.5)

        # === ACT 5: RESULT FLOWS BACK ===
        # Everything converges into an output block
        result_rect = RoundedRectangle(
            corner_radius=0.15, width=3, height=1.2,
            stroke_color=GREEN, stroke_width=2,
            fill_color=SURFACE, fill_opacity=0.9
        )
        result_rect.move_to(terminal.content_center + DOWN * 2.5)

        exit_label = Text("exit 0", font="JetBrains Mono", font_size=18, color=GREEN)
        exit_label.move_to(result_rect)

        # Converge all outputs to result
        self.play(
            bars.animate.scale(0.1).move_to(result_rect.get_center()),
            shield.animate.scale(0.1).move_to(result_rect.get_center()),
            code_lines.animate.scale(0.1).move_to(result_rect.get_center()),
            FadeIn(result_rect),
            Write(exit_label),
            run_time=0.8
        )
        self.play(
            FadeOut(bars), FadeOut(shield), FadeOut(code_lines),
            run_time=0.2
        )

        # Arrow back to conversation
        arrow = Arrow(
            result_rect.get_right(),
            terminal.content_center + RIGHT * 5 + DOWN * 2.5,
            buff=0.1, stroke_width=2, color=GREEN
        )
        conv_label = Text("conversation", font="Graphik", font_size=16, color=TEXT_COLOR)
        conv_label.next_to(arrow, RIGHT, buff=0.2)

        self.play(Create(arrow), FadeIn(conv_label), run_time=0.4)

        self.wait(0.3)

        # === FINALE: warden title ===
        self.play(
            FadeOut(matched), FadeOut(slot),
            FadeOut(result_rect), FadeOut(exit_label),
            FadeOut(arrow), FadeOut(conv_label),
            run_time=0.5
        )

        title = Text("claude-warden", font="Graphik", font_size=52, color=GREEN)
        title.move_to(terminal.content_center)
        self.play(Write(title), run_time=0.8)
        self.wait(1.0)
