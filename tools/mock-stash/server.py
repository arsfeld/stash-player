#!/usr/bin/env python3
"""Mock Stash GraphQL server for offline development + screenshots.

Implements the subset of the Stash schema that stash-player consumes:
  - version
  - findScenes / findScene
  - sceneSaveActivity, sceneIncrementO, sceneResetO

Thumbnails come from `./thumbs/<id>.jpg` (regenerate via gen_thumbs.sh).
The data set is 12 SFW landscape-themed scenes — safe for screenshots
and demos.

Test-only observability (not part of the Stash schema): every accepted
`sceneSaveActivity` call is recorded in-memory, in order, and can be read
back via `GET /__test__/activity` or cleared via `POST /__test__/reset`.
This exists so the Flutter integration smoke test (and any other client
test) can assert on activity writeback without a real Stash instance.
`/stream` stays a documented 404 — this does not add real video or
bypass authentication in any way.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
THUMB_DIR = os.path.join(HERE, "thumbs")
HOST = os.environ.get("MOCK_STASH_HOST", "127.0.0.1")
PORT = int(os.environ.get("MOCK_STASH_PORT", "9999"))

# In-memory, ordered record of every accepted `sceneSaveActivity` call —
# test-only observability, see the module docstring. Never persisted, and
# cleared only by `POST /__test__/reset` (not by any GraphQL mutation).
ACTIVITY_LOG = []

STUDIOS = [
    {"id": "S1", "name": "Open Frame"},
    {"id": "S2", "name": "Wild Lens"},
    {"id": "S3", "name": "Daylight Co"},
    {"id": "S4", "name": "Field Notes Films"},
]

PERFORMERS = [
    {"id": "P1", "name": "Mira Solveig"},
    {"id": "P2", "name": "Owen Park"},
    {"id": "P3", "name": "Hana Kato"},
    {"id": "P4", "name": "Eli Brennan"},
    {"id": "P5", "name": "Kira Vance"},
    {"id": "P6", "name": "Ari Lund"},
    {"id": "P7", "name": "Noor Aziz"},
    {"id": "P8", "name": "Theo Vance"},
]


def scene(idx, sid, title, details, date, rating100, dur, w, h, codec, fps,
          studio_idx, performer_idxs, ocount=0, plays=0, resume=0.0):
    return {
        "id": str(sid),
        "title": title,
        "details": details,
        "date": date,
        "rating100": rating100,
        "resume_time": resume,
        "play_count": plays,
        "play_duration": resume * 1.05 if resume else 0.0,
        "o_counter": ocount,
        "paths": {
            "screenshot": f"http://{HOST}:{PORT}/scene/{sid}/screenshot",
            "preview": None,
            "sprite": None,
            "stream": f"http://{HOST}:{PORT}/scene/{sid}/stream",
            "webp": None,
        },
        "files": [{
            "path": f"/media/stash/{sid}_{title.lower().replace(' ', '_')}.mp4",
            "duration": dur,
            "width": w,
            "height": h,
            "video_codec": codec,
            "frame_rate": fps,
        }],
        "studio": STUDIOS[studio_idx],
        "performers": [PERFORMERS[i] for i in performer_idxs],
    }


SCENES = [
    scene(0, 1001, "Aurora Over Tromsø",
          "A timelapse of the green Arctic auroras photographed across three winter nights above the Norwegian coast.",
          "2026-02-14", 90, 1842.0, 3840, 2160, "hevc", 30, 1, [0, 3], plays=4, resume=320.0),
    scene(1, 1002, "Sunrise in Hokkaido",
          "Cinematic morning light over the snow-blanketed forests of Daisetsuzan National Park.",
          "2026-01-08", 80, 1320.0, 3840, 2160, "hevc", 30, 1, [2], plays=2, resume=600.0),
    scene(2, 1003, "Rooftop Jazz Midnight",
          "An impromptu rooftop jazz set recorded under the city's neon skyline.",
          "2025-12-22", 70, 2580.0, 1920, 1080, "h264", 25, 0, [4, 5], plays=1),
    scene(3, 1004, "Trinity College Library",
          "Slow walk through the Long Room, with afternoon sun catching dust above the oak shelves.",
          "2025-11-30", 60, 940.0, 1920, 1080, "h264", 25, 2, [3]),
    scene(4, 1005, "Volcanic Iceland Coast",
          "Black-sand beaches, basalt sea stacks, and breaking Atlantic surf along the Reynisfjara coastline.",
          "2025-10-17", 85, 1502.0, 3840, 2160, "hevc", 60, 1, [1, 7], plays=3, resume=240.0),
    scene(5, 1006, "Paris in the Rain",
          "Wet cobblestones, café awnings, and umbrellas crossing the Pont des Arts at dusk.",
          "2025-09-04", None, 1080.0, 1920, 1080, "h264", 30, 0, [0]),
    scene(6, 1007, "Kyoto Cherry Blossoms",
          "Sakura tunnels along the Philosopher's Path, filmed at the peak of the spring bloom.",
          "2026-04-02", 100, 1620.0, 3840, 2160, "hevc", 60, 3, [2, 6], plays=5),
    scene(7, 1008, "Sailing the Greek Isles",
          "Three days aboard a small sloop hopping between Milos, Folegandros and Sifnos.",
          "2025-08-19", 75, 2400.0, 3840, 2160, "hevc", 30, 1, [4, 7]),
    scene(8, 1009, "Snow Trails in the Alps",
          "Backcountry ski touring along the Haute Route, from Chamonix toward Zermatt.",
          "2025-12-05", 65, 1800.0, 1920, 1080, "h264", 30, 3, [3, 5]),
    scene(9, 1010, "Sahara Stargazing",
          "A clear-sky timelapse of the Milky Way wheeling over the Erg Chebbi dunes.",
          "2025-07-22", 95, 720.0, 3840, 2160, "hevc", 30, 1, [1]),
    scene(10, 1011, "Fjord Kayak Day",
          "Sea kayak along Geirangerfjord with a cameo from a curious harbor seal.",
          "2025-06-11", 55, 1320.0, 1920, 1080, "h264", 25, 2, [0, 6]),
    scene(11, 1012, "Lighthouse on the Cape",
          "An afternoon at Cape Spear lighthouse — gulls, foghorn, and the Atlantic punching the cliff base.",
          "2025-05-28", 50, 540.0, 1920, 1080, "h264", 25, 2, [7]),
]


def parse_op_name(query: str) -> str:
    m = re.search(r"(query|mutation)\s+([A-Za-z_][A-Za-z0-9_]*)", query)
    return m.group(2) if m else ""


def apply_filter(scenes, scene_filter, find_filter):
    out = list(scenes)
    q = (find_filter or {}).get("q")
    if q:
        ql = q.lower()
        out = [s for s in out if ql in (s["title"] or "").lower()
               or ql in (s["details"] or "").lower()
               or any(ql in p["name"].lower() for p in s["performers"])]
    if scene_filter:
        rating = scene_filter.get("rating100")
        if rating:
            v = rating.get("value", 0)
            out = [s for s in out if (s.get("rating100") or 0) > v]
        ocrit = scene_filter.get("o_counter")
        if ocrit and ocrit.get("modifier") == "EQUALS":
            out = [s for s in out if (s.get("o_counter") or 0) == ocrit.get("value", 0)]

    sort_key = (find_filter or {}).get("sort", "date")
    direction = (find_filter or {}).get("direction", "DESC")
    keyfn = {
        "date": lambda s: s.get("date") or "",
        "title": lambda s: (s.get("title") or "").lower(),
        "rating": lambda s: s.get("rating100") or 0,
        "play_count": lambda s: s.get("play_count") or 0,
        "duration": lambda s: (s["files"][0]["duration"] if s["files"] else 0),
        "created_at": lambda s: int(s["id"]),
        "updated_at": lambda s: int(s["id"]),
    }
    if sort_key.startswith("random"):
        seed = 0
        if "_" in sort_key:
            try:
                seed = int(sort_key.split("_", 1)[1])
            except ValueError:
                seed = 0
        out.sort(key=lambda s: (hash(s["id"]) ^ seed) & 0xFFFFFFFF)
    else:
        out.sort(key=keyfn.get(sort_key, keyfn["date"]),
                 reverse=(direction == "DESC"))
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[mock] " + (fmt % args) + "\n")

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/__test__/activity":
            return self._json({"activity": ACTIVITY_LOG})
        m = re.match(r"^/scene/(\d+)/screenshot", self.path)
        if m:
            sid = m.group(1)
            path = os.path.join(THUMB_DIR, f"{sid}.jpg")
            if os.path.exists(path):
                with open(path, "rb") as fh:
                    data = fh.read()
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Cache-Control", "public, max-age=3600")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(404); self.end_headers(); return
        # Stream endpoint is a 404 stub — the player just shows the
        # loading state. Wire up a real video here (e.g. Big Buck Bunny)
        # if you need playback.
        self.send_response(404); self.end_headers()

    def do_POST(self):
        if self.path == "/__test__/reset":
            ACTIVITY_LOG.clear()
            return self._json({"reset": True})
        if not self.path.startswith("/graphql"):
            self.send_response(404); self.end_headers(); return
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else "{}"
        try:
            req = json.loads(body)
        except json.JSONDecodeError:
            return self._json({"errors": [{"message": "bad json"}]}, 400)
        query = req.get("query", "")
        variables = req.get("variables") or {}
        op = parse_op_name(query)

        if op == "Version":
            return self._json({"data": {"version": {"version": "v0.27.2"}}})

        if op == "FindScenes":
            ff = variables.get("filter") or {}
            sf = variables.get("scene_filter") or {}
            page = int(ff.get("page", 1))
            per_page = int(ff.get("per_page", 24))
            filtered = apply_filter(SCENES, sf, ff)
            start = (page - 1) * per_page
            slc = filtered[start:start + per_page]
            return self._json({"data": {
                "findScenes": {"count": len(filtered), "scenes": slc}
            }})

        if op == "FindScene":
            sid = str(variables.get("id"))
            for s in SCENES:
                if s["id"] == sid:
                    return self._json({"data": {"findScene": s}})
            return self._json({"data": {"findScene": None}})

        if op == "SceneSaveActivity":
            ACTIVITY_LOG.append({
                "id": str(variables.get("id")),
                "resume_time": variables.get("resume_time"),
                "playDuration": variables.get("playDuration"),
            })
            return self._json({"data": {"sceneSaveActivity": True}})

        if op == "SceneIncrementO":
            sid = str(variables.get("id"))
            for s in SCENES:
                if s["id"] == sid:
                    s["o_counter"] = (s.get("o_counter") or 0) + 1
                    return self._json({"data": {"sceneIncrementO": s["o_counter"]}})
            return self._json({"data": {"sceneIncrementO": 0}})

        if op == "SceneResetO":
            sid = str(variables.get("id"))
            for s in SCENES:
                if s["id"] == sid:
                    s["o_counter"] = 0
            return self._json({"data": {"sceneResetO": 0}})

        return self._json({"errors": [{"message": f"unknown op: {op!r}"}]}, 400)


if __name__ == "__main__":
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[mock] listening on http://{HOST}:{PORT}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
