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


[private]
default:
    @just --list

# ---------------------------------------------------------------- backends

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
    @echo "stash   : ${STASH_URL-(saved settings)}"
    @echo "socks   : ${STASH_SOCKS_PROXY-(saved settings)}"

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
#
# Each STASH_* variable is forwarded only when it is genuinely set in the
# calling shell. The app treats a variable that is merely *present* as an
# override, empty value included, so forwarding a defaulted-to-empty one
# would silently wipe whatever the connection screen has saved and leave
# that screen with no effect on a `just` launch.
[macos]
flutter-launch:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{ app_bundle }}" ]; then
      echo "No build at {{ app_bundle }} — run: just flutter-build" >&2
      exit 2
    fi

    # Seeded with the base environment rather than built up from empty:
    # bash 3.2, which is what /bin/bash still is on macOS, treats
    # "${array[@]}" as an unbound variable under `set -u` when the array
    # has no elements, and would abort the launch whenever nothing is
    # being overridden.
    launch_env=(HOME="$HOME" USER="$USER" TMPDIR=/tmp LANG=en_US.UTF-8
                PATH=/usr/bin:/bin:/usr/sbin:/sbin)
    overridden=""
    override() {
      launch_env+=("$1=$2")
      overridden="$overridden $1"
    }

    if [ -n "${STASH_URL+set}" ]; then
      override STASH_URL "$STASH_URL"
    fi
    if [ -n "${STASH_SOCKS_PROXY+set}" ]; then
      override STASH_SOCKS_PROXY "$STASH_SOCKS_PROXY"
    fi
    # An explicitly empty STASH_API_KEY is a valid override (an
    # unauthenticated server), so the keychain is consulted only when the
    # variable is genuinely unset, and only when a server is being
    # overridden too: a key without one belongs to whichever server the app
    # already has saved.
    if [ -n "${STASH_API_KEY+set}" ]; then
      override STASH_API_KEY "$STASH_API_KEY"
    elif [ -n "${STASH_URL+set}" ]; then
      key="$(security find-generic-password -s stash-player -a stash-api-key -w 2>/dev/null || true)"
      if [ -n "$key" ]; then
        override STASH_API_KEY "$key"
      fi
    fi

    if [ -z "$overridden" ]; then
      echo "launching against the app's saved connection"
    else
      echo "launching with$overridden overridden"
    fi
    exec env -i "${launch_env[@]}" \
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
