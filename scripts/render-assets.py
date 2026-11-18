#!/usr/bin/env python3
"""Generate BeanBridge SVG brand, dark/light adaptive diagrams, badges, and interactive demo figures.

SVGs use only inline vector shapes, CSS animations, and system fonts (zero external network requests,
and zero OS-dependent emoji glyphs so text renders identically across macOS, Windows, Linux, and mobile).
Add --png when CairoSVG is installed.
"""
from pathlib import Path
from html import escape
import argparse

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/assets"
BADGES_OUT = OUT / "badges"

FOREST = "#12372D"
DEEP_FOREST = "#0A1F19"
LIME = "#C6F38A"
CREAM = "#F6FAF0"

FONT_STACK = '-apple-system,BlinkMacSystemFont,"SF Pro Display","Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",Helvetica,Arial,sans-serif'
MONO_STACK = '"SF Mono",Menlo,Monaco,Consolas,"Liberation Mono",monospace'


def palette(dark: bool):
    if dark:
        return {
            "canvas": "#0B1613",
            "canvas_stroke": "#1E3B31",
            "surface": "#11231E",
            "surface_alt": "#152C25",
            "surface_elev": "#18332B",
            "border": "#25493D",
            "border_soft": "#1C382F",
            "ink": "#F3F8F2",
            "ink_sub": "#9BB8A8",
            "ink_muted": "#6D8E7D",
            "accent": "#C6F38A",
            "accent_ink": "#0B241C",
            "accent_bg": "#1B3B2B",
            "accent_border": "#3F6E50",
            "teal": "#5EEAD4",
            "teal_bg": "#12322F",
            "teal_border": "#265953",
            "amber": "#FBBF24",
            "amber_bg": "#2B2413",
            "amber_border": "#684F1D",
            "win_bg": "#12241F",
            "win_hdr": "#183029",
            "ctrl_bg": "#1B362E",
            "shadow_opacity": "0.42",
        }
    return {
        "canvas": "#F6FAF3",
        "canvas_stroke": "#D5E4CF",
        "surface": "#FFFFFF",
        "surface_alt": "#EEF6E8",
        "surface_elev": "#F9FCF7",
        "border": "#CFE0C8",
        "border_soft": "#E2EDE0",
        "ink": "#0F2921",
        "ink_sub": "#466356",
        "ink_muted": "#6E887B",
        "accent": "#12372D",
        "accent_ink": "#C6F38A",
        "accent_bg": "#E5F5D3",
        "accent_border": "#A8D582",
        "teal": "#0F766E",
        "teal_bg": "#E6F7F5",
        "teal_border": "#99E2DA",
        "amber": "#B45309",
        "amber_bg": "#FEF5E7",
        "amber_border": "#F5CBA7",
        "win_bg": "#FFFFFF",
        "win_hdr": "#F1F6EE",
        "ctrl_bg": "#EDF3EA",
        "shadow_opacity": "0.08",
    }


def begin(width, height, title, bg=None, stroke=None, rx=24, extra_style=""):
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)}">',
        f"<title>{escape(title)}</title>",
        f"<style>"
        f"text{{font-family:{FONT_STACK}}} "
        f".mono{{font-family:{MONO_STACK}}} "
        f"{extra_style}"
        f"</style>",
    ]
    if bg:
        stroke_attr = f' stroke="{stroke}" stroke-width="1.5"' if stroke else ""
        lines.append(
            f'<rect x="0.75" y="0.75" width="{width - 1.5}" height="{height - 1.5}" '
            f'rx="{rx}" fill="{bg}"{stroke_attr}/>'
        )
    return lines


def add_shadow_defs(lines, shadow_opacity="0.12"):
    lines.append(
        f'<defs>'
        f'<filter id="cardShadow" x="-8%" y="-8%" width="116%" height="120%">'
        f'<feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#04110D" flood-opacity="{shadow_opacity}"/>'
        f'</filter>'
        f'<linearGradient id="beanGrad" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0%" stop-color="#285948"/>'
        f'<stop offset="55%" stop-color="#14382D"/>'
        f'<stop offset="100%" stop-color="#0A1F19"/>'
        f'</linearGradient>'
        f'<linearGradient id="metalRim" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0%" stop-color="#D7E2DC"/>'
        f'<stop offset="50%" stop-color="#7C9087"/>'
        f'<stop offset="100%" stop-color="#C8D6CE"/>'
        f'</linearGradient>'
        f'</defs>'
    )


def text(lines, x, y, value, size=16, color=FOREST, weight=400, anchor="start", extra=""):
    lines.append(
        f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" '
        f'font-weight="{weight}" text-anchor="{anchor}" {extra}>{escape(value)}</text>'
    )


def pill(lines, x, y, w, h, label, bg, fg, border=None, size=11.5, weight=600, mono=False, rx=None, dot_color=None):
    r = rx if rx is not None else h / 2
    b_attr = f' stroke="{border}" stroke-width="1"' if border else ""
    lines.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{bg}"{b_attr}/>')
    cls = 'class="mono"' if mono else ""
    if dot_color:
        lines.append(f'<circle cx="{x + 14}" cy="{y + h / 2}" r="3.5" fill="{dot_color}"/>')
        text(lines, x + (w + 12) / 2, y + h / 2 + size * 0.36, label, size, fg, weight, "middle", cls)
    else:
        text(lines, x + w / 2, y + h / 2 + size * 0.36, label, size, fg, weight, "middle", cls)


def mini_lock(lines, cx, cy, color):
    lines.append(f'<rect x="{cx-5}" y="{cy-1}" width="10" height="7.5" rx="1.8" fill="none" stroke="{color}" stroke-width="1.6"/>')
    lines.append(f'<path d="M{cx-3} {cy-1}V{cy-3.5}A3 3 0 0 1 {cx+3} {cy-3.5}V{cy-1}" fill="none" stroke="{color}" stroke-width="1.6"/>')


def mini_shield(lines, cx, cy, color):
    lines.append(
        f'<path d="M{cx} {cy-6}L{cx+5.5} {cy-3.8}V{cy+0.5}C{cx+5.5} {cy+3.8} {cx+3} {cy+5.8} {cx} {cy+6.8}'
        f'C{cx-3} {cy+5.8} {cx-5.5} {cy+3.8} {cx-5.5} {cy+0.5}V{cy-3.8}Z" '
        f'fill="none" stroke="{color}" stroke-width="1.6" stroke-linejoin="round"/>'
    )


def mark(lines, x, y, size, tile=True):
    lines.append(f'<g transform="translate({x} {y}) scale({size/256:.5f})">')
    if tile:
        lines.append(f'<rect width="256" height="256" rx="62" fill="{FOREST}"/>')
    lines.append(
        f'<path d="M141 39C102 25 58 49 43 85C27 124 41 169 74 194C100 214 133 215 155 195'
        f'C177 175 159 151 169 132C178 115 205 114 210 91C215 67 181 51 141 39Z" fill="{LIME}"/>'
    )
    lines.append(
        f'<path d="M139 56C100 74 96 105 116 130C133 153 128 178 104 190" '
        f'fill="none" stroke="{FOREST}" stroke-width="15" stroke-linecap="round"/>'
    )
    lines.append(
        f'<path d="M174 156V175M194 143V186M214 157V173" '
        f'fill="none" stroke="{LIME}" stroke-width="10" stroke-linecap="round"/>'
    )
    lines.append("</g>")


def save(name, lines, folder=OUT):
    lines.append("</svg>")
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{name}.svg").write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# 1. Logo & Branded Pill Badges
# ---------------------------------------------------------------------------

def logo():
    lines = begin(256, 256, "BeanBridge logo: a bean and an audio waveform")
    mark(lines, 0, 0, 256)
    save("logo", lines)


def make_badge(filename, left_label, right_label, w1, w2, accent=LIME):
    total_w = w1 + w2
    h = 28
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{total_w}" height="{h}" '
        f'viewBox="0 0 {total_w} {h}" role="img" aria-label="{escape(left_label + ": " + right_label)}">',
        f"<title>{escape(left_label + ': ' + right_label)}</title>",
        f'<style>text{{font-family:{FONT_STACK}}} .mono{{font-family:{MONO_STACK}}}</style>',
        f'<defs><clipPath id="r"><rect width="{total_w}" height="{h}" rx="14"/></clipPath></defs>',
        f'<g clip-path="url(#r)">',
        f'<rect width="{w1}" height="{h}" fill="#0C221B"/>',
        f'<rect x="{w1}" width="{w2}" height="{h}" fill="#15382D"/>',
        f'</g>',
        f'<rect x="0.5" y="0.5" width="{total_w - 1}" height="{h - 1}" rx="13.5" fill="none" stroke="#2E5C4B"/>',
        f'<circle cx="14" cy="14" r="3.5" fill="{accent}"/>',
    ]
    text(lines, 24, 18, left_label, 10.5, "#A7C7B5", 700, "start", 'class="mono" letter-spacing="0.8"')
    text(lines, w1 + w2 / 2, 18, right_label, 11.5, CREAM, 600, "middle")
    save(filename, lines, folder=BADGES_OUT)


