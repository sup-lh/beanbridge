#!/usr/bin/env python3
"""Generate the original BeanBridge SVG brand and documentation figures.

SVGs use only inline shapes and system fonts. Add --png when CairoSVG is installed.
"""
from pathlib import Path
from html import escape
import argparse

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/assets"
FOREST, LIME, CREAM = "#12372D", "#C6F38A", "#F6FAF0"


def begin(width, height, title, background=None):
    lines = []
    lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)}">')
    lines.append(f'<title>{escape(title)}</title>')
    lines.append('<style>text{font-family:"Helvetica Neue",Helvetica,Arial,sans-serif} .mono{font-family:Menlo,Consolas,monospace}</style>')
    if background:
        lines.append(f'<rect width="{width}" height="{height}" rx="24" fill="{background}"/>')
    return lines


def text(lines, x, y, value, size=20, color=FOREST, weight=400, anchor="start", extra=""):
    lines.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" font-weight="{weight}" text-anchor="{anchor}" {extra}>{escape(value)}</text>')


def mark(lines, x, y, size, tile=True):
    lines.append(f'<g transform="translate({x} {y}) scale({size/256})">')
    if tile:
        lines.append(f'<rect width="256" height="256" rx="62" fill="{FOREST}"/>')
    lines.append(f'<path d="M141 39C102 25 58 49 43 85C27 124 41 169 74 194C100 214 133 215 155 195C177 175 159 151 169 132C178 115 205 114 210 91C215 67 181 51 141 39Z" fill="{LIME}"/>')
    lines.append(f'<path d="M139 56C100 74 96 105 116 130C133 153 128 178 104 190" fill="none" stroke="{FOREST}" stroke-width="15" stroke-linecap="round"/>')
    lines.append(f'<path d="M174 156V175M194 143V186M214 157V173" fill="none" stroke="{LIME}" stroke-width="10" stroke-linecap="round"/>')
    lines.append('</g>')


def save(name, lines):
    lines.append('</svg>')
    (OUT / f"{name}.svg").write_text("\n".join(lines) + "\n", encoding="utf-8")


def logo():
    lines = begin(256, 256, "BeanBridge logo: a bean and an audio waveform")
    mark(lines, 0, 0, 256)
    save("logo", lines)


def banner(name="banner", width=1600, height=560):
    lines = begin(width, height, "BeanBridge — Press. Speak. Send.")
    scale = width / 1600
    offset = (height - 560 * scale) / 2
    lines.append(f'<rect width="{width}" height="{height}" rx="24" fill="{FOREST}"/>')
    lines.append(f'<g transform="translate(0 {offset}) scale({scale})">')
    lines.append(f'<rect width="1600" height="560" rx="28" fill="{FOREST}"/>')
    lines.append('<path d="M810 560C930 320 1230 260 1600 286V560Z" fill="#1A4839"/>')
    lines.append('<path d="M1000 0C1010 190 1300 215 1600 170V0Z" fill="#183E33"/>')
    for x in range(925, 1550, 32):
        for y in range(45, 485, 32):
            lines.append(f'<circle cx="{x}" cy="{y}" r="1.2" fill="#74A589" opacity=".24"/>')
    mark(lines, 68, 53, 74)
    text(lines, 160, 98, "BEANBRIDGE / MACOS", 18, "#D4E7D1", 500, extra='letter-spacing="3"')
    text(lines, 72, 225, "BeanBridge", 100, CREAM, 600, extra='letter-spacing="-4"')
    text(lines, 76, 290, "Press. Speak. Send.", 39, LIME, 500, extra='letter-spacing="-1"')
    text(lines, 78, 341, "A physical button for your Codex conversation.", 24, "#C1D6C8")
    labels = [("D3200 + BLE", 170), ("LOCAL SPEECH", 194), ("CODEX QUEUE", 191)]
    x = 78
    for label, w in labels:
        lines.append(f'<rect x="{x}" y="411" width="{w}" height="42" rx="21" fill="#244C3D" stroke="#476B52"/>')
        text(lines, x+w/2, 438, label, 14, "#E3EFDF", 500, "middle", 'class="mono" letter-spacing="1"')
        x += w+14
    text(lines, 80, 511, "EXPERIMENTAL PROTOTYPE  /  EXPLICIT TARGET  /  LOCAL TRANSCRIPTION", 12, "#99B69F", 400, extra='class="mono" letter-spacing="1"')
    # Recorder symbol and the bridge to a message, intentionally not a product render.
    lines.append('<ellipse cx="1220" cy="278" rx="168" ry="115" fill="#08271D"/>')
    lines.append('<circle cx="1210" cy="231" r="144" fill="#ECF5DC"/>')
    lines.append('<circle cx="1210" cy="231" r="120" fill="#DDEBC9" stroke="#B7CCA2" stroke-width="2"/>')
    mark(lines, 1119, 137, 185, False)
    lines.append('<circle cx="1309" cy="133" r="9" fill="#EEB95F"/>')
    lines.append('<path d="M1010 245H968Q946 245 946 270V355" fill="none" stroke="#C6F38A" stroke-width="3" stroke-linecap="round"/>')
    lines.append('<circle cx="1010" cy="245" r="6" fill="#C6F38A"/>')
    lines.append('<rect x="885" y="350" width="610" height="130" rx="18" fill="#F6FAF0"/>')
    lines.append('<rect x="907" y="373" width="42" height="42" rx="10" fill="#DEEDCD"/>')
    lines.append('<path d="M920 385L930 394L920 403M933 403H939" fill="none" stroke="#12372D" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>')
    text(lines, 968, 390, "YOUR VOICE, IN THE RIGHT THREAD", 13, "#6C866E", 600, extra='letter-spacing="1"')
    text(lines, 968, 429, "Turn this idea into something useful.", 22, FOREST, 500)
    lines.append('<circle cx="1455" cy="392" r="12" fill="#C6F38A"/>')
    lines.append('<path d="M1450 392L1454 396L1461 387" fill="none" stroke="#12372D" stroke-width="2.4" stroke-linecap="round"/>')
    lines.append('</g>')
    save(name, lines)


