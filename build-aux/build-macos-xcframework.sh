#!/usr/bin/env bash
# Build the stash-player-ffi staticlib, generate Swift UniFFI bindings, and
# package both into an XCFramework that the SwiftUI app at apps/macos/ can
# link against. Walking-skeleton: aarch64-apple-darwin only. To add Intel,
# append "x86_64-apple-darwin" to TARGETS and run `lipo -create` before
# xcodebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

CRATE="stash-player-ffi"
LIB_NAME="libstash_player_ffi.a"
PROFILE="release"
TARGETS=("aarch64-apple-darwin")
# Match the Swift target's deployment floor so the linker doesn't complain
# about "object file built for newer macOS than being linked".
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
OUT_FRAMEWORK="$ROOT/apps/macos/StashPlayerFFI.xcframework"
BINDINGS_DIR="$ROOT/apps/macos/StashPlayer/Generated"

echo "==> Ensuring rust targets are installed"
for t in "${TARGETS[@]}"; do
    rustup target list --installed | grep -q "^${t}$" || rustup target add "$t"
done

echo "==> Building $CRATE for ${TARGETS[*]} ($PROFILE)"
for t in "${TARGETS[@]}"; do
    cargo build -p "$CRATE" --$PROFILE --target "$t"
done

LIB_PATH="$ROOT/target/${TARGETS[0]}/$PROFILE/$LIB_NAME"

echo "==> Generating Swift bindings"
mkdir -p "$BINDINGS_DIR"
# Wipe stale generated artifacts so renames in lib.rs don't leave dead files
# floating in the Swift target.
rm -f "$BINDINGS_DIR"/*.swift "$BINDINGS_DIR"/*.h "$BINDINGS_DIR"/*.modulemap
cargo run -p "$CRATE" --bin uniffi-bindgen --$PROFILE -- \
    generate --library "$LIB_PATH" --language swift --out-dir "$BINDINGS_DIR"

echo "==> Composing module headers dir"
HEADERS_DIR="$(mktemp -d -t stash-player-ffi-headers)"
trap 'rm -rf "$HEADERS_DIR"' EXIT
cp "$BINDINGS_DIR"/*.h "$HEADERS_DIR/"
# xcodebuild expects the modulemap to be named exactly `module.modulemap`.
MODMAP="$(find "$BINDINGS_DIR" -maxdepth 1 -name '*.modulemap' | head -1)"
if [ -z "$MODMAP" ]; then
    echo "error: no .modulemap produced by uniffi-bindgen in $BINDINGS_DIR" >&2
    exit 1
fi
cp "$MODMAP" "$HEADERS_DIR/module.modulemap"

echo "==> Creating XCFramework"
rm -rf "$OUT_FRAMEWORK"
xcodebuild -create-xcframework \
    -library "$LIB_PATH" -headers "$HEADERS_DIR" \
    -output "$OUT_FRAMEWORK" >/dev/null

echo
echo "Framework:      $OUT_FRAMEWORK"
echo "Swift bindings: $BINDINGS_DIR"
