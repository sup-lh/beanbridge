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
    lines.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)}">'
    )
    lines.append(f"<title>{escape(title)}</title>")
    lines.append(
        '<style>text{font-family:"Helvetica Neue",Helvetica,Arial,sans-serif} '
        '.mono{font-family:Menlo,Consolas,monospace}</style>'
    )
    if background:
        lines.append(f'<rect width="{width}" height="{height}" rx="24" fill="{background}"/>')
    return lines


def text(lines, x, y, value, size=20, color=FOREST, weight=400, anchor="start", extra=""):
    lines.append(
        f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" '
        f'font-weight="{weight}" text-anchor="{anchor}" {extra}>{escape(value)}</text>'
    )


def mark(lines, x, y, size, tile=True):
    lines.append(f'<g transform="translate({x} {y}) scale({size/256})">')
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


def save(name, lines):
    lines.append("</svg>")
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
    text(lines, 78, 341, "Wearable AI voice button & workbench for Codex, Doubao, and Paseo.", 22, "#C1D6C8")
    labels = [("D3200 BLE + OFFLINE", 214), ("LOCAL WHISPER ASR", 214), ("CODEX · DOUBAO · PASEO", 254)]
    x = 78
    for label, w in labels:
        lines.append(f'<rect x="{x}" y="411" width="{w}" height="42" rx="21" fill="#244C3D" stroke="#476B52"/>')
        text(lines, x + w / 2, 438, label, 13, "#E3EFDF", 500, "middle", 'class="mono" letter-spacing="1"')
        x += w + 14
    text(
        lines,
        80,
        511,
        "MULTI-APP ROUTING  /  FAIL-CLOSED TARGET LOCK  /  LOCAL WORKBENCH",
        12,
        "#99B69F",
        400,
        extra='class="mono" letter-spacing="1"',
    )
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
    text(lines, 968, 390, "LOCKED TO YOUR FOREGROUND CONVERSATION", 13, "#6C866E", 600, extra='letter-spacing="1"')
    text(lines, 968, 429, "Turn this voice note into a clean PR.", 22, FOREST, 500)
    lines.append('<circle cx="1455" cy="392" r="12" fill="#C6F38A"/>')
    lines.append('<path d="M1450 392L1454 396L1461 387" fill="none" stroke="#12372D" stroke-width="2.4" stroke-linecap="round"/>')
    lines.append("</g>")
    save(name, lines)


def arrow(lines, x1, y1, x2, y2, label=None, color="#2563EB"):
    lines.append(f'<path d="M{x1} {y1}L{x2} {y2}" fill="none" stroke="{color}" stroke-width="2" marker-end="url(#arrow)"/>')
    if label:
        text(lines, (x1 + x2) / 2, y1 - 14, label, 13, "#6B7280", 400, "middle")


