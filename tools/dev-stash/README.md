# dev-stash

A real `stashapp/stash` server in Docker, plus a script that fills it
with sample clips. Use this when you need actual video playback,
transcoding, or the real GraphQL surface — things `tools/mock-stash/`
explicitly punts on.

For fast / offline / "I just want SFW thumbnails for screenshots" work,
use `tools/mock-stash/` instead.

## What it provides

- `stashapp/stash:v0.31.1` on `http://127.0.0.1:9999` (no auth).
- A library at `/data`, bind-mounted to `tools/dev-stash/media/` on
  the host (gitignored). `populate.sh` registers it via Stash's
  first-run `setup` mutation.
- A populate script that downloads ~20 short CC-BY sample clips
  (Blender open-movie derivatives at various resolutions / codecs /
  sizes), runs setup, and triggers a metadata scan.

## Two ways to boot Stash, one script to populate

Pick whichever fits your machine: Docker for portability, devenv for a
native binary on a Nix dev box. `populate.sh` works against either.

### Docker (compose.yml at repo root)

```sh
docker compose up -d                     # boots Stash on :9999
tools/dev-stash/populate.sh              # downloads clips + scans

STASH_URL=http://127.0.0.1:9999 \
  cargo run -p stash-player-ui           # point the app at it
```

Stop:

```sh
docker compose stop                      # keep the DB / clips
docker compose down -v                   # wipe the Stash DB (clips survive)
```

### devenv (devenv.nix at repo root)

```sh
devenv up                                # boots stash on :9999 (foreground)
# in another shell:
devenv shell                             # sets DEV_STASH_LIBRARY
tools/dev-stash/populate.sh              # same script, native backend

STASH_URL=http://127.0.0.1:9999 \
  cargo run -p stash-player-ui
```

Stop with Ctrl-C in the `devenv up` shell (or `devenv processes stop`).
Reset all Stash state with `rm -rf .devenv/state/stash` between runs.
Clips in `media/` survive.

Re-running `populate.sh` is a no-op once the library is populated.

The `media/` directory is gitignored — host-visible, easy to inspect,
never committed.

## Overrides

The populate script honours a few env vars:

| Var | Default | Meaning |
| --- | --- | --- |
| `DEV_STASH_URL` | `http://127.0.0.1:9999` | Where to talk to Stash. |
| `DEV_STASH_LIBRARY` | `/data` | Library path to register on first run. Compose uses `/data` (bind mount); devenv shell sets this to the absolute host path automatically. |
| `DEV_STASH_READY_TIMEOUT` | `60` | Seconds to wait for Stash to answer GraphQL on startup. |
| `DEV_STASH_SCAN_TIMEOUT` | `300` | Seconds to wait for `metadataScan` to finish. |

## Files

- `compose.yml` — at the repo root. One service, named volumes for
  Stash state, gitignored bind mount for the library.
- `clips.json` — the clip manifest. `{url, filename, license, source}`
  per entry.
- `ATTRIBUTION.md` — per-source attribution. Most clips are CC-BY 3.0
  (Blender Foundation derivatives); attribution is recorded here.
- `populate.sh` — the bash script described above. Requires `curl`
  and `jq`.
- `media/` — destination for downloaded clips, gitignored.

## Adding clips

1. Append a `{url, filename, license, source}` entry to `clips.json`.
2. Add a matching attribution bullet to `ATTRIBUTION.md`.
3. Re-run `populate.sh` — only the new clip is downloaded, then the
   scan picks it up.

URLs must respond to a plain `curl -fL`. The script logs a warning and
continues if a single URL 404s, so one rotten link doesn't block the
rest of the population run.

## Why not `mock-stash`?

`mock-stash` is faster, has no Docker dependency, and ships
hand-picked SFW gradient thumbnails that are safe to use in
screenshots. But it serves a 404 for `/scene/<id>/stream`, so anything
that depends on real playback can't be exercised against it. That's
exactly the gap this directory fills.

## Pinning Stash's version

- **Compose**: `compose.yml` pins the image tag (e.g.
  `stashapp/stash:v0.31.1`). Stash's GraphQL surface changes between
  versions and the populate script's mutations (`setup`,
  `metadataScan`, `findJob`) shift shape occasionally — pinning
  eliminates that whole class of silent breakage.
- **devenv**: tracks `pkgs.stash` from the pinned nixpkgs in
  `devenv.lock`. Update by editing `devenv.yaml` or running
  `devenv update`. The nixpkgs version may lag the upstream release
  that the compose tag points at (typically by a few months); if a
  mutation shifts shape between them, `populate.sh` will surface a
  GraphQL error rather than silently misbehave.