def badges():
    spec = [
        ("platform", "PLATFORM", "macOS 14+ · Apple Silicon", 92, 170),
        ("swift", "NATIVE", "Swift 5.10 · AppKit", 76, 136),
        ("whisper", "LOCAL ASR", "whisper.cpp · Zero FFmpeg", 96, 176),
        ("targets", "TARGETS", "Codex · Doubao · Paseo", 84, 166),
        ("tests", "VERIFIED", "49 Swift + 16 Python Tests", 88, 174),
        ("license", "LICENSE", "Apache-2.0", 82, 92),
    ]
    for fname, l_txt, r_txt, w1, w2 in spec:
        make_badge(fname, l_txt, r_txt, w1, w2)


# ---------------------------------------------------------------------------
# 2. Vector Banner (Fallback / SVG Source)
# ---------------------------------------------------------------------------

def banner(name="banner", width=1600, height=560):
    lines = begin(width, height, "BeanBridge — Press. Speak. Route Safely.")
    scale = width / 1600
    offset = (height - 560 * scale) / 2
    lines.append(
        '<defs>'
        '<radialGradient id="bgGlow" cx="76%" cy="46%" r="52%">'
        '<stop offset="0%" stop-color="#1E4E3E"/>'
        '<stop offset="55%" stop-color="#102E25"/>'
        '<stop offset="100%" stop-color="#081A14"/>'
        '</radialGradient>'
        '<linearGradient id="discFace" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0%" stop-color="#2D5E4C"/>'
        '<stop offset="50%" stop-color="#173B2F"/>'
        '<stop offset="100%" stop-color="#0B211A"/>'
        '</linearGradient>'
        '<linearGradient id="tiBezel" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0%" stop-color="#DCE5E0"/>'
        '<stop offset="48%" stop-color="#798D84"/>'
        '<stop offset="100%" stop-color="#C9D6CF"/>'
        '</linearGradient>'
        '</defs>'
    )
    lines.append(f'<rect width="{width}" height="{height}" rx="26" fill="url(#bgGlow)"/>')
    lines.append(f'<g transform="translate(0 {offset}) scale({scale:.5f})">')
    for r in [165, 215, 268, 324]:
        lines.append(
            f'<circle cx="1230" cy="250" r="{r}" fill="none" stroke="{LIME}" '
            f'stroke-opacity="{max(0.06, 0.28 - (r-165)*0.0012):.2f}" stroke-width="1.5"/>'
        )
    mark(lines, 68, 52, 52)
    text(lines, 136, 84, "BEANBRIDGE  ·  MACOS NATIVE VOICE BRIDGE", 15, "#B8D8C3", 600, extra='class="mono" letter-spacing="2"')
    text(lines, 68, 198, "BeanBridge", 92, CREAM, 700, extra='letter-spacing="-3"')
    text(lines, 588, 194, "豆桥", 40, "#CDE2D4", 600)
    text(lines, 72, 256, "Press. Speak. Route Safely.", 36, LIME, 600, extra='letter-spacing="-0.6"')
    text(
        lines, 72, 304,
        "Anker D3200 BLE button, zero-FFmpeg local whisper.cpp & fail-closed routing to Codex, Doubao, and Paseo.",
        19.5, "#C3DDD0",
    )
    lines.append('<ellipse cx="1236" cy="276" rx="146" ry="132" fill="#04110D" opacity="0.65"/>')
    lines.append('<circle cx="1230" cy="246" r="134" fill="url(#tiBezel)"/>')
    lines.append('<circle cx="1230" cy="246" r="118" fill="url(#discFace)" stroke="#3B6E5B" stroke-width="1.5"/>')
    mark(lines, 1146, 162, 168, False)
    lines.append(f'<circle cx="1320" cy="322" r="7.5" fill="{LIME}"/>')
    lines.append('<rect x="68" y="362" width="760" height="132" rx="18" fill="#0D271F" fill-opacity="0.88" stroke="#45785D" stroke-width="1.4"/>')
    lines.append(f'<circle cx="96" cy="396" r="5" fill="{LIME}"/>')
    text(lines, 112, 401, "LOCKED ON FIRST PRESS  ·  IN-MEMORY WHISPER", 12.5, LIME, 700, extra='class="mono" letter-spacing="1"')
    for idx, lbl in enumerate(["Codex", "Doubao", "Paseo"]):
        pill(lines, 576 + idx * 78, 382, 72, 26, lbl, "#194033", "#E7F6DF", "#3E6E58", 11.5, 600)
    text(lines, 92, 454, "“Split multi-app safety routing into a clean PR with unit tests.”", 20, CREAM, 500)
    pill(lines, 678, 434, 128, 32, "Safe Routed", LIME, "#0B241C", None, 12.5, 700, rx=10)
    lines.append("</g>")
    save(name, lines)


# ---------------------------------------------------------------------------
# 3. Auto-Playing 12s Animated Live Workflow Scene (hero-demo.svg / hero-demo-en.svg)
# ---------------------------------------------------------------------------

