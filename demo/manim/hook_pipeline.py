"""
Claude Warden - Hook Pipeline Animation
Manim Community v0.20.1

Scenes:
  1. HookPipeline - Data flowing through PreToolUse -> Execute -> PostToolUse
  2. TokenSavings - Before/after compression with counter
  3. ShieldLogo - Logo assembly from terminal characters

Render:
  manim render hook_pipeline.py HookPipeline -qh    # 1080p
  manim render hook_pipeline.py TokenSavings -qh
  manim render hook_pipeline.py ShieldLogo -qh
  manim render hook_pipeline.py -qh -a               # all scenes
"""

from manim import *
import numpy as np

# Warden palette
WARDEN_BG = "#0d1117"
WARDEN_GREEN = "#3fb950"
WARDEN_AMBER = "#d29922"
WARDEN_RED = "#f85149"
WARDEN_BLUE = "#58a6ff"
WARDEN_CYAN = "#39d353"
WARDEN_GRAY = "#8b949e"
WARDEN_TEXT = "#c9d1d9"
WARDEN_DIM = "#484f58"
WARDEN_SURFACE = "#161b22"


class HookPipeline(Scene):
    """Animate a tool call flowing through the warden hook lifecycle."""

    def construct(self):
        self.camera.background_color = WARDEN_BG

        # Title
        title = Text("claude-warden", font="JetBrains Mono", font_size=48, color=WARDEN_GREEN)
        subtitle = Text("hook lifecycle", font="JetBrains Mono", font_size=24, color=WARDEN_GRAY)
        subtitle.next_to(title, DOWN, buff=0.3)
        self.play(Write(title), run_time=0.8)
        self.play(FadeIn(subtitle, shift=UP * 0.2), run_time=0.5)
        self.wait(0.5)
        self.play(FadeOut(title), FadeOut(subtitle))

        # Pipeline stages
        stages = ["PreToolUse", "Execute", "PostToolUse"]
        stage_colors = [WARDEN_AMBER, WARDEN_BLUE, WARDEN_GREEN]

        boxes = VGroup()
        labels = VGroup()
        for i, (name, color) in enumerate(zip(stages, stage_colors)):
            box = RoundedRectangle(
                corner_radius=0.15, width=3, height=1.2,
                stroke_color=color, stroke_width=2,
                fill_color=WARDEN_SURFACE, fill_opacity=0.8
            )
            label = Text(name, font="JetBrains Mono", font_size=20, color=color)
            label.move_to(box)
            boxes.add(box)
            labels.add(label)

        boxes.arrange(RIGHT, buff=1.2)
        boxes.move_to(ORIGIN)
        for label, box in zip(labels, boxes):
            label.move_to(box)

        arrows = VGroup()
        for i in range(len(boxes) - 1):
            arrow = Arrow(
                boxes[i].get_right(), boxes[i + 1].get_left(),
                buff=0.15, stroke_width=2, color=WARDEN_DIM
            )
            arrows.add(arrow)

        self.play(
            *[Create(b) for b in boxes],
            *[Write(l) for l in labels],
            *[Create(a) for a in arrows],
            run_time=1.0
        )
        self.wait(0.3)

        # Incoming tool call
        tool_call = self._make_data_block("git clone ...", WARDEN_TEXT, width=2.5)
        tool_call.next_to(boxes[0], LEFT, buff=1.5)
        self.play(FadeIn(tool_call, shift=RIGHT * 0.5), run_time=0.5)

        # Move through PreToolUse - inject quiet flag
        self.play(tool_call.animate.move_to(boxes[0].get_center()), run_time=0.6)
        flash = boxes[0].copy().set_stroke(WARDEN_AMBER, width=6)
        self.play(Create(flash), run_time=0.2)

        inject_label = Text("+ inject -q", font="JetBrains Mono", font_size=16, color=WARDEN_AMBER)
        inject_label.next_to(boxes[0], UP, buff=0.3)
        self.play(Write(inject_label), run_time=0.4)

        modified_call = self._make_data_block("git clone -q ...", WARDEN_AMBER, width=2.5)
        modified_call.move_to(boxes[0].get_center())
        self.play(Transform(tool_call, modified_call), FadeOut(flash), run_time=0.4)
        self.wait(0.2)

        # Move through Execute
        self.play(tool_call.animate.move_to(boxes[1].get_center()), run_time=0.6)
        exec_flash = boxes[1].copy().set_stroke(WARDEN_BLUE, width=6)
        self.play(Create(exec_flash), FadeOut(exec_flash), run_time=0.4)

        # Output emerges (big)
        output_block = self._make_data_block(
            "Cloning into 'repo'...\nremote: Enumerating...\n"
            "remote: Counting objects...\nReceiving objects: 100%\n"
            "Resolving deltas: 100%\n[... 847 more lines ...]",
            WARDEN_RED, width=3.5, height=2.0
        )
        output_block.move_to(boxes[1].get_center())
        self.play(Transform(tool_call, output_block), run_time=0.5)

        # Move through PostToolUse - compress
        self.play(tool_call.animate.move_to(boxes[2].get_center()), run_time=0.6)
        post_flash = boxes[2].copy().set_stroke(WARDEN_GREEN, width=6)
        self.play(Create(post_flash), run_time=0.2)

        compress_label = Text(
            "truncate 20KB -> 200B", font="JetBrains Mono", font_size=16, color=WARDEN_GREEN
        )
        compress_label.next_to(boxes[2], UP, buff=0.3)
        self.play(Write(compress_label), run_time=0.4)

        compressed = self._make_data_block(
            "Cloned repo (847 lines)\n[warden: ran as git clone -q]",
            WARDEN_GREEN, width=2.5, height=0.8
        )
        compressed.move_to(boxes[2].get_center())
        self.play(Transform(tool_call, compressed), FadeOut(post_flash), run_time=0.5)

        # Token savings
        savings = Text("~4,200 tokens saved", font="JetBrains Mono", font_size=28, color=WARDEN_CYAN)
        savings.next_to(boxes, DOWN, buff=1.0)
        self.play(Write(savings), run_time=0.6)

        self.play(tool_call.animate.shift(RIGHT * 3), run_time=0.6)
        self.wait(1.0)

    def _make_data_block(self, text, color, width=2.5, height=1.0):
        rect = RoundedRectangle(
            corner_radius=0.1, width=width, height=height,
            stroke_color=color, stroke_width=1.5,
            fill_color=WARDEN_BG, fill_opacity=0.9
        )
        display = text if len(text) < 80 else text[:77] + "..."
        label = Text(display, font="JetBrains Mono", font_size=12, color=color).move_to(rect)
        if label.width > rect.width - 0.3:
            label.scale_to_fit_width(rect.width - 0.3)
        if label.height > rect.height - 0.2:
            label.scale_to_fit_height(rect.height - 0.2)
        return VGroup(rect, label)