def flow():
    lines = begin(1280, 410, "Implemented multi-app audio-to-message data flow", "#FFFFFF")
    lines.append(
        '<defs><marker id="arrow" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">'
        '<path d="M0 0L10 3.5L0 7Z" fill="#2563EB"/></marker></defs>'
    )
    text(lines, 40, 51, "From a button press to the locked conversation", 28, "#111827", 600)
    text(
        lines,
        40,
        83,
        "BLE audio is resampled & transcribed locally on macOS, then routed safely to Codex, Doubao, or Paseo.",
        16,
        "#6B7280",
    )
    lines.append('<rect x="339" y="116" width="602" height="194" rx="12" fill="#F8FAFC" stroke="#D1D5DB" stroke-dasharray="6 5"/>')
    text(lines, 359, 139, "ON YOUR MAC (IN-MEMORY · ZERO FFMPEG)", 11, "#6B7280", 600, extra='letter-spacing="1.6"')
    for x1, x2, label in [(280, 360, "BLE"), (600, 680, "16k PCM"), (920, 1000, "routed text")]:
        arrow(lines, x1 + 8, 229, x2 - 8, 229, label)
    cards = [
        (40, "01", "D3200", "Press to speak · Tap for new", "#EFF6FF", "device"),
        (360, "02", "Decode", "48kHz Opus -> 16kHz PCM", "#F0FDFA", "wave"),
        (680, "03", "Local ASR", "4 GGML tiers + hotwords", "#F0FDF4", "text"),
        (1000, "04", "Multi-App", "Codex · Doubao · Paseo", "#FAF5FF", "terminal"),
    ]
    for x, n, title, sub, fill, icon in cards:
        lines.append(f'<rect x="{x}" y="155" width="240" height="136" rx="8" fill="{fill}" stroke="#D1D5DB" stroke-width="1.5"/>')
        text(lines, x + 215, 181, n, 12, "#6B7280", 500, "end", 'class="mono"')
        if icon == "device":
            lines.append(f'<rect x="{x+22}" y="175" width="29" height="37" rx="14" fill="#2563EB"/>')
            lines.append(f'<path d="M{x+35} 181V203" stroke="white" stroke-width="3" stroke-linecap="round"/>')
        elif icon == "wave":
            lines.append(
                f'<path d="M{x+23} 195V201M{x+31} 184V212M{x+39} 178V218M{x+47} 188V207M{x+55} 195V201" '
                f'stroke="#0F766E" stroke-width="3" stroke-linecap="round"/>'
            )
        elif icon == "text":
            for yy, ww in [(181, 35), (193, 44), (205, 27)]:
                lines.append(f'<rect x="{x+22}" y="{yy}" width="{ww}" height="4" rx="2" fill="#16A34A"/>')
        else:
            lines.append(f'<rect x="{x+20}" y="176" width="49" height="37" rx="6" fill="{FOREST}"/>')
            lines.append(
                f'<path d="M{x+31} 186L{x+40} 194L{x+31} 202M{x+44} 202H{x+56}" '
                f'fill="none" stroke="{LIME}" stroke-width="2.6" stroke-linecap="round"/>'
            )
        text(lines, x + 22, 244, title, 23, "#111827", 600)
        text(lines, x + 22, 270, sub, 14, "#6B7280")
    lines.append('<line x1="40" y1="338" x2="1240" y2="338" stroke="#E5E7EB"/>')
    text(lines, 40, 372, "Ambiguity or focus jumps fail closed into Pending Inbox (0o600).", 14, "#6B7280")
    text(lines, 1240, 372, "Offline device recordings sync cleanly to Workbench.", 14, "#6B7280", 400, "end")
    save("flow", lines)


def routing():
    lines = begin(1280, 630, "Proposed context-aware routing — historical v0.1 note", "#FFFFFF")
    lines.append(
        '<defs><marker id="arrow" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">'
        '<path d="M0 0L10 3.5L0 7Z" fill="#2563EB"/></marker></defs>'
    )
    text(lines, 40, 48, "Context-aware routing", 28, "#111827", 600)
    lines.append('<rect x="1037" y="24" width="203" height="32" rx="16" fill="#FFF7ED"/>')
    text(lines, 1138, 45, "ARCHIVED v0.1 PROPOSAL", 11, "#C2410C", 600, "middle", 'class="mono"')
    text(lines, 40, 80, "Historical design note (superseded by implemented multi-app-routing.svg).", 16, "#6B7280")
    lines.append('<rect x="455" y="118" width="370" height="70" rx="8" fill="#EFF6FF" stroke="#BFDBFE"/>')
    text(lines, 640, 148, "First press", 21, "#111827", 600, "middle")
    text(lines, 640, 174, "Capture app state + routing context", 14, "#6B7280", 400, "middle")
    lines.append('<path d="M640 188V217M220 217H1060" fill="none" stroke="#2563EB" stroke-width="1.8"/>')
    for x in [220, 640, 1060]:
        lines.append(f'<path d="M{x} 217V253" fill="none" stroke="#2563EB" stroke-width="1.8" marker-end="url(#arrow)"/>')
    content = [
        (40, "A", "A reliable thread is known", "Pin that exact thread ID", ["Show the destination in the panel.", "Send only to the captured target.", "Changing tabs does not redirect audio."], "#F0FDF4", "Now shipped across Codex, Doubao & Paseo"),
        (460, "B", "Client is blank or closed", "Launch, then create", ["Create an isolated new session.", "Wait for creation receipt.", "Open and submit cleanly."], "#EFF6FF", "Shipped with 0o600 idempotent receipts"),
        (880, "C", "No clear destination", "Fail closed into Pending", ["Preserve transcript safely on disk.", "Choose existing or create new later.", "Never guess recent threads."], "#FFF7ED", "Active fail-closed safety rule"),
    ]
    for x, n, title, action, details, fill, note in content:
        lines.append(f'<rect x="{x}" y="260" width="360" height="236" rx="8" fill="{fill}" stroke="#D1D5DB" stroke-width="1.5"/>')
        text(lines, x + 22, 292, n, 14, "#6B7280", 500, extra='class="mono"')
        text(lines, x + 22, 330, title, 21, "#111827", 600)
        text(lines, x + 22, 365, action, 18, "#2563EB", 500)
        for y, detail in zip([403, 429, 455], details):
            text(lines, x + 22, y, detail, 14, "#6B7280")
        text(lines, x + 180, 526, note, 12, "#6B7280", 400, "middle")
    lines.append('<rect x="40" y="559" width="1200" height="38" rx="8" fill="#F3F4F6"/>')
    text(lines, 640, 584, "Historical proposal preserved for reference. See docs/assets/multi-app-routing.svg for v0.5.1 shipped routing.", 14, "#4B5563", 500, "middle")
    save("routing-proposal", lines)