def hero_demo(lang="zh"):
    zh = lang == "zh"
    name = "hero-demo" if zh else "hero-demo-en"
    title = (
        "BeanBridge 12 秒全链路动态演示：短按锁定 -> 内存实时预览（切屏防串台）-> 再按精准投递"
        if zh
        else "BeanBridge 12s live workflow demo: Press to lock -> Live in-memory ASR -> Press to route safely"
    )
    anim_css = """
      @keyframes pulseRing {
        0%, 100% { r: 64px; opacity: 0; }
        4% { r: 66px; opacity: 0.9; }
        16% { r: 96px; opacity: 0; }
        58% { r: 64px; opacity: 0; }
        62% { r: 66px; opacity: 0.95; }
        74% { r: 98px; opacity: 0; }
      }
      @keyframes recDot {
        0%, 5% { fill: #C6F38A; }
        6%, 60% { fill: #EF4444; }
        61%, 100% { fill: #C6F38A; }
      }
      @keyframes waveA {
        0%, 6%, 62%, 100% { transform: scaleY(0.22); opacity: 0.35; }
        15%, 35%, 52% { transform: scaleY(1); opacity: 1; }
        25%, 44% { transform: scaleY(0.45); opacity: 0.85; }
      }
      @keyframes waveB {
        0%, 6%, 62%, 100% { transform: scaleY(0.25); opacity: 0.35; }
        12%, 30%, 48% { transform: scaleY(0.5); opacity: 0.85; }
        20%, 40%, 56% { transform: scaleY(1); opacity: 1; }
      }
      @keyframes line1Reveal {
        0%, 12% { opacity: 0; transform: translateY(4px); }
        18%, 92% { opacity: 1; transform: translateY(0); }
        97%, 100% { opacity: 0; }
      }
      @keyframes line2Reveal {
        0%, 28% { opacity: 0; transform: translateY(4px); }
        35%, 92% { opacity: 1; transform: translateY(0); }
        97%, 100% { opacity: 0; }
      }
      @keyframes driftGuard {
        0%, 34% { opacity: 0; }
        40%, 58% { opacity: 1; }
        64%, 100% { opacity: 0; }
      }
      @keyframes packetFly {
        0%, 61% { opacity: 0; transform: translateX(0px); }
        64% { opacity: 1; transform: translateX(6px); }
        72% { opacity: 1; transform: translateX(52px); }
        75%, 100% { opacity: 0; transform: translateX(64px); }
      }
      @keyframes chatBubble {
        0%, 68% { opacity: 0; transform: translateY(8px); }
        74%, 94% { opacity: 1; transform: translateY(0); }
        98%, 100% { opacity: 0; }
      }
      @keyframes aiReply {
        0%, 77% { opacity: 0; transform: translateY(8px); }
        83%, 94% { opacity: 1; transform: translateY(0); }
        98%, 100% { opacity: 0; }
      }
      @keyframes step1Hi {
        0%, 24% { stroke: #C6F38A; stroke-width: 1.8; }
        25%, 100% { stroke: #25493D; stroke-width: 1; }
      }
      @keyframes step2Hi {
        0%, 24% { stroke: #25493D; stroke-width: 1; }
        25%, 61% { stroke: #C6F38A; stroke-width: 1.8; }
        62%, 100% { stroke: #25493D; stroke-width: 1; }
      }
      @keyframes step3Hi {
        0%, 61% { stroke: #25493D; stroke-width: 1; }
        62%, 95% { stroke: #C6F38A; stroke-width: 1.8; }
        96%, 100% { stroke: #25493D; stroke-width: 1; }
      }
      .ring { animation: pulseRing 12s infinite ease-out; }
      .recdot { animation: recDot 12s infinite; }
      .wa { transform-box: fill-box; transform-origin: center; animation: waveA 12s infinite ease-in-out; }
      .wb { transform-box: fill-box; transform-origin: center; animation: waveB 12s infinite ease-in-out; }
      .l1 { animation: line1Reveal 12s infinite ease-out; }
      .l2 { animation: line2Reveal 12s infinite ease-out; }
      .guard { animation: driftGuard 12s infinite ease-in-out; }
      .pkt { animation: packetFly 12s infinite ease-in-out; }
      .msg { animation: chatBubble 12s infinite ease-out; }
      .reply { animation: aiReply 12s infinite ease-out; }
      .s1 { animation: step1Hi 12s infinite; }
      .s2 { animation: step2Hi 12s infinite; }
      .s3 { animation: step3Hi 12s infinite; }
      @media (prefers-reduced-motion: reduce) {
        .ring, .wa, .wb, .l1, .l2, .guard, .pkt, .msg, .reply, .s1, .s2, .s3 { animation: none !important; opacity: 1 !important; }
        .pkt { opacity: 0 !important; }
      }
    """
    lines = begin(1280, 510, title, "#0A1914", "#244A3D", 24, anim_css)
    add_shadow_defs(lines, "0.45")

    steps = (
        [
            ("01 · 短按实体键", "冻结前台唯一会话", "s1", 36),
            ("02 · 内存实时预览", "48k -> 16k · 切屏防串台", "s2", 446),
            ("03 · 再按安全投递", "0o600 回执 · 精准入队", "s3", 856),
        ]
        if zh
        else [
            ("01 · First Press", "Freeze foreground chat", "s1", 36),
            ("02 · Live RAM Preview", "48k -> 16k · Tab-switch proof", "s2", 446),
            ("03 · Press to Deliver", "0o600 receipt · Verified send", "s3", 856),
        ]
    )
    for st_num, st_desc, cls, sx in steps:
        lines.append(f'<rect class="{cls}" x="{sx}" y="24" width="388" height="44" rx="12" fill="#11261F" stroke="#25493D"/>')
        text(lines, sx + 18, 51, st_num, 13, LIME, 700, extra='class="mono"')
        text(lines, sx + 370, 51, st_desc, 12.5, "#B6D3C3", 500, "end")

    # Column 1: D3200 Hardware Pod
    lines.append('<rect x="36" y="88" width="264" height="390" rx="18" fill="#10231D" stroke="#214337" filter="url(#cardShadow)"/>')
    text(lines, 168, 122, "ANKER D3200 · BLE", 12, "#8FB2A0", 700, "middle", 'class="mono" letter-spacing="1.2"')
    text(lines, 168, 144, "固件 04.92 · 电量 92%" if zh else "FW 04.92 · Battery 92%", 12, "#678A78", 500, "middle")

    lines.append(f'<circle class="ring" cx="168" cy="248" r="66" fill="none" stroke="{LIME}" stroke-width="2.5"/>')
    lines.append('<circle cx="168" cy="248" r="66" fill="url(#metalRim)"/>')
    lines.append('<circle cx="168" cy="248" r="57" fill="url(#beanGrad)" stroke="#3B6E5B" stroke-width="1.2"/>')
    mark(lines, 126, 206, 84, False)
    lines.append('<circle class="recdot" cx="210" cy="288" r="5.5" fill="#C6F38A"/>')

    bar_heights = [18, 32, 46, 28, 50, 36, 20, 40, 24]
    for idx, bh in enumerate(bar_heights):
        bx = 104 + idx * 16
        by = 360 - bh / 2
        cls = "wa" if idx % 2 == 0 else "wb"
        lines.append(f'<rect class="{cls}" x="{bx}" y="{by:.1f}" width="6" height="{bh}" rx="3" fill="{LIME}"/>')

    hint_hw = "轻敲机身震动 -> 分叉新对话" if zh else "Tap body (04.92) -> Fork new chat"
    pill(lines, 56, 422, 224, 32, hint_hw, "#17332A", "#CBE8D6", "#2D5949", 11.5, 600, rx=10)

    lines.append('<path d="M304 282H338" stroke="#3E6E58" stroke-width="2" stroke-dasharray="4 4"/>')
    text(lines, 321, 272, "BLE", 10.5, LIME, 700, "middle", 'class="mono"')

    # Column 2: Menu Bar + Floating HUD
    lines.append('<rect x="342" y="88" width="416" height="36" rx="10" fill="#162E27" stroke="#25493D"/>')
    text(lines, 360, 111, "macOS Menu Bar", 11.5, "#83A594", 500)
    lines.append('<rect x="576" y="94" width="172" height="24" rx="6" fill="#0E201B" stroke="#2E594A"/>')
    lines.append('<circle class="recdot" cx="592" cy="106" r="4.5" fill="#C6F38A"/>')
    text(lines, 605, 110, "安克豆 · 92% · Small" if zh else "Bean · 92% · Small", 11, CREAM, 600)

    lines.append('<rect x="342" y="136" width="416" height="342" rx="16" fill="#122620" stroke="#2B5446" filter="url(#cardShadow)"/>')
    lines.append('<path d="M342 152Q342 136 358 136H742Q758 136 758 152V168H342Z" fill="#18322A"/>')
    for i, c in enumerate(["#EF4444", "#F59E0B", "#10B981"]):
        lines.append(f'<circle cx="{362 + i*14}" cy="152" r="4.5" fill="{c}"/>')
    text(lines, 550, 156, "安克豆语音 · Floating HUD" if zh else "BeanBridge Voice · Floating HUD", 12, "#D2E6DA", 600, "middle")

    text(lines, 364, 198, "正在聆听 · 纯内存 16kHz 预览" if zh else "Listening · In-Memory 16kHz Preview", 15, CREAM, 700)
    pill(lines, 364, 212, 134, 24, "目标: Paseo v" if zh else "Target: Paseo v", "#1B372E", "#E3F2E8", "#315D4E", 11.5, 600, rx=6)
    lines.append('<rect x="506" y="212" width="230" height="24" rx="6" fill="#1B3E2B" stroke="#3E7052"/>')
    mini_lock(lines, 524, 224, LIME)
    text(lines, 628, 228, "已锁定唯一前台会话" if zh else "Foreground Single Locked", 11.5, LIME, 700, "middle")

    lines.append('<rect x="364" y="250" width="372" height="156" rx="12" fill="#0C1B16" stroke="#214337"/>')
    text(lines, 382, 276, "锁定会话：Paseo · BeanBridge Workspace" if zh else "Locked: Paseo · BeanBridge Workspace", 12, LIME, 600)
    l1_txt = "“把多应用路由协议抽成独立模块，" if zh else "“Extract AppTargetAdapter into a clean module,"
    l2_txt = "  补齐防串台单测后直接提交 PR。”" if zh else "  and run all 65 routing safety tests.”"
    text(lines, 382, 314, l1_txt, 15, CREAM, 500, extra='class="l1"')
    text(lines, 382, 342, l2_txt, 15, CREAM, 500, extra='class="l2"')

    lines.append('<g class="guard">')
    lines.append('<rect x="382" y="366" width="336" height="26" rx="7" fill="#203A2B" stroke="#3E6E52"/>')
    mini_shield(lines, 398, 379, "#A7F3D0")
    text(
        lines, 558, 383,
        "检测到后台切屏 · 锁定不变（拒绝串发）" if zh else "Tab switch ignored · Target stays locked",
        11, "#A7F3D0", 600, "middle",
    )
    lines.append("</g>")

    hud_btns = (
        [("检测目标", 78), ("待发箱", 68), ("工作台", 74), ("辅助功能", 78), ("取消本条", 62)]
        if zh
        else [("Probe", 70), ("Pending", 74), ("Workbench", 86), ("AX Auth", 70), ("Cancel", 60)]
    )
    bx = 364
    for b_lbl, bw in hud_btns:
        is_cancel = b_lbl in ("取消本条", "Cancel")
        is_wb = b_lbl in ("工作台", "Workbench")
        bg = "#3A1D20" if is_cancel else (LIME if is_wb else "#1A352C")
        fg = "#FCA5A5" if is_cancel else ("#0B241C" if is_wb else "#CFE3D7")
        bd = "#7F2D33" if is_cancel else (None if is_wb else "#2B5345")
        pill(lines, bx, 424, bw, 30, b_lbl, bg, fg, bd, 11, 600, rx=7)
        bx += bw + 3

    lines.append('<path d="M762 282H818" stroke="#3E6E58" stroke-width="2" stroke-dasharray="4 4"/>')
    lines.append(f'<circle class="pkt" cx="764" cy="282" r="6" fill="{LIME}"/>')

    # Column 3: Target AI Desktop Client
    lines.append('<rect x="822" y="88" width="422" height="390" rx="16" fill="#10221C" stroke="#264C3F" filter="url(#cardShadow)"/>')
    lines.append('<path d="M822 104Q822 88 838 88H1228Q1244 88 1244 104V122H822Z" fill="#173028"/>')
    for i, c in enumerate(["#EF4444", "#F59E0B", "#10B981"]):
        lines.append(f'<circle cx="{842 + i*14}" cy="105" r="4.5" fill="{c}"/>')
    text(lines, 1033, 109, "Paseo · BeanBridge Workspace", 12, "#D2E6DA", 600, "middle")

    pill(lines, 840, 134, 198, 26, "BeanBridge Workspace", "#1D4234", LIME, "#3E7052", 11, 700, rx=7, dot_color=LIME)
    pill(lines, 1046, 134, 178, 26, "Other Scratch Tab", "#142A23", "#739584", "#214237", 11, 500, rx=7)

    lines.append('<rect x="842" y="176" width="382" height="58" rx="12" fill="#152C25" stroke="#22453A"/>')
    text(lines, 858, 198, "Agent · Ready", 11, "#7FA391", 600, extra='class="mono"')
    text(
        lines, 858, 219,
        "当前工作区已就绪，等待下一步重构指令。" if zh else "Workspace ready for your next refactoring prompt.",
        13, "#B8D3C4", 400,
    )

    lines.append('<g class="msg">')
    lines.append('<rect x="866" y="250" width="358" height="86" rx="14" fill="#1B4333" stroke="#4D8564" stroke-width="1.3"/>')
    lines.append(f'<circle cx="884" cy="270" r="4" fill="{LIME}"/>')
    text(lines, 896, 274, "BeanBridge Voice · Queued (0o600)", 11, LIME, 700, extra='class="mono"')
    text(
        lines, 884, 298,
        "把多应用路由协议抽成独立模块，补齐防串台" if zh else "Extract AppTargetAdapter into a clean module",
        13.5, CREAM, 500,
    )
    text(
        lines, 884, 319,
        "单测后直接提交 PR。" if zh else "and run all 65 routing safety tests.",
        13.5, CREAM, 500,
    )
    lines.append("</g>")

    lines.append('<g class="reply">')
    lines.append('<rect x="842" y="352" width="382" height="104" rx="14" fill="#0D1C17" stroke="#2A5445"/>')
    lines.append(f'<circle cx="860" cy="375" r="4.5" fill="{LIME}"/>')
    text(lines, 872, 379, "Paseo Agent · Streaming", 11.5, LIME, 700, extra='class="mono"')
    text(
        lines, 858, 405,
        "收到！已锁定当前工作区会话，正在拆分" if zh else "Got it! Locked onto BeanBridge Workspace—",
        13, "#E2EFE7", 500,
    )
    text(
        lines, 858, 427,
        "VoiceRouting 适配器并执行 49 Swift + 16 Python 测试…" if zh else "running 49 Swift + 16 Python routing tests now…",
        13, "#A9C8B7", 400,
    )
    lines.append("</g>")

    save(name, lines)