class TokenSavings(Scene):
    """Before/after token comparison with animated counter."""

    def construct(self):
        self.camera.background_color = WARDEN_BG

        divider = Line(UP * 3, DOWN * 3, stroke_width=1, color=WARDEN_DIM)
        self.add(divider)

        left_title = Text("without", font="JetBrains Mono", font_size=24, color=WARDEN_RED)
        left_title.move_to(LEFT * 3.5 + UP * 2.8)

        spam_text = [
            "npm warn deprecated @babel/plugin@7.x",
            "npm warn deprecated source-map-url@0.x",
            "npm warn deprecated urix@0.1.0",
            "npm warn deprecated resolve-url@0.2",
            "npm warn deprecated chokidar@2.1.8",
            "npm warn deprecated fsevents@1.2.13",
            "npm warn deprecated querystring@0.2",
            "added 1,247 packages in 45s",
            "npm warn deprecated uuid@3.4.0",
            "npm warn deprecated request@2.88",
            "npm warn deprecated har-validator@5",
            "npm warn deprecated tough-cookie@2.5",
        ]
        left_lines = VGroup()
        for i, txt in enumerate(spam_text):
            line = Text(txt, font="JetBrains Mono", font_size=10, color=WARDEN_RED)
            line.move_to(LEFT * 3.5 + UP * (2.0 - i * 0.35))
            left_lines.add(line)

        right_title = Text("with warden", font="JetBrains Mono", font_size=24, color=WARDEN_GREEN)
        right_title.move_to(RIGHT * 3.5 + UP * 2.8)

        clean_text = [
            ("added 1,247 packages in 45s", WARDEN_GREEN),
            ("", WARDEN_DIM),
            ("[warden: ran with --silent]", WARDEN_AMBER),
        ]
        right_lines = VGroup()
        for i, (txt, color) in enumerate(clean_text):
            line = Text(txt, font="JetBrains Mono", font_size=14, color=color)
            line.move_to(RIGHT * 3.5 + UP * (2.0 - i * 0.5))
            right_lines.add(line)

        self.play(Write(left_title), Write(right_title), run_time=0.5)

        for line in left_lines:
            self.play(FadeIn(line, shift=UP * 0.1), run_time=0.12)

        more = Text("... 1,235 more lines ...", font="JetBrains Mono", font_size=10, color=WARDEN_DIM)
        more.move_to(LEFT * 3.5 + DOWN * 2.0)
        self.play(FadeIn(more), run_time=0.3)
        self.wait(0.3)

        for line in right_lines:
            self.play(FadeIn(line, shift=UP * 0.1), run_time=0.25)
        self.wait(0.5)

        left_tokens = Text("~31,000 tokens", font="JetBrains Mono", font_size=18, color=WARDEN_RED)
        left_tokens.move_to(LEFT * 3.5 + DOWN * 3.0)
        right_tokens = Text("~120 tokens", font="JetBrains Mono", font_size=18, color=WARDEN_GREEN)
        right_tokens.move_to(RIGHT * 3.5 + DOWN * 3.0)

        self.play(Write(left_tokens), Write(right_tokens), run_time=0.5)

        savings = Text("99.6% reduction", font="JetBrains Mono", font_size=32, color=WARDEN_CYAN)
        savings.move_to(DOWN * 3.0)
        self.play(Write(savings), run_time=0.6)
        self.wait(1.5)


