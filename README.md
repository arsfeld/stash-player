# Stash Player

Desktop client for [Stash](https://github.com/stashapp/stash): browse your
library and play scenes locally with hardware-accelerated video, with watch
progress and play counts synced back to Stash. Built with Flutter
(`apps/flutter/`), shipped as a Linux Flatpak and a notarized, self-updating
macOS app.

## Features

- Browse your library with search, sort (title / date / rating / random / …),
  rating filter, organized filter, and a "hide tracked" switch that defaults to
  untracked-only so the grid opens to fresh material.
- "Play random" shortcut from the toolbar.
- Inline scene player with mpv-style keyboard shortcuts and hardware-accelerated
  playback via libmpv (VA-API where available).
- Video-first scene detail pages: the player fills the page, with
  performers, details, and file info tucked into a slide-over drawer so
  they never resize the video. "Open in Stash" lives in the header menu.
- Resume where you left off — watch progress and play counts sync back to Stash
  automatically (`sceneSaveActivity`), throttled and flushed on pause / seek /
  close.
- Prev/next navigation (honouring the library's current filter), a
  per-scene "O counter" with increment + reset, and the star rating all
  render right on the player's on-screen controls.
- API key stored in the system keyring (Secret Service on Linux, Keychain on
  macOS), with an optional SOCKS proxy for servers reachable only over a
  tailnet.
- On first launch, an existing connection saved by an older Stash Player
  install is imported automatically — see [apps/flutter/README.md](apps/flutter/README.md#upgrading-from-the-legacy-clients).

## Install

### Linux (Flatpak)

Download `stash-player.flatpak` from the [latest GitHub
release](https://github.com/arsfeld/stash-player/releases/latest), then:

```sh
curl -L -o stash-player.flatpak \
  https://github.com/arsfeld/stash-player/releases/latest/download/stash-player.flatpak

flatpak install --user stash-player.flatpak
flatpak run dev.arsfeld.stash-player
```

The bundle ships the binary and assets only; the GNOME 50 runtime comes from
Flathub, so the Flathub remote needs to be configured
(`flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo`
if it isn't already — most desktop systems have it out of the box). To
upgrade later, repeat the download + `flatpak install` step with the new
bundle.

### macOS (Apple Silicon)

Download `StashPlayer-macos-arm64.zip` from the [latest GitHub
release](https://github.com/arsfeld/stash-player/releases/latest), unzip it,
and move `StashPlayer.app` to `/Applications`:

```sh
curl -L -o StashPlayer-macos-arm64.zip \
  https://github.com/arsfeld/stash-player/releases/latest/download/StashPlayer-macos-arm64.zip

unzip StashPlayer-macos-arm64.zip -d /Applications
open /Applications/StashPlayer.app
```

It's Developer ID–signed and notarized, so Gatekeeper opens it without a
warning, and it updates itself through the app menu's "Check for
Updates…" (Sparkle). Requires macOS 14 (Sonoma) or later on Apple Silicon.

## Repository layout

```
stash-player/
├── apps/
│   ├── flutter/                 # The shipped client (Linux + macOS) — see its own README
│   └── macos/                   # Legacy SwiftUI app (frozen, not released)
├── crates/                      # Legacy Rust workspace backing the frozen GTK/SwiftUI clients
├── data/                        # .desktop, AppStream metainfo, icon
├── build-aux/                   # Flatpak manifest, macOS xcframework script
└── flake.nix                    # Nix dev shells
```

## Development

The shipped app lives in `apps/flutter/`. See
[`apps/flutter/README.md`](apps/flutter/README.md) for full setup, build,
and troubleshooting instructions. Quick start:

```sh
nix develop .#flutter
just flutter-run      # build + launch, wired to STASH_URL/STASH_API_KEY overrides
just flutter-check    # format + analyze + test, mirrors CI
```

`just --list` shows every recipe, including the platform-specific ones
(`flutter-build`, `flutter-launch`, `flutter-env`).

A local Flatpak build (rather than the prebuilt bundle above) is one
command via the Nix flake:

```sh
nix run .#flatpak
flatpak run dev.arsfeld.stash-player
```

## Configuration

On first launch, open **Stash server** and enter:

- **URL** — e.g. `https://stash.example.tld`
- **API key** — optional; copy it from Stash's *Settings → Security → API Key*
  when auth is enabled

Click **Test connection** to confirm. The URL and any SOCKS proxy persist to
platform preferences; the API key goes to the system keyring.

## Local development backend

Three options for running the app against something other than your real
Stash server, all driven by the same `tools/dev-stash/populate.sh`:

| | `tools/mock-stash/` | `compose.yml` | `devenv.nix` |
| --- | --- | --- | --- |
| Backend | Python stub | `stashapp/stash` in Docker | Native `pkgs.stash` (Nix) |
| Video playback | No (404s on `/stream`) | Yes | Yes |
| Setup | `python3 server.py` | `docker compose up -d` | `devenv up` |
| State location | none | named Docker volumes | `.devenv/state/stash/` |
| Reset | restart | `docker compose down -v` | `rm -rf .devenv/state/stash` |
| Good for | Screenshots, offline UI work | Linux/macOS, no Nix needed | Fastest on Nix dev machines |

### Compose (Docker)

```sh
docker compose up -d                 # boots Stash at http://127.0.0.1:9999
tools/dev-stash/populate.sh          # downloads clips + triggers scan
```

`docker compose down -v` wipes the Stash DB; the gitignored
`tools/dev-stash/media/` survives so clips don't re-download.

### devenv (native, Nix-based)

```sh
devenv up                            # boots stash on :9999
devenv shell                         # in another terminal — sets DEV_STASH_LIBRARY
tools/dev-stash/populate.sh          # same script, native backend
```

Stop with Ctrl-C / `devenv processes stop`. State (DB, blobs, generated)
lives under `.devenv/state/stash/`; remove it to reset.

See [`tools/dev-stash/README.md`](tools/dev-stash/README.md) for details and
[`tools/dev-stash/ATTRIBUTION.md`](tools/dev-stash/ATTRIBUTION.md) for clip
sources / licences.

## Keyboard shortcuts (player)

| Key | Action |
| --- | --- |
| `Space` / `k` | Play / pause |
| `←` / `→` | Seek ∓5s |
| `j` / `l` | Seek ∓10s |
| `↑` / `↓` | Seek ±60s |
| `Home` / `End` | Seek to start / end |
| `9` / `0` | Volume ∓5% |
| `m` | Mute |
| `f` | Toggle fullscreen |
| `Esc` | Exit fullscreen |

Fullscreen isn't implemented yet — `f`/`Esc` are wired but currently a
no-op; see [`apps/flutter/README.md`](apps/flutter/README.md#keyboard-shortcuts-player).

## Legacy clients (frozen, not released)

`crates/stash-player-ui` (GTK4 + libadwaita, relm4, GStreamer) and
`apps/macos` (SwiftUI + AVKit) are the original Linux and macOS clients.
Both remain buildable but are no longer released or updated — `apps/flutter/`
has taken over both app identities and their update channel. See
[`docs/superpowers/specs/2026-09-23-flutter-first-class-release-design.md`](docs/superpowers/specs/2026-09-23-flutter-first-class-release-design.md)
for why.

Rust prerequisites and system deps: `nix develop` (pulls Rust + GTK4 +
libadwaita + the GStreamer plugin set + libsecret), or without Nix, `gtk4`,
`libadwaita`, `gstreamer1.0` (`base`/`good`/`bad`/`ugly`/`libav` plugins),
`gst-plugin-gtk4`, `libsecret`, `pkg-config`, `openssl`.

```sh
# GTK client (Linux)
nix develop
cargo run -p stash-player-ui

# SwiftUI app (macOS) — Xcode 16+, xcodegen (brew install xcodegen)
nix run .#macos               # rust → xcframework → xcodeproj → xcodebuild → launch
nix run .#macos-build         # same, minus the launch (refreshes Generated/)
```

## License

MIT — see [LICENSE](LICENSE).
