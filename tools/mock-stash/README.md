# mock-stash

A tiny stand-in Stash GraphQL server for offline UI work — demos,
screenshots, manual testing without a real Stash instance.

The data set is **12 SFW landscape-themed scenes** with pre-rendered
gradient thumbnails (Aurora Over Tromsø, Kyoto Cherry Blossoms, …), so
it's safe to point at when grabbing screenshots for the README or a
release.

## What it implements

The subset of the Stash schema that `stash-player` actually calls:

- `Version`
- `FindScenes` (search, sort, paging, rating filter, hide-tracked, random seed)
- `FindScene`
- `SceneSaveActivity`
- `SceneIncrementO` / `SceneResetO`
- `GET /scene/<id>/screenshot` — serves the matching JPG from `thumbs/`
- `GET /scene/<id>/stream` — 404 stub (the player just spins)

That's enough to drive the library, scene detail, search/sort/filter,
and the O-counter UI. Video playback won't work — wire `paths.stream`
to a real video URL in `server.py` if you need that.

## Usage

```sh
# 1. Start the mock (Python 3 stdlib only)
python3 tools/mock-stash/server.py
# [mock] listening on http://127.0.0.1:9999

# 2. In another shell, point the UI at it. Move .env aside first if
#    it's pinning you to a real instance — dotenv won't override an
#    already-set var, but a stale .env will pre-populate the wrong URL
#    if you launch without env overrides:
mv .env .env.disabled  # only if .env points elsewhere

STASH_URL=http://127.0.0.1:9999 \
STASH_API_KEY=mocktoken \
cargo run -p stash-player-ui
```

The UI hits the mock just like a real Stash; thumbnails come from
`tools/mock-stash/thumbs/<id>.jpg`.

### Override host/port

```sh
MOCK_STASH_HOST=0.0.0.0 MOCK_STASH_PORT=8080 python3 tools/mock-stash/server.py
```

### Isolate from your real config

If you don't want the mock URL to overwrite your normal
`~/.config/stash-player/config.toml`:

```sh
XDG_CONFIG_HOME=/tmp/mock-config \
XDG_CACHE_HOME=/tmp/mock-cache \
STASH_URL=http://127.0.0.1:9999 STASH_API_KEY=mocktoken \
cargo run -p stash-player-ui
```

## Files

- `server.py` — the mock server. Edit `SCENES` at the top to change titles,
  studios, performers, ratings, durations, etc.
- `thumbs/<id>.jpg` — pre-rendered gradient thumbnails (12 files,
  640×360, ~10 KB each). Checked in; no need to regenerate.
- `gen_thumbs.sh` — regenerate the thumbnails from the gradient/title
  table. Only needed if you change the scene list or art. Requires
  `ffmpeg` and `fc-match`.

## Adding scenes

1. Append a `scene(...)` row to `SCENES` in `server.py`.
2. Add a matching `"<id>|Title|<hex_top>|<hex_bottom>"` entry to
   `SCENES` in `gen_thumbs.sh` and run it (or drop a JPG into `thumbs/`
   yourself — anything goes, as long as the filename is `<id>.jpg`).