def multi_app_routing():
    lines = begin(1280, 560, "Implemented multi-app safety routing & disambiguation", "#FFFFFF")
    lines.append(
        '<defs><marker id="arrow" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">'
        '<path d="M0 0L10 3.5L0 7Z" fill="#12372D"/></marker></defs>'
    )
    text(lines, 40, 48, "Multi-App Safety Routing & Disambiguation", 28, "#111827", 600)
    lines.append('<rect x="1030" y="24" width="210" height="32" rx="16" fill="#ECFDF5" stroke="#A7F3D0"/>')
    text(lines, 1135, 45, "SHIPPED IN v0.5.1", 11, "#065F46", 600, "middle", 'class="mono"')
    text(lines, 40, 80, "Selected target freezes on first press. Ambiguous splits, duplicate titles, or focus jumps fail closed.", 16, "#6B7280")

    lines.append('<rect x="330" y="108" width="620" height="72" rx="10" fill="#F6FAF0" stroke="#476B52" stroke-width="1.5"/>')
    text(lines, 640, 138, "First Press -> Inspect Active AppTargetAdapter", 20, FOREST, 600, "middle")
    text(lines, 640, 163, "Codex (⌘⌥L)  ·  Doubao / DoubaoWork (AX URL)  ·  Paseo (AX Title + Daemon)", 14, "#476B52", 500, "middle")

    lines.append(f'<path d="M640 180V205M178 205H1102" fill="none" stroke="{FOREST}" stroke-width="1.8"/>')
    xs = [40, 348, 656, 964]
    for x in xs:
        cx = x + 138
        lines.append(f'<path d="M{cx} 205V234" fill="none" stroke="{FOREST}" stroke-width="1.8" marker-end="url(#arrow)"/>')

    cards = [
        (
            40,
            "PATH A",
            "Unique Target Locked",
            "Pin exact session ID",
            [
                "Codex: double-copy UUID check",
                "Doubao: filter 25-char placeholder",
                "Paseo: unique non-archived title",
                "Tab switching never redirects",
            ],
            "#F0FDF4",
            "#15803D",
        ),
        (
            348,
            "PATH B",
            "Blank Tab or Closed",
            "Auto-create clean chat",
            [
                "Codex: projectless Chats/<id>",
                "Doubao: single-window launch",
                "Paseo: idempotent daemon create",
                "Draft state never inherited",
            ],
            "#EFF6FF",
            "#1D4ED8",
        ),
        (
            656,
            "PATH C",
            "Mid-Recording Tap",
            "Route to standalone chat",
            [
                "04.92 bit 0 hardware vibration",
                "HUD displays tap confirmation",
                "Locked target cleanly discarded",
                "Cancel button aborts anytime",
            ],
            "#FAF5FF",
            "#7E22CE",
        ),
        (
            964,
            "PATH D",
            "Ambiguous or Error",
            "Fail closed into Pending",
            [
                "Multi-window or split pane conflict",
                "Duplicate titles or loading tabs",
                "Missing AX / focus changed mid-read",
                "Stored on disk (0o600) for review",
            ],
            "#FFF7ED",
            "#C2410C",
        ),
    ]
    for x, tag, title, action, bullets, fill, accent in cards:
        lines.append(f'<rect x="{x}" y="242" width="276" height="242" rx="10" fill="{fill}" stroke="#D1D5DB" stroke-width="1.5"/>')
        text(lines, x + 20, 272, tag, 12, accent, 600, extra='class="mono"')
        text(lines, x + 20, 304, title, 20, "#111827", 600)
        text(lines, x + 20, 334, action, 15, accent, 600)
        for idx, b in enumerate(bullets):
            yy = 372 + idx * 27
            lines.append(f'<circle cx="{x+24}" cy="{yy-4}" r="2.5" fill="{accent}"/>')
            text(lines, x + 36, yy, b, 13.5, "#374151")

    lines.append(f'<rect x="40" y="502" width="1200" height="38" rx="8" fill="{FOREST}"/>')
    text(
        lines,
        640,
        526,
        "Creation/ and Submissions/ receipts enforce idempotent claiming: crashes or timeouts enter 'uncertain' instead of double-sending.",
        13.5,
        CREAM,
        500,
        "middle",
    )
    save("multi-app-routing", lines)


