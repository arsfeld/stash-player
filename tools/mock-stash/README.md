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

### Test-only observability

Not part of the Stash schema — added purely so client integration tests
(e.g. the Flutter smoke test in `apps/flutter/integration_test/`) can
assert on activity writeback without a real Stash instance. `/stream`
stays a documented 404; these endpoints add **no** real video and **no**
authentication bypass:

- `GET /__test__/activity` — every accepted `SceneSaveActivity` call so
  far, in call order, as `{"activity": [{"id", "resume_time",
  "playDuration"}, ...]}`.
- `POST /__test__/reset` — clears the recorded activity log only (scene
  state such as `o_counter` is untouched).

```sh
curl http://127.0.0.1:9999/__test__/activity
curl -X POST http://127.0.0.1:9999/__test__/reset
```

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

This matters more than it sounds: **9999 is a common default for a real
Stash instance too** (a personal server, `docker compose up -d`,
`devenv up`, ...). If one is already listening on this host, the mock
will fail to start with `OSError: [Errno 98] Address already in use`.
Don't stop whatever else owns port 9999 — run the mock (and whatever
you're pointing at it, e.g. `apps/flutter`'s integration smoke test) on
an alternate port instead:

```sh
MOCK_STASH_PORT=19999 python3 tools/mock-stash/server.py
# then point your client's STASH_URL at http://127.0.0.1:19999
```

CI runners don't hit this — nothing else is listening on a fresh
runner — so every committed default (this file, `apps/flutter/README.md`,
`.github/workflows/flutter.yml`) keeps using `9999` unchanged.

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