# ---------------------------------------------------------------------------
# 4. Apple-Style 3-Column Tactile Gestures Card (Dark + Light, ZH + EN)
# ---------------------------------------------------------------------------

def tactile_gestures(dark=False, lang="zh"):
    p = palette(dark)
    zh = lang == "zh"
    suffix = ("-en" if not zh else "") + ("-dark" if dark else "-light")
    title = "物理按键交互三定律" if zh else "Three Tactile Hardware Guarantees"
    lines = begin(1280, 416, title, p["canvas"], p["canvas_stroke"], 24)
    add_shadow_defs(lines, p["shadow_opacity"])

    hdr = "无需看键盘的三段式盲操交互" if zh else "Zero-Keyboard Tactile Interaction"
    sub = (
        "从按下第一秒起锁定去向；中途变卦可轻敲分叉；任何歧义一律安全兜底进待发箱。"
        if zh
        else "Target freezes on first press. Tap mid-speech to fork a clean chat. Ambiguity always fails closed."
    )
    text(lines, 44, 52, hdr, 26, p["ink"], 700, extra='letter-spacing="-0.5"')
    text(lines, 44, 80, sub, 15, p["ink_sub"], 400)
    pill(
        lines, 1052, 30, 184, 30,
        "D3200 · FW 04.92", p["accent_bg"], p["accent"], p["accent_border"], 11.5, 700, mono=True,
    )

    cards = (
        [
            (
                "01 · PRESS TO LOCK",
                "短按 · 首按即锁定",
                ("首次按下瞬间冻结前台唯一对话 ID；", "录音途中切标签、切应用绝不串台。"),
                ["Codex 双重深链一致性核验", "豆包过滤 25 字空框默认占位符", "Paseo 守护进程唯一非归档消歧"],
                "lock",
                p["accent"], p["accent_bg"], p["accent_border"],
            ),
            (
                "02 · TAP TO FORK (04.92)",
                "轻敲 · 震动改发新聊",
                ("说到一半不想发进当前旧话题？", "轻敲豆身至震动，自动改建独立新聊。"),
                ["硬件分片 flags=01 震动确认", "浮窗实时亮起「轻敲已确认」", "多次轻敲幂等保护，绝不重复建聊"],
                "fork",
                p["teal"], p["teal_bg"], p["teal_border"],
            ),
            (
                "03 · FAIL-CLOSED GUARD",
                "兜底 · 歧义零误发",
                ("遇分屏多窗、同名会话、失焦或未授权，", "绝不盲猜最近窗口，加密落盘待发箱。"),
                ["Pending/ 与回执均以 0o600 落盘", "支持随时点「取消本条」静默丢弃", "补绑链接或一键改发新聊零丢失"],
                "shield",
                p["amber"], p["amber_bg"], p["amber_border"],
            ),
        ]
        if zh
        else [
            (
                "01 · PRESS TO LOCK",
                "Short Press · Freeze Target",
                ("Captures your single foreground thread", "on first press—tab switches never drift."),
                ["Codex dual-copy UUID verification", "Doubao 25-char empty hint filter", "Paseo daemon unique tab matching"],
                "lock",
                p["accent"], p["accent_bg"], p["accent_border"],
            ),
            (
                "02 · TAP TO FORK (04.92)",
                "Tap Body · Vibration Fork",
                ("Changed your mind mid-thought? Tap the", "D3200 until vibration to spawn a clean chat."),
                ["Firmware 04.92 flags=01 marker", "HUD confirms tap-to-fork live", "Idempotent—extra taps never duplicate"],
                "fork",
                p["teal"], p["teal_bg"], p["teal_border"],
            ),
            (
                "03 · FAIL-CLOSED GUARD",
                "Ambiguity · Zero Misfire",
                ("Split panes, duplicate titles, or lost focus", "never guess—text locks safely in Pending."),
                ["0o600 disk permissions & receipts", "One-click mid-recording Cancel", "Recover or spawn clean chat anytime"],
                "shield",
                p["amber"], p["amber_bg"], p["amber_border"],
            ),
        ]
    )

    for idx, (eyebrow, ctitle, (d1, d2), bullets, icon, col, badge_bg, badge_bd) in enumerate(cards):
        cx = 44 + idx * 404
        cy = 106
        cw, ch = 384, 278
        lines.append(
            f'<rect x="{cx}" y="{cy}" width="{cw}" height="{ch}" rx="18" '
            f'fill="{p["surface"]}" stroke="{p["border"]}" stroke-width="1.3" filter="url(#cardShadow)"/>'
        )
        ix, iy = cx + cw - 64, cy + 20
        lines.append(f'<rect x="{ix}" y="{iy}" width="44" height="44" rx="12" fill="{badge_bg}" stroke="{badge_bd}"/>')
        if icon == "lock":
            lines.append(f'<rect x="{ix+13}" y="{iy+21}" width="18" height="13" rx="3" fill="none" stroke="{col}" stroke-width="2.2"/>')
            lines.append(f'<path d="M{ix+16} {iy+21}V{iy+16}A6 6 0 0 1 {ix+28} {iy+16}V{iy+21}" fill="none" stroke="{col}" stroke-width="2.2"/>')
        elif icon == "fork":
            lines.append(f'<path d="M{ix+16} {iy+32}V{iy+23}Q{ix+16} {iy+18} {ix+22} {iy+18}H{ix+29}M{ix+25} {iy+13}L{ix+30} {iy+18}L{ix+25} {iy+23}" fill="none" stroke="{col}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>')
            lines.append(f'<circle cx="{ix+16}" cy="{iy+14}" r="2.5" fill="{col}"/>')
        else:
            lines.append(f'<path d="M{ix+22} {iy+11}L{ix+33} {iy+15}V{iy+23}C{ix+33} {iy+29} {ix+28} {iy+33} {ix+22} {iy+35}C{ix+16} {iy+33} {ix+11} {iy+29} {ix+11} {iy+23}V{iy+15}Z" fill="none" stroke="{col}" stroke-width="2.2" stroke-linejoin="round"/>')
            lines.append(f'<path d="M{ix+18} {iy+23}L{ix+21} {iy+26}L{ix+27} {iy+19}" fill="none" stroke="{col}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>')

        text(lines, cx + 24, cy + 38, eyebrow, 11.5, col, 700, extra='class="mono" letter-spacing="0.8"')
        text(lines, cx + 24, cy + 68, ctitle, 21, p["ink"], 700)
        text(lines, cx + 24, cy + 98, d1, 13.5, p["ink_sub"], 400)
        text(lines, cx + 24, cy + 118, d2, 13.5, p["ink_sub"], 400)

        lines.append(f'<line x1="{cx+24}" y1="{cy+138}" x2="{cx+cw-24}" y2="{cy+138}" stroke="{p["border_soft"]}"/>')
        for b_idx, b_txt in enumerate(bullets):
            by = cy + 168 + b_idx * 32
            lines.append(f'<circle cx="{cx+30}" cy="{by-4}" r="3.2" fill="{col}"/>')
            text(lines, cx + 44, by, b_txt, 13.5, p["ink"], 500)

    save(f"tactile-gestures{suffix}", lines)