def arrow(lines, x1, y1, x2, y2, label=None):
    lines.append(f'<path d="M{x1} {y1}L{x2} {y2}" fill="none" stroke="#2563EB" stroke-width="2" marker-end="url(#arrow)"/>')
    if label:
        text(lines, (x1+x2)/2, y1-14, label, 13, "#6B7280", 400, "middle")


def flow():
    lines = begin(1280, 410, "Implemented audio-to-message data flow", "#FFFFFF")
    lines.append('<defs><marker id="arrow" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto"><path d="M0 0L10 3.5L0 7Z" fill="#2563EB"/></marker></defs>')
    text(lines, 40, 51, "From a press to a message", 28, "#111827", 600)
    text(lines, 40, 83, "Audio is decoded and transcribed on your Mac. Final text goes to the selected Codex thread.", 16, "#6B7280")
    lines.append('<rect x="339" y="116" width="602" height="194" rx="12" fill="#F8FAFC" stroke="#D1D5DB" stroke-dasharray="6 5"/>')
    text(lines, 359, 139, "ON YOUR MAC", 11, "#6B7280", 600, extra='letter-spacing="2"')
    for x1, x2, label in [(280,360,"BLE"),(600,680,"PCM"),(920,1000,"final text")]:
        arrow(lines, x1+8, 229, x2-8, 229, label)
    cards = [
        (40, "01", "D3200", "Press to start / stop", "#EFF6FF", "device"),
        (360, "02", "Decode", "Encrypted Opus to audio", "#F0FDFA", "wave"),
        (680, "03", "Local ASR", "Whisper + live preview", "#F0FDF4", "text"),
        (1000, "04", "Codex queue", "Explicit thread ID", "#FAF5FF", "terminal")
    ]
    for x, n, title, sub, fill, icon in cards:
        lines.append(f'<rect x="{x}" y="155" width="240" height="136" rx="8" fill="{fill}" stroke="#D1D5DB" stroke-width="1.5"/>')
        text(lines, x+215, 181, n, 12, "#6B7280", 500, "end", 'class="mono"')
        if icon == "device":
            lines.append(f'<rect x="{x+22}" y="175" width="29" height="37" rx="14" fill="#2563EB"/>')
            lines.append(f'<path d="M{x+35} 181V203" stroke="white" stroke-width="3" stroke-linecap="round"/>')
        elif icon == "wave":
            lines.append(f'<path d="M{x+23} 195V201M{x+31} 184V212M{x+39} 178V218M{x+47} 188V207M{x+55} 195V201" stroke="#0F766E" stroke-width="3" stroke-linecap="round"/>')
        elif icon == "text":
            for yy, ww in [(181,35),(193,44),(205,27)]:
                lines.append(f'<rect x="{x+22}" y="{yy}" width="{ww}" height="4" rx="2" fill="#16A34A"/>')
        else:
            lines.append(f'<rect x="{x+20}" y="176" width="49" height="37" rx="6" fill="#111827"/>')
            lines.append(f'<path d="M{x+31} 186L{x+40} 194L{x+31} 202M{x+44} 202H{x+56}" fill="none" stroke="#D8B4FE" stroke-width="2.6" stroke-linecap="round"/>')
        text(lines, x+22, 244, title, 23, "#111827", 600)
        text(lines, x+22, 270, sub, 14, "#6B7280")
    lines.append('<line x1="40" y1="338" x2="1240" y2="338" stroke="#E5E7EB"/>')
    text(lines, 40, 372, "The recorder retains its own audio.", 14, "#6B7280")
    text(lines, 1240, 372, "Queued does not always mean processing immediately.", 14, "#6B7280", 400, "end")
    save("flow", lines)


