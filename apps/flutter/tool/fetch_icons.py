#!/usr/bin/env python3
"""Fetches the app's icons into assets/icons/.

Linux (Adwaita dialect) icons come from GNOME's adwaita-icon-theme, the
official symbolic icons libadwaita/GTK apps draw from; macOS icons come from
Lucide (ISC). Both are pinned. Rerun only when adding an icon to
lib/ui/icons/app_icons.dart:

    python3 tool/fetch_icons.py
"""

import pathlib
import urllib.request
import xml.etree.ElementTree as ET

ADWAITA_COMMIT = "551245ae75fdc42cde42a8cf24ca2ccab9d3a815"
ADWAITA_BASE = (
    "https://gitlab.gnome.org/GNOME/adwaita-icon-theme/-/raw/"
    f"{ADWAITA_COMMIT}/Adwaita/symbolic"
)
LUCIDE_VERSION = "1.48.0"
LUCIDE_BASE = f"https://cdn.jsdelivr.net/npm/lucide-static@{LUCIDE_VERSION}"

ADWAITA_ICONS = {
    # actions
    "go-previous-symbolic": "actions",
    "view-sort-ascending-symbolic": "actions",
    "view-sort-descending-symbolic": "actions",
    "view-reveal-symbolic": "actions",
    "view-conceal-symbolic": "actions",
    "folder-new-symbolic": "actions",
    "view-list-symbolic": "actions",
    "open-menu-symbolic": "actions",
    "view-more-horizontal-symbolic": "actions",
    "object-select-symbolic": "actions",
    "media-skip-backward-symbolic": "actions",
    "media-skip-forward-symbolic": "actions",
    "media-seek-backward-symbolic": "actions",
    "media-seek-forward-symbolic": "actions",
    "media-playback-start-symbolic": "actions",
    "media-playback-pause-symbolic": "actions",
    "edit-clear-symbolic": "actions",
    "edit-find-symbolic": "actions",
    # ui
    "pan-down-symbolic": "ui",
    "checkbox-symbolic": "ui",
    "checkbox-checked-symbolic": "ui",
    "window-close-symbolic": "ui",
    # status
    "media-playlist-shuffle-symbolic": "status",
    "dialog-warning-symbolic": "status",
    "dialog-information-symbolic": "status",
    "dialog-error-symbolic": "status",
    "audio-volume-muted-symbolic": "status",
    "audio-volume-high-symbolic": "status",
    "starred-symbolic": "status",
    # devices
    "video-display-symbolic": "devices",
    # legacy
    "preferences-system-time-symbolic": "legacy",
    # mimetypes
    "video-x-generic-symbolic": "mimetypes",
}

O_COUNTER_SVG = b"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <path fill="#2e3436" d="M8 1C5.5 4 2.5 7 2.5 10C2.5 13 5 15.5 8 15.5C11 15.5 13.5 13 13.5 10C13.5 7 10.5 4 8 1Z"/>
</svg>
"""
LUCIDE = [
    "arrow-left", "chevron-down", "arrow-up-narrow-wide",
    "arrow-down-wide-narrow", "circle-dashed", "circle-check-big",
    "circle-x", "eye", "eye-off", "shuffle", "folder-plus", "list-checks",
    "menu", "sliders-horizontal", "clock", "triangle-alert",
    "monitor-play", "info", "volume-x", "volume-2", "skip-back",
    "skip-forward", "rotate-ccw", "rotate-cw", "play", "pause",
    "circle-play", "droplet", "delete", "x", "film", "clapperboard",
    "circle-alert", "star", "search",
]

SVG_NS = "http://www.w3.org/2000/svg"
GPA_NS = "https://www.gtk.org/grappa"
ROOT = pathlib.Path(__file__).resolve().parent.parent / "assets" / "icons"


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url) as response:
        return response.read()


def _resolve_paint_value(value: str, defined_ids: set[str]) -> str:
    """Rewrites a `fill`/`stroke` value of the form `url(#id) fallback`
    (optionally with quotes around the fragment, however ElementTree
    happened to escape them) to just `fallback`, since
    vector_graphics_compiler silently drops the whole paint rather than
    falling back to it when `#id` doesn't resolve. A `url()` with no
    fallback is left alone if `#id` is actually defined in this file
    (a real gradient/pattern), and otherwise replaced with black, the
    same default CSS would use for an unresolvable paint.
    """
    stripped = value.strip()
    if not stripped.startswith("url("):
        return value
    close = stripped.find(")")
    if close == -1:
        return value
    ref = stripped[4:close].strip().strip("\"'").lstrip("#")
    fallback = stripped[close + 1 :].strip()
    if fallback:
        return fallback
    return value if ref in defined_ids else "rgb(0,0,0)"


def _resolve_paint_references(root: ET.Element) -> None:
    defined_ids = {el.get("id") for el in root.iter() if el.get("id")}
    for el in root.iter():
        for attr in ("fill", "stroke"):
            value = el.get(attr)
            if value is not None:
                el.set(attr, _resolve_paint_value(value, defined_ids))


def main() -> None:
    gnome_dir = ROOT / "gnome"
    lucide_dir = ROOT / "lucide"
    for directory in (gnome_dir, lucide_dir):
        directory.mkdir(parents=True, exist_ok=True)
        for old in directory.glob("*.svg"):
            old.unlink()

    for name, category in ADWAITA_ICONS.items():
        svg = fetch(f"{ADWAITA_BASE}/{category}/{name}.svg")
        ET.register_namespace("", SVG_NS)
        root = ET.fromstring(svg)
        _resolve_paint_references(root)
        root.set("viewBox", root.get("viewBox", "0 0 16 16"))
        (gnome_dir / f"{name}.svg").write_bytes(ET.tostring(root, encoding="utf-8"))

    (gnome_dir / "o-counter-symbolic.svg").write_bytes(O_COUNTER_SVG)
    (gnome_dir / "COPYING.md").write_bytes(
        fetch(
            f"https://gitlab.gnome.org/GNOME/adwaita-icon-theme/-/raw/{ADWAITA_COMMIT}/COPYING"
        )
    )

    for name in LUCIDE:
        (lucide_dir / f"{name}.svg").write_bytes(
            fetch(f"{LUCIDE_BASE}/icons/{name}.svg")
        )
    (lucide_dir / "LICENSE").write_bytes(fetch(f"{LUCIDE_BASE}/LICENSE"))


if __name__ == "__main__":
    main()