# ---------------------------------------------------------------------------
# 5. Asymmetric 5-Card Bento Grid (bento-overview-*.svg & workbench-pipeline.svg)
# ---------------------------------------------------------------------------

def bento_overview(dark=False, lang="zh", save_alias=None):
    p = palette(dark)
    zh = lang == "zh"
    suffix = ("-en" if not zh else "") + ("-dark" if dark else "-light")
    title = "BeanBridge 核心能力矩阵" if zh else "BeanBridge Architecture & Workbench Bento"
    lines = begin(1280, 616, title, p["canvas"], p["canvas_stroke"], 24)
    add_shadow_defs(lines, p["shadow_opacity"])

    hdr = "一个菜单栏守护进程，打通实时按键与离机工作台" if zh else "One Native AppKit Daemon. Live Routing + Offline Workbench."
    sub = (
        "纯 Swift 原生构建（零 Electron 开销），兼顾毫秒级内存预览、多端可插拔路由与全本地隐私落盘。"
        if zh
        else "Pure native Swift & AppKit—pairing zero-FFmpeg Whisper previews with pluggable multi-app safety routing."
    )
    text(lines, 44, 52, hdr, 26, p["ink"], 700, extra='letter-spacing="-0.5"')
    text(lines, 44, 80, sub, 15, p["ink_sub"], 400)

    # --- Bento Card 1 (Top-Left Wide) ---
    lines.append(f'<rect x="44" y="104" width="744" height="232" rx="18" fill="{p["surface"]}" stroke="{p["border"]}" filter="url(#cardShadow)"/>')
    text(lines, 68, 136, "01 · PLUGGABLE MULTI-APP ROUTING", 11.5, p["accent"], 700, extra='class="mono" letter-spacing="0.8"')
    text(lines, 68, 166, "可插拔三端适配器（AppTargetAdapter）" if zh else "Pluggable Multi-Client Routing (AppTargetAdapter)", 20, p["ink"], 700)
    text(
        lines, 68, 191,
        "菜单栏、浮窗或工作台一键切换默认目标；统一复用首按锁定、空白建聊与幂等回执。"
        if zh
        else "Switch default target anytime from Menu Bar, HUD, or Workbench with unified safety receipts.",
        13.5, p["ink_sub"],
    )
    apps = (
        [
            ("Codex", "com.openai.codex", "Cmd+Opt+L 双采样 + 入队", "真机全链路已实测", 136),
            ("豆包 / DoubaoWork", "com.work.pc.doubao", "AX URL + 25字空框占位过滤", "桌面端实机已实测", 136),
            ("Paseo", "sh.paseo.desktop", "kAXTitle + Daemon 唯一消歧", "工作区按键已实测", 136),
        ]
        if zh
        else [
            ("Codex", "com.openai.codex", "Cmd+Opt+L dual-check + queue", "D3200 E2E Verified", 148),
            ("Doubao / Work", "com.work.pc.doubao", "AX URL + 25-char hint filter", "Live App Verified", 142),
            ("Paseo", "sh.paseo.desktop", "kAXTitle + Daemon tab match", "Workspace Verified", 148),
        ]
    )
    for idx, (aname, abid, amech, astat, pw) in enumerate(apps):
        ax = 68 + idx * 236
        lines.append(f'<rect x="{ax}" y="208" width="224" height="106" rx="12" fill="{p["surface_alt"]}" stroke="{p["border_soft"]}"/>')
        text(lines, ax + 14, 232, aname, 14.5, p["ink"], 700)
        text(lines, ax + 14, 250, abid, 11, p["ink_muted"], 500, extra='class="mono"')
        text(lines, ax + 14, 272, amech, 11.5, p["ink_sub"], 500)
        pill(lines, ax + 14, 283, pw, 21, astat, p["accent_bg"], p["accent"], p["accent_border"], 10.5, 700, rx=6, dot_color=p["accent"])

    # --- Bento Card 2 (Top-Right) ---
    lines.append(f'<rect x="808" y="104" width="428" height="232" rx="18" fill="{p["surface"]}" stroke="{p["border"]}" filter="url(#cardShadow)"/>')
    text(lines, 832, 136, "02 · IN-MEMORY ASR & HOTWORDS", 11.5, p["teal"], 700, extra='class="mono" letter-spacing="0.8"')
    text(lines, 832, 166, "零 FFmpeg 纯内存实时转写" if zh else "Zero-FFmpeg In-Memory Whisper", 20, p["ink"], 700)
    text(
        lines, 832, 191,
        "Opus 48kHz 在 Swift 内存中直接重采样至 16kHz PCM。"
        if zh
        else "48kHz Opus resampled to 16kHz PCM directly in Swift RAM.",
        13.5, p["ink_sub"],
    )
    lines.append(f'<rect x="832" y="208" width="380" height="54" rx="10" fill="{p["surface_alt"]}" stroke="{p["border_soft"]}"/>')
    text(lines, 848, 231, "48kHz Opus (BLE)", 12, p["ink"], 600, extra='class="mono"')
    text(lines, 1002, 231, "->", 12, p["teal"], 700, "middle", 'class="mono"')
    text(lines, 1024, 231, "16kHz PCM (RAM)", 12, p["teal"], 700, extra='class="mono"')
    text(lines, 848, 250, "Sliding energy gate triggers whisper-cli without subprocess bloat", 11, p["ink_muted"])
    hw_chips = ["hotwords.txt:", "BeanBridge", "Codex", "Paseo", "Swift"]
    hx = 832
    for idx, hw in enumerate(hw_chips):
        w = len(hw) * 7 + 20
        if idx == 0:
            text(lines, hx, 294, hw, 12, p["ink_muted"], 600, extra='class="mono"')
            hx += 98
        else:
            pill(lines, hx, 277, w, 24, hw, p["teal_bg"], p["teal"], p["teal_border"], 11, 600, mono=True, rx=6)
            hx += w + 6

    # --- Bento Card 3 (Bottom-Left) ---
    lines.append(f'<rect x="44" y="356" width="384" height="228" rx="18" fill="{p["surface"]}" stroke="{p["border"]}" filter="url(#cardShadow)"/>')
    text(lines, 68, 388, "03 · IN-APP MODEL CENTER", 11.5, p["accent"], 700, extra='class="mono" letter-spacing="0.8"')
    text(lines, 68, 418, "可视化模型中心与双源校验" if zh else "In-App Model Download Center", 19, p["ink"], 700)
    text(
        lines, 68, 442,
        "内置 HF 官方源与 hf-mirror 镜像，后台续传 + SHA-256。"
        if zh
        else "HF Official & hf-mirror with background resume & SHA-256.",
        13, p["ink_sub"],
    )
    lines.append(f'<rect x="68" y="458" width="336" height="50" rx="10" fill="{p["surface_alt"]}" stroke="{p["border_soft"]}"/>')
    text(lines, 82, 479, "ggml-small.bin · 465 MB", 12.5, p["ink"], 700, extra='class="mono"')
    pill(lines, 286, 465, 106, 20, "SHA-256 PASS", p["accent_bg"], p["accent"], p["accent_border"], 10, 700, mono=True, rx=5)
    lines.append(f'<rect x="82" y="492" width="308" height="6" rx="3" fill="{p["border_soft"]}"/>')
    lines.append(f'<rect x="82" y="492" width="308" height="6" rx="3" fill="{p["accent"]}"/>')
    tiers_lbl = "4 档可选：Base · Small-Q5_1 · Small (推荐) · Medium" if zh else "4 Tiers: Base · Small-Q5_1 · Small (Rec.) · Medium"
    text(lines, 68, 536, tiers_lbl, 12.5, p["ink_sub"], 500)
    text(lines, 68, 560, "Atomic .part swap · 0o600 model permissions", 11.5, p["ink_muted"], 500, extra='class="mono"')

    # --- Bento Card 4 (Bottom-Center) ---
    lines.append(f'<rect x="448" y="356" width="384" height="228" rx="18" fill="{p["surface"]}" stroke="{p["border"]}" filter="url(#cardShadow)"/>')
    text(lines, 472, 388, "04 · OFFLINE SYNC & VAD WORKBENCH", 11.5, p["teal"], 700, extra='class="mono" letter-spacing="0.8"')
    text(lines, 472, 418, "离机增量同步与能量 VAD 切片" if zh else "Offline Sync & Energy VAD Slicer", 19, p["ink"], 700)
    text(
        lines, 472, 442,
        "外出盲录回来一键增量拉取，按语音能量切出时间轴。"
        if zh
        else "Incremental manifest sync + timestamped VAD speech slices.",
        13, p["ink_sub"],
    )
    lines.append(f'<rect x="472" y="458" width="336" height="50" rx="10" fill="{p["surface_alt"]}" stroke="{p["border_soft"]}"/>')
    for seg_t, seg_w, sx in [("00:01-00:06", 98, 484), ("00:08-00:15", 116, 590), ("00:18-00:22", 82, 714)]:
        lines.append(f'<rect x="{sx}" y="468" width="{seg_w}" height="30" rx="6" fill="{p["teal_bg"]}" stroke="{p["teal_border"]}"/>')
        text(lines, sx + seg_w / 2, 487, seg_t, 10.5, p["teal"], 700, "middle", 'class="mono"')
    wb_lbl = "支持多词分词检索 · 单段试听回放 · 修改后一键转发" if zh else "Multi-keyword search · Segment replay · 1-click forward"
    text(lines, 472, 536, wb_lbl, 12.5, p["ink_sub"], 500)
    text(lines, 472, 560, "Workbench/sync-manifest.json checkpoint", 11.5, p["ink_muted"], 500, extra='class="mono"')

    # --- Bento Card 5 (Bottom-Right) ---
    lines.append(f'<rect x="852" y="356" width="384" height="228" rx="18" fill="{p["surface"]}" stroke="{p["border"]}" filter="url(#cardShadow)"/>')
    text(lines, 876, 388, "05 · MENU BAR & SLEEP-AWARE BLE", 11.5, p["accent"], 700, extra='class="mono" letter-spacing="0.8"')
    text(lines, 876, 418, "菜单栏常驻与睡眠唤醒恢复" if zh else "Menu Bar Daemon & Sleep Guard", 19, p["ink"], 700)
    text(
        lines, 876, 442,
        "关掉浮窗不断连；系统休眠自动挂起，唤醒后退避重连。"
        if zh
        else "Runs in NSStatusItem with 1s-30s backoff & sleep guard.",
        13, p["ink_sub"],
    )
    lines.append(f'<rect x="876" y="458" width="336" height="50" rx="10" fill="{p["surface_alt"]}" stroke="{p["border_soft"]}"/>')
    pill(lines, 888, 471, 126, 24, "安克豆 · 92%" if zh else "Bean · 92%", p["accent_bg"], p["accent"], p["accent_border"], 11, 700, rx=6, dot_color=p["accent"])
    pill(lines, 1022, 471, 88, 24, ".sleeping", p["ctrl_bg"], p["ink_sub"], p["border"], 10.5, 600, mono=True, rx=6)
    pill(lines, 1118, 471, 82, 24, "1s -> 30s", p["ctrl_bg"], p["ink_sub"], p["border"], 10.5, 600, mono=True, rx=6)
    sc_lbl = "捷径：Cmd+V 浮窗 · Cmd+B 工作台 · Cmd+P 待发箱" if zh else "Keys: Cmd+V HUD · Cmd+B Workbench · Cmd+P Pending"
    text(lines, 876, 536, sc_lbl, 12.5, p["ink_sub"], 500)
    text(lines, 876, 560, "LSUIElement=true · App Support 0o700", 11.5, p["ink_muted"], 500, extra='class="mono"')

    save(f"bento-overview{suffix}", lines)
    if save_alias:
        save(save_alias, lines[:-1])