def routing():
    lines = begin(1280, 630, "Proposed context-aware routing — not implemented", "#FFFFFF")
    lines.append('<defs><marker id="arrow" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto"><path d="M0 0L10 3.5L0 7Z" fill="#2563EB"/></marker></defs>')
    text(lines, 40, 48, "Context-aware routing", 28, "#111827", 600)
    lines.append('<rect x="1037" y="24" width="203" height="32" rx="16" fill="#FFF7ED"/>')
    text(lines, 1138, 45, "PROPOSAL / NOT SHIPPED", 11, "#C2410C", 600, "middle", 'class="mono"')
    text(lines, 40, 80, "Freeze the destination on the first press. Never infer the target from recency.", 16, "#6B7280")
    lines.append('<rect x="455" y="118" width="370" height="70" rx="8" fill="#EFF6FF" stroke="#BFDBFE"/>')
    text(lines, 640, 148, "First press", 21, "#111827", 600, "middle")
    text(lines, 640, 174, "Capture app state + routing context", 14, "#6B7280", 400, "middle")
    lines.append('<path d="M640 188V217M220 217H1060" fill="none" stroke="#2563EB" stroke-width="1.8"/>')
    for x in [220,640,1060]:
        lines.append(f'<path d="M{x} 217V253" fill="none" stroke="#2563EB" stroke-width="1.8" marker-end="url(#arrow)"/>')
    content = [
      (40,"A","A reliable thread is known","Pin that exact thread ID",["Show the destination in the panel.","Send only to the captured target.","Changing tabs does not redirect audio."],"#F0FDF4","Copy-link verified manually; automation pending"),
      (460,"B","Codex is not running","Launch, then create",["Use a configured workspace.","Wait for creation acknowledgement.","Open and submit to the returned ID."],"#EFF6FF","Creation APIs exist; UI handoff untested"),
      (880,"C","No clear destination","Show a destination picker",["Keep the transcript pending.","Choose an existing or new thread.","Do not guess the last active thread."],"#FFF7ED","Safe fallback when state is ambiguous")
    ]
    for x, n, title, action, details, fill, note in content:
        lines.append(f'<rect x="{x}" y="260" width="360" height="236" rx="8" fill="{fill}" stroke="#D1D5DB" stroke-width="1.5"/>')
        text(lines, x+22, 292, n, 14, "#6B7280", 500, extra='class="mono"')
        text(lines, x+22, 330, title, 21, "#111827", 600)
        text(lines, x+22, 365, action, 18, "#2563EB", 500)
        for y, detail in zip([403,429,455], details): text(lines, x+22, y, detail, 14, "#6B7280")
        text(lines, x+180, 526, note, 12, "#6B7280", 400, "middle")
    lines.append('<rect x="40" y="559" width="1200" height="38" rx="8" fill="#F3F4F6"/>')
    text(lines, 640, 584, "Current build: one explicitly configured thread. Automatic focus routing is not implemented.", 14, "#4B5563", 500, "middle")
    save("routing-proposal", lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--png", action="store_true")
    parser.add_argument("--icns", action="store_true", help="Build the macOS app icon (requires CairoSVG, Pillow and iconutil).")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    logo(); banner(); banner("social-preview", 1280, 640); flow(); routing()
    if args.png:
        import cairosvg
        for path in sorted(OUT.glob("*.svg")):
            cairosvg.svg2png(url=str(path), write_to=str(path.with_suffix(".png")), scale=2 if path.stem != "social-preview" else 1)
    if args.icns:
        import cairosvg
        import io
        import subprocess
        import tempfile
        from PIL import Image
        master = Image.open(io.BytesIO(cairosvg.svg2png(url=str(OUT / "logo.svg"), output_width=1024, output_height=1024)))
        with tempfile.TemporaryDirectory(prefix="beanbridge-icon-") as temporary:
            iconset = Path(temporary) / "BeanBridge.iconset"
            iconset.mkdir()
            for size in [16, 32, 128, 256, 512]:
                for multiplier in [1, 2]:
                    suffix = "@2x" if multiplier == 2 else ""
                    pixels = size * multiplier
                    master.resize((pixels, pixels), Image.Resampling.LANCZOS).save(iconset / f"icon_{size}x{size}{suffix}.png")
            subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "BeanBridge.icns")], check=True)
    print("Generated BeanBridge assets in docs/assets")
