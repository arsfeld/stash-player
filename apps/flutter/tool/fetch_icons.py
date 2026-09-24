#!/usr/bin/env python3
"""Fetches the app's icons into assets/icons/.

Linux (Adwaita dialect) icons come from GNOME's icon-development-kit, the
CC0 set libadwaita apps draw from; macOS icons come from Lucide (ISC).
Both are pinned. Rerun only when adding an icon to lib/ui/icons/app_icons.dart:

    python3 tool/fetch_icons.py

The GNOME icons are GTK "GPA" SVGs that carry several animation states
in one file, with the inactive states marked visibility="hidden". A
plain SVG renderer would draw every state on top of each other, so each
icon is flattened to one state here: "outline" by default, or the state
named after "@" (e.g. "star@filled").
"""

import pathlib
import urllib.request
import xml.etree.ElementTree as ET

GNOME_COMMIT = "e5857f6d796a96571a61030db40f35bfb8815a94"
GNOME_BASE = (
    "https://gitlab.gnome.org/Teams/Design/icon-development-kit/-/raw/"
    f"{GNOME_COMMIT}"
)
LUCIDE_VERSION = "1.48.0"
LUCIDE_BASE = f"https://cdn.jsdelivr.net/npm/lucide-static@{LUCIDE_VERSION}"

GNOME = [
    "go-previous", "pan-down", "view-sort-ascending", "view-sort-descending",
    "checkbox", "circle-check", "cross", "eye-open", "eye-crossed",
    "media-playlist-shuffle", "folder-plus", "list", "cogged-wheel",
    "sliders", "clock", "dialog-warning", "video-encode", "info-outline",
    "speaker-cross", "speaker-max", "media-skip-backward",
    "media-skip-forward", "arrow-left-10", "arrow-right-10",
    "media-playback-start", "media-playback-pause",
    "media-playback-start@filled", "raindrop", "edit-clear", "video",
    "clapper", "round-exclamation", "star@filled", "loupe",
]
LUCIDE = [
    "arrow-left", "chevron-down", "arrow-up-narrow-wide",
    "arrow-down-wide-narrow", "circle-dashed", "circle-check-big",
    "circle-x", "eye", "eye-off", "shuffle", "folder-plus", "list-checks",
    "settings", "sliders-horizontal", "clock", "triangle-alert",
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


def flatten_gpa(svg: bytes, state: str) -> bytes:
    ET.register_namespace("", SVG_NS)
    root = ET.fromstring(svg)

    def prune(parent: ET.Element) -> None:
        for child in list(parent):
            local = child.tag.split("}")[-1]
            states = child.get(f"{{{GPA_NS}}}states")
            # <defs> may hold paint servers the kept paths reference, so it
            # is never pruned, whatever state it is tagged with.
            if local == "metadata" or (
                local != "defs"
                and states is not None
                and state not in states.split()
            ):
                parent.remove(child)
                continue
            child.attrib.pop("visibility", None)
            for key in [k for k in child.attrib if k.startswith(f"{{{GPA_NS}}}")]:
                del child.attrib[key]
            prune(child)

    prune(root)
    for key in [k for k in root.attrib if k.startswith(f"{{{GPA_NS}}}")]:
        del root.attrib[key]
    root.set("viewBox", root.get("viewBox", "0 0 16 16"))
    return ET.tostring(root, encoding="utf-8")


def main() -> None:
    gnome_dir = ROOT / "gnome"
    lucide_dir = ROOT / "lucide"
    for directory in (gnome_dir, lucide_dir):
        directory.mkdir(parents=True, exist_ok=True)
        for old in directory.glob("*.svg"):
            old.unlink()

    for entry in GNOME:
        name, _, state = entry.partition("@")
        svg = fetch(f"{GNOME_BASE}/icons/{name}.svg")
        out = f"{name}-{state}.svg" if state else f"{name}.svg"
        (gnome_dir / out).write_bytes(flatten_gpa(svg, state or "outline"))
    (gnome_dir / "COPYING.md").write_bytes(fetch(f"{GNOME_BASE}/COPYING.md"))

    for name in LUCIDE:
        (lucide_dir / f"{name}.svg").write_bytes(
            fetch(f"{LUCIDE_BASE}/icons/{name}.svg")
        )
    (lucide_dir / "LICENSE").write_bytes(fetch(f"{LUCIDE_BASE}/LICENSE"))


if __name__ == "__main__":
    main()