# ---------------------------------------------------------------------------
# 6. Native macOS AppKit Surfaces Showcase (ui-tour-dark / ui-tour-light / ui-tour)
# ---------------------------------------------------------------------------

def macos_window(lines, p, x, y, w, h, title, pin_num):
    lines.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{p["win_bg"]}" stroke="{p["border"]}" stroke-width="1.3" filter="url(#cardShadow)"/>')
    lines.append(f'<path d="M{x} {y+14}Q{x} {y} {x+14} {y}H{x+w-14}Q{x+w} {y} {x+w} {y+14}V{y+34}H{x}Z" fill="{p["win_hdr"]}"/>')
    lines.append(f'<line x1="{x}" y1="{y+34}" x2="{x+w}" y2="{y+34}" stroke="{p["border_soft"]}"/>')
    for i, c in enumerate(["#EF4444", "#F59E0B", "#10B981"]):
        lines.append(f'<circle cx="{x+18+i*14}" cy="{y+17}" r="4.5" fill="{c}"/>')
    text(lines, x + w / 2, y + 21, title, 11.5, p["ink_sub"], 600, "middle")
    lines.append(f'<circle cx="{x+w-20}" cy="{y+17}" r="10" fill="{p["accent_bg"]}" stroke="{p["accent_border"]}"/>')
    text(lines, x + w - 20, y + 21, str(pin_num), 11, p["accent"], 700, "middle", 'class="mono"')


def ui_tour(dark=False, save_default=False):
    p = palette(dark)
    suffix = "-dark" if dark else "-light"
    lines = begin(1280, 560, "BeanBridge Native macOS AppKit Surfaces Showcase", p["canvas"], p["canvas_stroke"], 24)
    add_shadow_defs(lines, p["shadow_opacity"])

    text(lines, 44, 50, "Native macOS AppKit Surfaces", 26, p["ink"], 700, extra='letter-spacing="-0.5"')
    text(
        lines, 44, 78,
        "[1] Menu Bar + Floating HUD (Cmd+V)   ·   [2] Offline Sync & VAD Workbench (Cmd+B)   ·   [3] In-App ASR Model Manager",
        14.5, p["ink_sub"], 500,
    )

    # 1. Left column: Menu Bar chip + Floating HUD
    lines.append('<rect x="44" y="102" width="356" height="38" rx="10" fill="#132922" stroke="#285042"/>')
    text(lines, 62, 125, "macOS Status Bar", 11.5, "#95B8A6", 500)
    lines.append('<rect x="208" y="109" width="180" height="24" rx="6" fill="#0B1915" stroke="#356653"/>')
    lines.append(f'<circle cx="224" cy="121" r="4.5" fill="{LIME}"/>')
    text(lines, 237, 125, "安克豆 · 92% · Small", 11.5, CREAM, 600)

    macos_window(lines, p, 44, 152, 356, 372, "安克豆语音 (Floating HUD)", 1)
    text(lines, 64, 210, "Recording · D3200 Ready", 15.5, p["ink"], 700)
    text(lines, 64, 230, "BLE Connected · Small (465MB) · Battery 92%", 11.5, p["ink_muted"])
    pill(lines, 64, 244, 130, 24, "Target: Paseo v", p["ctrl_bg"], p["ink"], p["border"], 11.5, 600, rx=6)
    lines.append(f'<rect x="202" y="244" width="178" height="24" rx="6" fill="{p["accent_bg"]}" stroke="{p["accent_border"]}"/>')
    mini_lock(lines, 218, 256, p["accent"])
    text(lines, 298, 260, "Locked · Single Window", 11, p["accent"], 700, "middle")

    lines.append(f'<rect x="64" y="280" width="316" height="176" rx="10" fill="{p["surface_alt"]}" stroke="{p["border_soft"]}"/>')
    text(lines, 78, 304, "Locked Chat: BeanBridge Workspace", 12, p["accent"], 700)
    text(lines, 78, 328, "Live In-Memory Preview (Zero FFmpeg):", 11, p["ink_muted"])
    text(lines, 78, 354, "“Upgrade the bilingual README with", 13, p["ink"], 600)
    text(lines, 78, 374, "adaptive dark/light visual cards…”", 13, p["ink"], 600)
    pill(lines, 78, 416, 288, 26, "Tap D3200 body (04.92) -> Fork clean chat", p["teal_bg"], p["teal"], p["teal_border"], 10.5, 600, rx=6, dot_color=p["teal"])

    btns = [("Probe", 56), ("Pending", 62), ("Workbench", 78), ("AX", 40), ("Cancel", 58)]
    bx = 64
    for btitle, bw in btns:
        if btitle == "Cancel":
            pill(lines, bx, 474, bw, 28, btitle, p["amber_bg"], p["amber"], p["amber_border"], 11, 700, rx=6)
        elif btitle == "Workbench":
            pill(lines, bx, 474, bw, 28, btitle, FOREST, LIME, None, 11, 700, rx=6)
        else:
            pill(lines, bx, 474, bw, 28, btitle, p["ctrl_bg"], p["ink"], p["border"], 11, 600, rx=6)
        bx += bw + 5.5

    # 2. Center column: Workbench Panel
    macos_window(lines, p, 420, 102, 440, 422, "安克豆工作台 · Workbench & VAD Replay", 2)
    lines.append(f'<rect x="438" y="148" width="166" height="26" rx="7" fill="{p["ctrl_bg"]}" stroke="{p["border_soft"]}"/>')
    pill(lines, 441, 151, 52, 20, "All", p["surface"], p["ink"], p["border"], 11, 700, rx=5)
    text(lines, 520, 165, "Inbox", 11, p["ink_sub"], 500, "middle")
    text(lines, 574, 165, "Replay", 11, p["ink_sub"], 500, "middle")
    pill(lines, 612, 148, 118, 26, "Search words…", p["surface_alt"], p["ink_muted"], p["border"], 11, 400, rx=7)
    pill(lines, 738, 148, 104, 26, "Sync Device", FOREST, LIME, None, 11, 700, rx=7)

    text(lines, 438, 198, "ASR: Small · Hotwords active", 11, p["ink_muted"])
    for idx, qbtn in enumerate(["Pending", "Hotwords", "Models"]):
        pill(lines, 640 + idx * 68, 184, 64, 22, qbtn, p["ctrl_bg"], p["ink_sub"], p["border"], 10.5, 600, rx=5)

    lines.append(f'<rect x="438" y="216" width="404" height="132" rx="8" fill="{p["surface_alt"]}" stroke="{p["border_soft"]}"/>')
    for hx, hlabel in [(450, "Tag"), (498, "Time"), (578, "VAD Slice"), (662, "Segment Excerpt")]:
        text(lines, hx, 235, hlabel, 10.5, p["ink_muted"], 700)
    lines.append(f'<line x1="438" y1="244" x2="842" y2="244" stroke="{p["border_soft"]}"/>')
    rows = [
        ("Inbox", "11-18 23:40", "00:01-00:06", "Redesign README with Bento.", True),
        ("Replay", "11-18 22:15", "00:02-00:09", "Live Paseo workspace tab lock.", False),
        ("Inbox", "11-18 21:04", "00:00-00:14", "DoubaoWork single-window fix.", False),
    ]
    for r_idx, (cat, tm, rng, exc, sel) in enumerate(rows):
        ry = 250 + r_idx * 31
        if sel:
            lines.append(f'<rect x="442" y="{ry}" width="396" height="27" rx="6" fill="{p["accent_bg"]}" stroke="{p["accent_border"]}"/>')
        text(lines, 450, ry + 18, cat, 11, p["accent"] if sel else p["ink_sub"], 700)
        text(lines, 498, ry + 18, tm, 11, p["ink_sub"])
        text(lines, 578, ry + 18, rng, 10.5, p["ink_muted"], extra='class="mono"')
        text(lines, 662, ry + 18, exc, 11, p["ink"], 600 if sel else 400)

    lines.append(f'<rect x="438" y="360" width="404" height="96" rx="8" fill="{p["surface_alt"]}" stroke="{p["border_soft"]}"/>')
    text(lines, 452, 382, "Editable Segment Transcript (VAD 00:01-00:06):", 11, p["ink_muted"])
    text(lines, 452, 406, "Redesign the bilingual README with Bento & Dark Mode.", 13, p["ink"], 600)
    for wi in range(28):
        wh = 6 + ((wi * 7) % 14)
        wx_bar = 454 + wi * 10
        lines.append(f'<rect x="{wx_bar}" y="{436 - wh/2:.1f}" width="4" height="{wh}" rx="2" fill="{p["accent"]}" opacity="0.75"/>')

    wbtns = [("Play", 62), ("Copy", 56), ("Move", 58), ("Target: Paseo v", 132), ("Send ->", 72)]
    wx = 438
    for wt, ww in wbtns:
        if "Send" in wt:
            pill(lines, wx, 474, ww, 28, wt, FOREST, LIME, None, 11, 700, rx=6)
        else:
            pill(lines, wx, 474, ww, 28, wt, p["ctrl_bg"], p["ink"], p["border"], 11, 600, rx=6)
        wx += ww + 6

    # 3. Right column: ASR Model Manager
    macos_window(lines, p, 880, 102, 356, 422, "ASR 模型管理与下载中心", 3)
    text(lines, 900, 158, "Active: Small (465 MB) · Auto-selected", 12.5, p["ink"], 700)
    pill(lines, 900, 170, 158, 24, "Mirror: hf-mirror.com v", p["ctrl_bg"], p["ink"], p["border"], 10.5, 600, rx=6)
    pill(lines, 1066, 170, 150, 24, "SHA-256 Verified", p["accent_bg"], p["accent"], p["accent_border"], 10.5, 700, rx=6, dot_color=p["accent"])

    tiers = [
        ("Small · Recommended (~465 MB)", "Active · Best ZH/EN balance", p["accent_bg"], p["accent_border"], p["accent"], 1.0),
        ("Small-Q5_1 (~181 MB)", "Downloading 72% · 16.4 MB/s", p["teal_bg"], p["teal_border"], p["teal"], 0.72),
        ("Medium · Flagship (~1.43 GB)", "Available · Dense terminology", p["surface_alt"], p["border_soft"], p["ink_sub"], 0.0),
        ("Base · Fast (~141 MB)", "Installed · Low-latency fallback", p["surface_alt"], p["border_soft"], p["ink_sub"], 0.0),
    ]
    for tidx, (tname, tstatus, tfill, tbd, tac, prog) in enumerate(tiers):
        ty = 208 + tidx * 62
        lines.append(f'<rect x="900" y="{ty}" width="316" height="52" rx="10" fill="{tfill}" stroke="{tbd}"/>')
        text(lines, 914, ty + 21, tname, 12, p["ink"], 700)
        text(lines, 914, ty + 40, tstatus, 11, tac, 600)
        if 0 < prog < 1:
            lines.append(f'<rect x="1104" y="{ty+33}" width="98" height="6" rx="3" fill="{p["border"]}"/>')
            lines.append(f'<rect x="1104" y="{ty+33}" width="{int(98*prog)}" height="6" rx="3" fill="{tac}"/>')

    pill(lines, 900, 474, 152, 28, "Verify All SHA-256", p["ctrl_bg"], p["ink"], p["border"], 11, 600, rx=6)
    pill(lines, 1064, 474, 152, 28, "Open Models/", p["ctrl_bg"], p["ink"], p["border"], 11, 600, rx=6)

    save(f"ui-tour{suffix}", lines)
    if save_default:
        save("ui-tour", lines[:-1])


# ---------------------------------------------------------------------------
# 7. Adaptive End-to-End Architecture Flow (flow-dark / flow-light / flow)
# ---------------------------------------------------------------------------

def flow(dark=False, save_default=False):
    p = palette(dark)
    suffix = "-dark" if dark else "-light"
    lines = begin(1280, 406, "BeanBridge end-to-end architecture pipeline", p["canvas"], p["canvas_stroke"], 24)
    add_shadow_defs(lines, p["shadow_opacity"])
    lines.append(
        f'<defs><marker id="arr{suffix}" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">'
        f'<path d="M0 0L10 3.5L0 7Z" fill="{p["accent"]}"/></marker></defs>'
    )

    text(lines, 44, 52, "End-to-End Voice-to-Agent Pipeline", 26, p["ink"], 700, extra='letter-spacing="-0.5"')
    text(
        lines, 44, 80,
        "Encrypted BLE Opus audio is decoded & transcribed locally in macOS RAM, then delivered under strict target lock.",
        15, p["ink_sub"],
    )

    lines.append(
        f'<rect x="336" y="110" width="608" height="206" rx="16" fill="{p["surface_alt"]}" '
        f'stroke="{p["accent_border"]}" stroke-dasharray="6 5"/>'
    )
    text(lines, 358, 134, "ON YOUR MAC  ·  IN-MEMORY PIPELINE  ·  ZERO FFMPEG", 11, p["accent"], 700, extra='class="mono" letter-spacing="1.4"')

    cards = [
        (44, "01", "D3200 Hardware", "Press to lock · Tap (04.92) to fork", "ble"),
        (358, "02", "RAM Resampler", "Opus 48kHz -> 16kHz PCM16", "wave"),
        (672, "03", "whisper.cpp ASR", "4 verified GGML tiers + hotwords", "asr"),
        (986, "04", "Safety Router", "Codex · Doubao · Paseo", "route"),
    ]
    for x, num, ctitle, csub, kind in cards:
        lines.append(f'<rect x="{x}" y="150" width="250" height="146" rx="14" fill="{p["surface"]}" stroke="{p["border"]}" filter="url(#cardShadow)"/>')
        pill(lines, x + 194, 166, 40, 22, num, p["ctrl_bg"], p["ink_sub"], p["border_soft"], 11, 700, mono=True, rx=6)
        lines.append(f'<rect x="{x+20}" y="166" width="40" height="40" rx="11" fill="{p["accent_bg"]}" stroke="{p["accent_border"]}"/>')
        if kind == "ble":
            lines.append(f'<circle cx="{x+40}" cy="186" r="11" fill="none" stroke="{p["accent"]}" stroke-width="2.4"/>')
            lines.append(f'<circle cx="{x+48}" cy="194" r="3" fill="{p["accent"]}"/>')
        elif kind == "wave":
            lines.append(f'<path d="M{x+28} 188V184M{x+34} 193V179M{x+40} 197V175M{x+46} 192V180M{x+52} 188V184" stroke="{p["accent"]}" stroke-width="2.6" stroke-linecap="round"/>')
        elif kind == "asr":
            lines.append(f'<path d="M{x+29} 179H{x+49}M{x+29} 186H{x+52}M{x+29} 193H{x+42}" stroke="{p["accent"]}" stroke-width="2.6" stroke-linecap="round"/>')
        else:
            lines.append(f'<path d="M{x+30} 180L{x+38} 186L{x+30} 192M{x+41} 192H{x+50}" fill="none" stroke="{p["accent"]}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>')
        text(lines, x + 20, 238, ctitle, 20, p["ink"], 700)
        text(lines, x + 20, 264, csub, 13, p["ink_sub"], 500)

    for x1, x2, lbl in [(298, 352, "BLE"), (612, 666, "16k PCM"), (926, 980, "Routed")]:
        lines.append(f'<path d="M{x1} 224H{x2}" fill="none" stroke="{p["accent"]}" stroke-width="2.2" marker-end="url(#arr{suffix})"/>')
        text(lines, (x1 + x2) / 2, 212, lbl, 10.5, p["ink_muted"], 700, "middle", 'class="mono"')

    lines.append(f'<line x1="44" y1="336" x2="1236" y2="336" stroke="{p["border_soft"]}"/>')
    mini_shield(lines, 52, 364, p["accent"])
    text(lines, 66, 368, "Fail-Closed Guarantee: Ambiguity or focus loss locks into Pending Inbox (0o600).", 13.5, p["ink_sub"], 500)
    text(lines, 1236, 368, "Offline recordings sync incrementally into Workbench.", 13.5, p["ink_sub"], 500, "end")

    save(f"flow{suffix}", lines)
    if save_default:
        save("flow", lines[:-1])


# ---------------------------------------------------------------------------
# 8. Adaptive Multi-App Safety Routing Decision Tree (Paths A–D)
# ---------------------------------------------------------------------------

def multi_app_routing(dark=False, save_default=False):
    p = palette(dark)
    suffix = "-dark" if dark else "-light"
    lines = begin(1280, 560, "Multi-App Safety Routing & Disambiguation (Paths A–D)", p["canvas"], p["canvas_stroke"], 24)
    add_shadow_defs(lines, p["shadow_opacity"])
    lines.append(
        f'<defs><marker id="rarr{suffix}" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">'
        f'<path d="M0 0L10 3.5L0 7Z" fill="{p["accent"]}"/></marker></defs>'
    )

    text(lines, 44, 50, "Multi-App Safety Routing & Disambiguation", 26, p["ink"], 700, extra='letter-spacing="-0.5"')
    pill(lines, 1044, 28, 192, 30, "SHIPPED IN v0.5.1", p["accent_bg"], p["accent"], p["accent_border"], 11.5, 700, mono=True)
    text(lines, 44, 78, "Target freezes on first button press. Split panes, duplicate titles, or focus jumps fail closed.", 15, p["ink_sub"])

    lines.append(f'<rect x="310" y="104" width="660" height="72" rx="14" fill="{p["surface_alt"]}" stroke="{p["accent_border"]}" stroke-width="1.5"/>')
    text(lines, 640, 134, "First Button Press  —  Inspect Active AppTargetAdapter", 19, p["ink"], 700, "middle")
    text(lines, 640, 159, "Codex (Cmd+Opt+L UUID)   ·   Doubao / DoubaoWork (AX URL)   ·   Paseo (AX Title + Daemon)", 12.5, p["ink_sub"], 600, "middle")

    lines.append(f'<path d="M640 176V204M184 204H1096" fill="none" stroke="{p["accent"]}" stroke-width="1.8"/>')
    xs = [44, 348, 652, 956]
    for x in xs:
        cx = x + 140
        lines.append(f'<path d="M{cx} 204V234" fill="none" stroke="{p["accent"]}" stroke-width="1.8" marker-end="url(#rarr{suffix})"/>')

    cards = [
        (
            44, "PATH A", "Unique Target Locked", "Pin exact session ID",
            [
                "Codex: double-copy UUID check",
                "Doubao: filter 25-char hint",
                "Paseo: unique non-archived title",
                "Tab switches never redirect",
            ],
            p["accent"], p["accent_bg"], p["accent_border"],
        ),
        (
            348, "PATH B", "Blank Tab or Closed", "Auto-create clean chat",
            [
                "Codex: isolated Chats/<id>",
                "Doubao: single-window launch",
                "Paseo: idempotent daemon create",
                "Existing drafts never inherited",
            ],
            p["teal"], p["teal_bg"], p["teal_border"],
        ),
        (
            652, "PATH C", "Mid-Recording Tap", "Fork standalone chat",
            [
                "04.92 bit 0 vibration marker",
                "HUD confirms tap immediately",
                "Original target cleanly detached",
                "Cancel button aborts anytime",
            ],
            p["accent"], p["accent_bg"], p["accent_border"],
        ),
        (
            956, "PATH D", "Ambiguous or Error", "Fail closed into Pending",
            [
                "Multi-window or split conflict",
                "Duplicate titles or loading tabs",
                "Missing AX or focus shifted",
                "Saved on disk (0o600) to review",
            ],
            p["amber"], p["amber_bg"], p["amber_border"],
        ),
    ]
    for x, tag, ctitle, action, bullets, col, bbg, bbd in cards:
        lines.append(f'<rect x="{x}" y="242" width="280" height="240" rx="14" fill="{p["surface"]}" stroke="{p["border"]}" filter="url(#cardShadow)"/>')
        pill(lines, x + 20, 260, 74, 22, tag, bbg, col, bbd, 11, 700, mono=True, rx=6)
        text(lines, x + 20, 308, ctitle, 19, p["ink"], 700)
        text(lines, x + 20, 333, action, 14, col, 600)
        lines.append(f'<line x1="{x+20}" y1="348" x2="{x+260}" y2="348" stroke="{p["border_soft"]}"/>')
        for idx, b in enumerate(bullets):
            yy = 376 + idx * 26
            lines.append(f'<circle cx="{x+26}" cy="{yy-4}" r="2.8" fill="{col}"/>')
            text(lines, x + 38, yy, b, 13, p["ink_sub"], 500)

    lines.append(f'<rect x="44" y="500" width="1192" height="38" rx="10" fill="{FOREST}"/>')
    text(
        lines, 640, 524,
        "Creation/ & Submissions/ receipts enforce idempotent claiming (0o600): timeouts enter 'uncertain' instead of double-sending.",
        13, CREAM, 600, "middle",
    )

    save(f"multi-app-routing{suffix}", lines)
    if save_default:
        save("multi-app-routing", lines[:-1])


# ---------------------------------------------------------------------------
# 9. Historical v0.1 Routing Archive (Preserved for docs/context-routing.md)
# ---------------------------------------------------------------------------

def routing_archive():
    p = palette(False)
    lines = begin(1280, 320, "Archived v0.1 routing proposal note", p["canvas"], p["canvas_stroke"], 20)
    text(lines, 44, 54, "Context-Aware Routing (Archived v0.1 Proposal)", 24, p["ink"], 700)
    pill(lines, 1020, 32, 216, 28, "ARCHIVED · SEE v0.5.1", p["amber_bg"], p["amber"], p["amber_border"], 11, 700, mono=True)
    text(
        lines, 44, 86,
        "This early v0.1 three-branch concept has been superseded by multi-app-routing.svg (Paths A-D across Codex, Doubao & Paseo).",
        15, p["ink_sub"],
    )
    for idx, (lbl, desc) in enumerate([
        ("Branch A · Pin Known Thread", "Now shipped across Codex, Doubao & Paseo"),
        ("Branch B · Auto-Create Blank", "Now shipped with 0o600 idempotent receipts"),
        ("Branch C · Pending Inbox", "Active fail-closed safety guarantee"),
    ]):
        bx = 44 + idx * 404
        lines.append(f'<rect x="{bx}" y="118" width="384" height="156" rx="14" fill="{p["surface"]}" stroke="{p["border"]}"/>')
        text(lines, bx + 24, 168, lbl, 18, p["ink"], 700)
        text(lines, bx + 24, 204, desc, 14, p["ink_sub"], 500)
    save("routing-proposal", lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--png", action="store_true")
    parser.add_argument(
        "--icns",
        action="store_true",
        help="Build the macOS app icon (requires CairoSVG, Pillow and iconutil).",
    )
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    BADGES_OUT.mkdir(parents=True, exist_ok=True)

    logo()
    badges()
    banner("banner", 1600, 560)
    banner("social-preview", 1280, 640)

    hero_demo("zh")
    hero_demo("en")

    for is_dark in (False, True):
        tactile_gestures(dark=is_dark, lang="zh")
        tactile_gestures(dark=is_dark, lang="en")
        bento_overview(dark=is_dark, lang="zh", save_alias="workbench-pipeline" if not is_dark else None)
        bento_overview(dark=is_dark, lang="en")
        ui_tour(dark=is_dark, save_default=not is_dark)
        flow(dark=is_dark, save_default=not is_dark)
        multi_app_routing(dark=is_dark, save_default=not is_dark)

    routing_archive()

    if args.png:
        import cairosvg

        for path in sorted(OUT.glob("*.svg")):
            if path.stem in ("hero-banner", "social-preview", "banner") and (OUT / "studio-hardware-bg.jpg").exists():
                continue
            cairosvg.svg2png(
                url=str(path),
                write_to=str(path.with_suffix(".png")),
                scale=2 if path.stem != "social-preview" else 1,
            )
    if args.icns:
        import cairosvg
        import io
        import subprocess
        import tempfile
        from PIL import Image

        master = Image.open(
            io.BytesIO(cairosvg.svg2png(url=str(OUT / "logo.svg"), output_width=1024, output_height=1024))
        )
        with tempfile.TemporaryDirectory(prefix="beanbridge-icon-") as temporary:
            iconset = Path(temporary) / "BeanBridge.iconset"
            iconset.mkdir()
            for size in [16, 32, 128, 256, 512]:
                for multiplier in [1, 2]:
                    suffix = "@2x" if multiplier == 2 else ""
                    pixels = size * multiplier
                    master.resize((pixels, pixels), Image.Resampling.LANCZOS).save(
                        iconset / f"icon_{size}x{size}{suffix}.png"
                    )
            subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "BeanBridge.icns")], check=True)
    print("Generated BeanBridge visual suite in docs/assets")