def workbench_pipeline():
    lines = begin(1280, 480, "Menu bar daemon, ASR model center & offline workbench pipeline", "#FFFFFF")
    text(lines, 40, 48, "Always-On Daemon, Model Center & Offline Workbench", 28, "#111827", 600)
    text(
        lines,
        40,
        80,
        "Three core subsystems keeping BLE resilient, ASR accurate, and offline D3200 recordings searchable.",
        16,
        "#6B7280",
    )

    panels = [
        (
            40,
            "01 · MENU BAR & BLE",
            "ReconnectCoordinator",
            "#F0FDFA",
            "#0F766E",
            [
                ("NSStatusItem Daemon", "Runs with floating HUD hidden"),
                ("Exponential Backoff", "1s -> 30s auto-reconnect retries"),
                ("Sleep/Wake Awareness", ".sleeping state avoids thrashing"),
                ("Live Indicators", "Battery %, recording & countdown"),
                ("Shortcuts", "Cmd+V HUD · B Workbench · R Sync"),
            ],
        ),
        (
            450,
            "02 · LOCAL ASR & MODELS",
            "ASRModelDownloadManager",
            "#EFF6FF",
            "#1D4ED8",
            [
                ("4 Verified Tiers", "Base · Small-Q5_1 · Small · Medium"),
                ("Dual Mirrors", "Hugging Face Official / hf-mirror"),
                ("Safe Streaming", "Hidden .part + SHA-256 atomic swap"),
                ("Custom Hotwords", "hotwords.txt editable in-app"),
                ("In-Memory Preview", "48kHz -> 16kHz zero-ffmpeg gate"),
            ],
        ),
        (
            860,
            "03 · INSPIRATION WORKBENCH",
            "WorkbenchSync + VAD",
            "#F6FAF0",
            FOREST,
            [
                ("Incremental Sync", "sync-manifest.json skips synced IDs"),
                ("Energy VAD Slicer", "Auto-segments speech timestamps"),
                ("Search & Filter", "Multi-keyword + Inbox/Replay tabs"),
                ("Audition & Edit", "Playback audio & refine text"),
                ("One-Click Forward", "Send to Codex, Doubao, or Paseo"),
            ],
        ),
    ]
    for x, tag, title, fill, accent, items in panels:
        lines.append(f'<rect x="{x}" y="110" width="380" height="304" rx="12" fill="{fill}" stroke="#D1D5DB" stroke-width="1.5"/>')
        text(lines, x + 22, 140, tag, 12, accent, 600, extra='class="mono"')
        text(lines, x + 22, 172, title, 21, "#111827", 600)
        lines.append(f'<line x1="{x+22}" y1="188" x2="{x+358}" y2="188" stroke="#E5E7EB"/>')
        for idx, (k, v) in enumerate(items):
            yy = 216 + idx * 39
            lines.append(f'<rect x="{x+22}" y="{yy-12}" width="8" height="8" rx="2" fill="{accent}"/>')
            text(lines, x + 38, yy - 3, k, 14, "#111827", 600)
            text(lines, x + 38, yy + 14, v, 12.5, "#6B7280")

    lines.append('<rect x="40" y="428" width="1200" height="34" rx="8" fill="#F3F4F6"/>')
    text(
        lines,
        640,
        449,
        "State directory: ~/Library/Application Support/AnkerVoiceBridge (0o700 directories, 0o600 models, pending queue & receipts)",
        12.5,
        "#374151",
        500,
        "middle",
        'class="mono"',
    )
    save("workbench-pipeline", lines)


