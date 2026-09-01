# Task runner for stash-player.
#
# Two macOS environment traps are baked into the recipes here, because both
# cost real debugging time to find:
#
#   1. This repo auto-loads `nix develop` through direnv. That shell puts
#      clang-wrapper's `ld` and xcbuild's `xcrun` ahead of Xcode's and exports
#      CC/LD/SDKROOT/NIX_LDFLAGS, which makes xcodebuild reject `-Xlinker`
#      flags and SPM resolution die on `arch: xcrun: Bad CPU type`. Clearing
#      PATH is not enough; the Flutter macOS recipes use `env -i`.
#   2. `STASH_URL` / `STASH_API_KEY` are read from the app's own process
#      environment. Launching through `open` (or the Finder) goes via
#      LaunchServices, which inherits no shell environment, so the app falls
#      back to its connection screen. `flutter-launch` execs the binary.

set shell := ["bash", "-euo", "pipefail", "-c"]

flutter_dir := justfile_directory() / "apps/flutter"
app_bundle := flutter_dir / "build/macos/Build/Products/Debug/Stash Player Flutter.app"

# Resolved once, in the ambient shell, so the clean-env recipes below can
# still find these after `env -i` drops PATH.
flutter_bin := `command -v flutter 2>/dev/null || true`
pod_bin := `command -v pod 2>/dev/null || true`

# Where the Flutter client should look for Stash. Defaults to the bridge.
bridge_port := env("SOCKS_BRIDGE_PORT", "18999")
stash_url := env("STASH_URL", "http://127.0.0.1:" + bridge_port)
# Real server behind the SOCKS proxy. No default: nobody else's host belongs
# in a checked-in file.
stash_upstream := env("STASH_UPSTREAM", "")

[private]
default:
    @just --list

# ---------------------------------------------------------------- backends

# Front a SOCKS5-only Stash server (Tailscale userspace mode) on localhost.
bridge upstream=stash_upstream:
    @if [ -z "{{ upstream }}" ]; then \
      echo "Pass an upstream or set STASH_UPSTREAM:" >&2; \
      echo "  just bridge https://stash.example.ts.net" >&2; \
      exit 2; \
    fi
    SOCKS_BRIDGE_UPSTREAM="{{ upstream }}" \
    SOCKS_BRIDGE_PORT="{{ bridge_port }}" \
    SOCKS_BRIDGE_VERBOSE="${SOCKS_BRIDGE_VERBOSE:-1}" \
      python3 tools/socks-bridge/server.py

# Offline mock Stash. Library and metadata work; /stream is a 404 by design.
mock:
    python3 tools/mock-stash/server.py

# Real Stash in Docker, then load the sample clips.
stash-up:
    docker compose up -d
    tools/dev-stash/populate.sh

stash-down:
    docker compose down

# ----------------------------------------------------------------- flutter

# Show which toolchain the Flutter macOS recipes will actually use.
[macos]
flutter-env:
    @echo "flutter : {{ if flutter_bin == "" { "NOT FOUND" } else { flutter_bin } }}"
    @echo "pod     : {{ if pod_bin == "" { "NOT FOUND" } else { pod_bin } }}"
    @{{ _clean }} sh -c 'echo "xcrun   : $(command -v xcrun) ($(xcrun --version | head -1))"'
    @{{ _clean }} sh -c 'echo "sdk     : $(xcrun --sdk macosx --show-sdk-path)"'
    @echo "stash   : {{ stash_url }}"

# Everything CI checks, in CI's order.
flutter-check: _needs-flutter
    cd {{ flutter_dir }} && {{ _flutter }} pub get
    cd {{ flutter_dir }} && {{ _dart }} format --output=none --set-exit-if-changed .
    cd {{ flutter_dir }} && {{ _flutter }} analyze --fatal-infos --fatal-warnings
    cd {{ flutter_dir }} && {{ _flutter }} test

flutter-fmt: _needs-flutter
    cd {{ flutter_dir }} && {{ _dart }} format .

# Build the debug .app outside the Nix shell.
[macos]
flutter-build: _needs-flutter
    cd {{ flutter_dir }} && {{ _flutter }} build macos --debug

# Build, then launch with the environment overrides actually applied.
[macos]
flutter-run: flutter-build flutter-launch

# Launch the already-built .app. Rebuild with `flutter-build` after Dart edits.
# Single shell (shebang recipe) because the key lookup has to reach the exec.
[macos]
flutter-launch:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{ app_bundle }}" ]; then
      echo "No build at {{ app_bundle }} — run: just flutter-build" >&2
      exit 2
    fi
    # An explicitly empty STASH_API_KEY is a valid override (unauthenticated
    # server), so only fall back to the keychain when it is genuinely unset.
    if [ -n "${STASH_API_KEY+set}" ]; then
      key="$STASH_API_KEY"
    else
      key="$(security find-generic-password -s stash-player -a stash-api-key -w 2>/dev/null || true)"
    fi
    echo "launching against {{ stash_url }}"
    exec env -i HOME="$HOME" USER="$USER" TMPDIR=/tmp LANG=en_US.UTF-8 \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      STASH_URL="{{ stash_url }}" STASH_API_KEY="$key" \
      "{{ app_bundle }}/Contents/MacOS/Stash Player Flutter"

# -------------------------------------------------------------------- rust

test:
    cargo test -p stash-api -p stash-player-core

lint:
    cargo clippy --workspace --all-targets -- -D warnings

run:
    cargo run -p stash-player-ui

# ----------------------------------------------------------------- helpers

[private]
_needs-flutter:
    @if [ -z "{{ flutter_bin }}" ]; then \
      echo "flutter not on PATH — try: nix develop .#flutter" >&2; \
      exit 2; \
    fi

# Escapes the Nix dev shell so Xcode's own linker and xcrun win.
[private]
_clean := "env -i HOME=$HOME USER=$USER TMPDIR=/tmp LANG=en_US.UTF-8 PATH=" + parent_directory(flutter_bin) + ":" + parent_directory(pod_bin) + ":/usr/bin:/bin:/usr/sbin:/sbin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"

[private]
_flutter := _clean + " " + flutter_bin

[private]
_dart := _clean + " " + parent_directory(flutter_bin) / "dart"