class ShieldLogo(Scene):
    """Warden shield logo assembling from terminal characters."""

    def construct(self):
        self.camera.background_color = WARDEN_BG

        shield_chars = [
            "  \u2554\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2557  ",
            " \u2551  \u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591 \u2551 ",
            " \u2551  \u2591 \u2588\u2588\u2588\u2588 \u2591 \u2551 ",
            " \u2551  \u2591 \u2588  \u2588 \u2591 \u2551 ",
            " \u2551  \u2591 \u2588  \u2588 \u2591 \u2551 ",
            "  \u2551 \u2591 \u2588\u2588\u2588\u2588 \u2591\u2551  ",
            "   \u2551 \u2591\u2591\u2591\u2591\u2591 \u2551   ",
            "    \u2551 \u2591\u2591\u2591 \u2551    ",
            "     \u2551 \u2591 \u2551     ",
            "      \u255a\u2550\u255d      ",
        ]

        shield_text = VGroup()
        for i, line in enumerate(shield_chars):
            t = Text(line, font="JetBrains Mono", font_size=20, color=WARDEN_GREEN)
            t.move_to(UP * (2.0 - i * 0.45))
            shield_text.add(t)

        # Scatter randomly
        original_positions = [t.get_center().copy() for t in shield_text]
        for t in shield_text:
            t.move_to([
                np.random.uniform(-6, 6),
                np.random.uniform(-4, 4),
                0
            ])
            t.set_opacity(0.3)

        self.add(*shield_text)
        self.wait(0.3)

        # Assemble
        anims = []
        for t, pos in zip(shield_text, original_positions):
            anims.append(t.animate.move_to(pos).set_opacity(1.0))
        self.play(*anims, run_time=1.5, rate_func=smooth)
        self.wait(0.3)

        title = Text("claude-warden", font="JetBrains Mono", font_size=36, color=WARDEN_GREEN)
        title.next_to(shield_text, DOWN, buff=0.6)
        version = Text("v1.0", font="JetBrains Mono", font_size=20, color=WARDEN_AMBER)
        version.next_to(title, DOWN, buff=0.2)

        self.play(Write(title), run_time=0.6)
        self.play(FadeIn(version, shift=UP * 0.2), run_time=0.4)

        # Glow pulse
        glow = shield_text.copy().set_stroke(WARDEN_CYAN, width=3, opacity=0.5)
        self.play(Create(glow), run_time=0.4)
        self.play(FadeOut(glow), run_time=0.6)
        self.wait(1.5)