def window_frame(lines, x, y, w, h, title, header_fill="#F3F4F6"):
    lines.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="#FFFFFF" stroke="#CBD5E1" stroke-width="1.5"/>')
    lines.append(f'<path d="M{x} {y+12}Q{x} {y} {x+12} {y}H{x+w-12}Q{x+w} {y} {x+w} {y+12}V{y+32}H{x}Z" fill="{header_fill}"/>')
    lines.append(f'<line x1="{x}" y1="{y+32}" x2="{x+w}" y2="{y+32}" stroke="#E2E8F0"/>')
    for i, c in enumerate(["#EF4444", "#F59E0B", "#10B981"]):
        lines.append(f'<circle cx="{x+18+i*14}" cy="{y+16}" r="4.5" fill="{c}"/>')
    text(lines, x + w / 2, y + 20, title, 12, "#334155", 600, "middle")


def ui_tour():
    lines = begin(1280, 540, "macOS desktop surfaces tour in v0.5.1", "#F8FAFC")
    text(lines, 40, 48, "Native macOS Desktop Surfaces (AppKit)", 28, "#111827", 600)
    text(lines, 40, 78, "Menu bar daemon + Floating HUD, Workbench with VAD replay, and In-App ASR Model Manager.", 16, "#6B7280")

    # 1. Left column: Menu Bar chip + Floating HUD
    lines.append('<rect x="40" y="106" width="360" height="36" rx="8" fill="#1E293B"/>')
    text(lines, 58, 129, "macOS Menu Bar", 12, "#94A3B8", 500)
    lines.append('<rect x="206" y="112" width="182" height="24" rx="6" fill="#334155"/>')
    lines.append('<circle cx="223" cy="124" r="4.5" fill="#C6F38A"/>')
    text(lines, 236, 128, "Anker Bean · 92%", 12, "#F8FAFC", 600)

    window_frame(lines, 40, 154, 360, 342, "Anker Voice HUD (Floating Panel)")
    text(lines, 60, 212, "Recording · D3200 Ready", 16, "#111827", 600)
    text(lines, 60, 232, "BLE: Connected · Small (465MB) · 92%", 11.5, "#64748B")
    lines.append('<rect x="60" y="246" width="136" height="24" rx="5" fill="#F1F5F9" stroke="#CBD5E1"/>')
    text(lines, 72, 262, "Target: Paseo ▾", 12, "#0F172A", 500)
    lines.append('<rect x="204" y="246" width="176" height="24" rx="5" fill="#ECFDF5" stroke="#A7F3D0"/>')
    text(lines, 214, 262, "Locked · Foreground Single", 11, "#065F46", 500)
    lines.append('<rect x="60" y="282" width="320" height="140" rx="8" fill="#F8FAFC" stroke="#E2E8F0"/>')
    text(lines, 74, 306, "Locked Chat: BeanBridge Workspace", 12, FOREST, 600)
    text(lines, 74, 332, "Live ASR Preview (in-memory):", 11.5, "#64748B")
    text(lines, 74, 356, '"Start optimizing the bilingual', 13, "#0F172A", 500)
    text(lines, 74, 376, 'README with diagrams..."', 13, "#0F172A", 500)
    text(lines, 74, 406, "Tip: Tap device to fork a new chat", 11, "#7C3AED")
    btns = [("Probe", 56), ("Pending", 64), ("Workbench", 82), ("AX", 38), ("Cancel", 60)]
    bx = 60
    for btitle, bw in btns:
        bg = "#FEE2E2" if btitle == "Cancel" else ("#12372D" if btitle == "Workbench" else "#F1F5F9")
        fg = "#991B1B" if btitle == "Cancel" else ("#C6F38A" if btitle == "Workbench" else "#1E293B")
        lines.append(f'<rect x="{bx}" y="442" width="{bw}" height="28" rx="6" fill="{bg}" stroke="#CBD5E1"/>')
        text(lines, bx + bw / 2, 460, btitle, 11, fg, 600, "middle")
        bx += bw + 5

    # 2. Center column: Workbench Panel
    window_frame(lines, 420, 106, 440, 390, "BeanBridge Workbench · Inbox & Replay")
    lines.append('<rect x="438" y="150" width="166" height="24" rx="6" fill="#E2E8F0"/>')
    lines.append('<rect x="440" y="152" width="52" height="20" rx="5" fill="#FFFFFF"/>')
    text(lines, 466, 166, "All", 11, "#0F172A", 600, "middle")
    text(lines, 520, 166, "Inbox", 11, "#475569", 500, "middle")
    text(lines, 574, 166, "Replay", 11, "#475569", 500, "middle")
    lines.append('<rect x="612" y="150" width="118" height="24" rx="6" fill="#F8FAFC" stroke="#CBD5E1"/>')
    text(lines, 622, 166, "Search keywords...", 11, "#94A3B8")
    lines.append('<rect x="738" y="150" width="104" height="24" rx="6" fill="#12372D"/>')
    text(lines, 790, 166, "Sync Device", 11, "#C6F38A", 600, "middle")

    text(lines, 438, 196, "ASR: Small · Hotwords ready", 11, "#64748B")
    for idx, qbtn in enumerate(["Pending", "Hotwords", "Models"]):
        qx = 640 + idx * 68
        lines.append(f'<rect x="{qx}" y="182" width="64" height="20" rx="4" fill="#F1F5F9" stroke="#CBD5E1"/>')
        text(lines, qx + 32, 196, qbtn, 10.5, "#334155", 500, "middle")

    lines.append('<rect x="438" y="212" width="404" height="122" rx="6" fill="#FFFFFF" stroke="#E2E8F0"/>')
    lines.append('<rect x="438" y="212" width="404" height="24" rx="6" fill="#F8FAFC"/>')
    for hx, hlabel in [(448, "Tag"), (494, "Time"), (574, "Range"), (654, "Segment Excerpt")]:
        text(lines, hx, 228, hlabel, 10.5, "#64748B", 600)
    rows = [
        ("Inbox", "11-16 01:46", "00:01-00:05", "Commit and push verified docs.", True),
        ("Replay", "11-16 01:41", "00:02-00:08", "Live Paseo workspace routing.", False),
        ("Inbox", "11-16 01:28", "00:00-00:14", "DoubaoWork single window fix.", False),
    ]
    for r_idx, (cat, tm, rng, exc, sel) in enumerate(rows):
        ry = 240 + r_idx * 30
        if sel:
            lines.append(f'<rect x="440" y="{ry-2}" width="400" height="28" rx="4" fill="#EFF6FF"/>')
        text(lines, 448, ry + 16, cat, 11, "#1D4ED8" if sel else "#475569", 600)
        text(lines, 494, ry + 16, tm, 11, "#334155")
        text(lines, 574, ry + 16, rng, 10.5, "#64748B", extra='class="mono"')
        text(lines, 654, ry + 16, exc, 11, "#0F172A")

    lines.append('<rect x="438" y="344" width="404" height="82" rx="6" fill="#F8FAFC" stroke="#E2E8F0"/>')
    text(lines, 450, 366, "Editable Segment Transcript:", 11, "#64748B")
    text(lines, 450, 390, "Commit and push the verified docs.", 13, "#0F172A", 500)
    text(lines, 450, 412, "Audio sliced by VAD · Archived under Workbench/audio", 11, "#64748B")

    wbtns = [("Play", 58), ("Copy", 58), ("Move Tag", 74), ("Codex/Doubao/Paseo ▾", 128), ("Send", 62)]
    wx = 438
    for wt, ww in wbtns:
        bg = "#2563EB" if wt == "Send" else "#F1F5F9"
        fg = "#FFFFFF" if wt == "Send" else "#1E293B"
        lines.append(f'<rect x="{wx}" y="444" width="{ww}" height="28" rx="6" fill="{bg}" stroke="#CBD5E1"/>')
        text(lines, wx + ww / 2, 462, wt, 10.5, fg, 600, "middle")
        wx += ww + 6

    # 3. Right column: ASR Model Manager
    window_frame(lines, 880, 106, 360, 390, "ASR Model Manager & Download Center")
    text(lines, 900, 158, "Active: Small (465MB) · Auto-selected", 12.5, "#0F172A", 600)
    lines.append('<rect x="900" y="170" width="160" height="22" rx="5" fill="#F1F5F9" stroke="#CBD5E1"/>')
    text(lines, 910, 185, "Source: HF Official ▾", 11, "#334155")
    lines.append('<rect x="1068" y="170" width="152" height="22" rx="5" fill="#ECFDF5" stroke="#A7F3D0"/>')
    text(lines, 1144, 185, "SHA-256 Verified", 11, "#065F46", 600, "middle")

    tiers = [
        ("Small · Recommended (~465MB)", "Active", "#F0FDF4", "#15803D", 1.0),
        ("Small-Q5_1 (~181MB)", "Downloading 68% · 14.2 MB/s", "#EFF6FF", "#1D4ED8", 0.68),
        ("Medium · Flagship (~1.43GB)", "Download Model", "#FFFFFF", "#475569", 0.0),
        ("Base · Fast (~141MB)", "Installed · Switch", "#FFFFFF", "#475569", 0.0),
    ]
    for tidx, (tname, tstatus, tfill, tac, prog) in enumerate(tiers):
        ty = 204 + tidx * 58
        lines.append(f'<rect x="900" y="{ty}" width="320" height="50" rx="8" fill="{tfill}" stroke="#CBD5E1"/>')
        text(lines, 914, ty + 20, tname, 12, "#0F172A", 600)
        text(lines, 914, ty + 38, tstatus, 11, tac, 500)
        if 0 < prog < 1:
            lines.append(f'<rect x="1104" y="{ty+30}" width="102" height="6" rx="3" fill="#DBEAFE"/>')
            lines.append(f'<rect x="1104" y="{ty+30}" width="{int(102*prog)}" height="6" rx="3" fill="#2563EB"/>')

    lines.append('<rect x="900" y="444" width="154" height="28" rx="6" fill="#F1F5F9" stroke="#CBD5E1"/>')
    text(lines, 977, 462, "Verify All SHA-256", 11, "#1E293B", 600, "middle")
    lines.append('<rect x="1066" y="444" width="154" height="28" rx="6" fill="#F1F5F9" stroke="#CBD5E1"/>')
    text(lines, 1143, 462, "Open Models/", 11, "#1E293B", 600, "middle")

    save("ui-tour", lines)


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
    logo()
    banner()
    banner("social-preview", 1280, 640)
    flow()
    routing()
    multi_app_routing()
    workbench_pipeline()
    ui_tour()
    if args.png:
        import cairosvg

        for path in sorted(OUT.glob("*.svg")):
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
    print("Generated BeanBridge assets in docs/assets")
