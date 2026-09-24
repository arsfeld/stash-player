# Flutter First-Class Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Flutter app (`apps/flutter/`) as the one released Stash Player: a Flatpak on Linux and a signed, notarized, Sparkle-updating app on macOS. It takes over the existing app IDs and imports each user's saved connection. Then merge `flutter` into `main` and tag `v1.0.0`.

**Architecture:**
- **Linux:** the Flatpak builds libass, libplacebo, and libmpv from source, then builds the Flutter bundle inside flatpak-builder, with network access for the SDK and pub.
- **macOS:** the release is the Flutter Runner, unsandboxed with the hardened runtime and Sparkle 2 (via CocoaPods). It is built by `xcodebuild` using the existing Developer ID and notarization pipeline.
- **Connection import:** a small Dart service reads the legacy `config.toml`, and a native method channel reads the legacy keychain or Secret Service entry. It runs once from `PlatformConnectionStore.loadStored`.

**Tech Stack:** Flutter 3.41.6 / Dart 3.11, media_kit (libmpv), flutter_secure_storage 11, shared_preferences, `toml` pub package, GTK3 runner (C++) with libsecret, AppKit runner (Swift) with Sparkle 2.9, flatpak-builder (GNOME 50 SDK + llvm21 extension), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-23-flutter-first-class-release-design.md`

## Global Constraints

- App ID on both platforms: `dev.arsfeld.stash-player`. Display name: `Stash Player`. Linux binary: `stash-player`. macOS bundle filename: `StashPlayer.app` (`PRODUCT_NAME = StashPlayer`).
- No user-visible "Flutter" or "experimental" string anywhere in the shipped app.
- Internal names don't change: the `apps/flutter/` directory, the Dart package `stash_player_flutter`, the preference keys `dev.arsfeld.stashplayer.flutter.*`, and the thumbnail cache segment.
- Flutter SDK version: 3.41.6 everywhere. The Flatpak archive sha256 is `503b3e6b7d352fca5d21b6474eca95ad544d8fc3b053782eab63a360c7fc7569`.
- macOS: deployment target 14.0, arm64 only, no App Sandbox, hardened runtime on. `CFBundleShortVersionString` = `CFBundleVersion` = the tag version without the `v` (`0.0.0` on non-tag builds).
- Sparkle: `SUFeedURL = https://arsfeld.github.io/stash-player/appcast.xml`, `SUPublicEDKey = Fx+Cc8kj5pSdtx3i/E+AhMmLUgefc8EXD1CxFh2VO5A=`, `SUEnableAutomaticChecks = true`, Sparkle `~> 2.9`.
- Legacy keychain / Secret Service identifiers: service/application `stash-player`, account/key `stash-api-key`.
- Legacy config: `stash_url` and `proxy_url` in `config.toml`.
  - macOS: `~/Library/Application Support/one.arsfeld.stash-player/config.toml`.
  - Linux: `$XDG_CONFIG_HOME/stash-player/config.toml`, then `$HOME/.config/stash-player/config.toml`.
- Flutter gates must stay green: `dart format --set-exit-if-changed`, `flutter analyze --fatal-infos --fatal-warnings`, `flutter test`. Run them with `just flutter-check` from the repo root.
- Rust gates must stay green: `cargo test -p stash-api -p stash-player-core`, `cargo clippy --workspace --all-targets -- -D warnings` (inside `nix develop`).
- `/docs` is gitignored. Add files under `docs/` with `git add -f`.
- Commit messages follow the repo style (`feat(flutter): …`, `fix(flutter): …`, `ci: …`, `docs: …`). No attribution trailers.

## Which tasks need which machine

| Tasks | Where verified |
|---|---|
| 0, 1, 2, 3, 7, 8 (Dart + Linux C), 9, 10, 11 | Linux dev box with `nix develop .#flutter` and `flatpak-builder` |
| 4, 5, 6, 8 (Swift half) | GitHub Actions `macos-15` via the draft PR opened in Task 0; a Mac for the runtime checks |
| 12 | Mac + Linux (manual release gates) |

## File map

| File | Responsibility | Tasks |
|---|---|---|
| `apps/flutter/linux/CMakeLists.txt` | Linux binary name and app ID | 1 |
| `apps/flutter/linux/runner/my_application.cc` | GTK window title; legacy-secret channel (libsecret) | 1, 8 |
| `apps/flutter/linux/runner/CMakeLists.txt` | Links libsecret into the runner | 8 |
| `apps/flutter/lib/app/app.dart`, `test/app/app_smoke_test.dart` | `MaterialApp.title` | 1 |
| `apps/flutter/windows/runner/Runner.rc` | Windows version-resource strings | 1 |
| `build-aux/dev.arsfeld.stash-player.yml` | Flatpak manifest (rewritten) | 2 |
| `.github/workflows/flatpak.yml` | Flatpak CI cache key and triggers | 3 |
| `apps/flutter/macos/Runner/Configs/AppInfo.xcconfig`, `Configs/Release.xcconfig`, `Info.plist`, `Release.entitlements`, `DebugProfile.entitlements`, `Base.lproj/MainMenu.xib`, `Assets.xcassets/AppIcon.appiconset/*`, `Runner.xcodeproj/project.pbxproj`, `macos/Podfile` | macOS identity, entitlements, deployment target | 4 |
| `apps/flutter/lib/services/platform_connection_store.dart` | macOS keychain option; legacy import hook | 4, 9 |
| `apps/flutter/macos/Runner/AppDelegate.swift`, `Base.lproj/MainMenu.xib`, `Info.plist`, `macos/Podfile` | Sparkle updater and menu item | 5 |
| `.github/workflows/macos.yml` | Flutter macOS build, sign, notarize, release, appcast | 6 |
| `apps/flutter/lib/services/legacy_config.dart` (new) | Legacy `config.toml` paths and parsing | 7 |
| `apps/flutter/lib/services/legacy_secret_reader.dart` (new) | Dart side of the legacy-secret channel | 8 |
| `apps/flutter/macos/Runner/MainFlutterWindow.swift` | macOS legacy-secret channel (Keychain) | 8 |
| `apps/flutter/lib/services/legacy_connection_importer.dart` (new) | Combines config + secret into a `ConnectionConfig` | 9 |
| `.github/workflows/{flutter,tests}.yml` | Trigger/path cleanup | 10 |
| `README.md`, `apps/flutter/README.md`, `CLAUDE.md`, `PLAN.md`, `justfile`, `data/dev.arsfeld.stash-player.metainfo.xml` | Docs, dev recipes, AppStream | 11 |

---

### Task 0: Merge `main` into `flutter` and open the draft PR

**Files:**
- Modify (conflicts): `CLAUDE.md`, `README.md`, `PLAN.md`, `.gitignore`, `.github/workflows/macos.yml`, `.github/workflows/tests.yml`, plus anything else git reports

**Interfaces:**
- Produces: a `flutter` branch that contains all of `main`, and a draft PR `flutter → main` whose CI runs on every later push.

- [ ] **Step 1: Merge**

```bash
cd /home/arosenfeld/Code/stash-player
git checkout flutter
git fetch origin
git merge origin/main
```

Expected: conflicts in some of the files listed above.

- [ ] **Step 2: Resolve conflicts with these rules**

- `crates/**`, `apps/macos/**`, `Cargo.lock`, `.github/workflows/macos.yml`, `.github/workflows/tests.yml`: take `main`'s side (`git checkout --theirs <path>`). Task 6 rewrites `macos.yml` anyway, and the Rust/Swift code only changed on `main`.
- `.gitignore`: keep the union of both sides' lines.
- `CLAUDE.md`, `README.md`, `PLAN.md`: keep both sides' content (main's proxy docs and the flutter branch's Flutter docs). Task 11 restructures them, so aim for correctness, not polish.
- `docs/superpowers/**`: keep both files where they differ by name. If both sides touched the same file, take the union.

Then:

```bash
git add -A
git commit --no-edit
```

- [ ] **Step 3: Verify both toolchains are green**

```bash
nix develop --command cargo test -p stash-api -p stash-player-core
nix develop --command cargo clippy --workspace --all-targets -- -D warnings
just flutter-check
```

Expected: all pass. If clippy fails, the failure came from `main` and must be fixed in a separate `fix:` commit on this branch before continuing.

- [ ] **Step 4: Push and open a draft PR**

```bash
git push origin flutter
gh pr create --draft --base main --head flutter \
  --title "Ship the Flutter client as Stash Player 1.0" \
  --body "Implements docs/superpowers/specs/2026-09-23-flutter-first-class-release-design.md. Draft until the release gates in the plan pass."
```

Expected: the PR URL is printed. `Flutter`, `Flatpak`, `macOS`, and `Tests` workflows start. `Flatpak` and `macOS` will build the legacy apps until Tasks 2/6 land; that's fine.

---

### Task 1: Linux and shared identity

**Files:**
- Modify: `apps/flutter/linux/CMakeLists.txt:7,10`
- Modify: `apps/flutter/linux/runner/my_application.cc:48,52`
- Modify: `apps/flutter/lib/app/app.dart:55`
- Modify: `apps/flutter/test/app/app_smoke_test.dart:18`
- Modify: `apps/flutter/windows/runner/Runner.rc:93,95,98`
- Modify: `justfile:21`

**Interfaces:**
- Produces: the Linux release bundle's executable is `build/linux/<arch>/release/bundle/stash-player`, and the GTK app ID is `dev.arsfeld.stash-player`. Task 2 relies on both.

- [ ] **Step 1: Write the failing test**

In `apps/flutter/test/app/app_smoke_test.dart`, change the expectation:

```dart
    expect(app.title, 'Stash Player');
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `nix develop .#flutter --command bash -c 'cd apps/flutter && flutter test test/app/app_smoke_test.dart'`
Expected: FAIL, `Expected: 'Stash Player'  Actual: 'Stash Player Flutter'`.

- [ ] **Step 3: Rename everywhere**

`apps/flutter/lib/app/app.dart` line 55:

```dart
      title: 'Stash Player',
```

`apps/flutter/linux/CMakeLists.txt`:

```cmake
set(BINARY_NAME "stash-player")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
# Shared with the Flatpak manifest, the .desktop file, and the AppStream
# metainfo in data/ — the Wayland app-id / X11 WM class must match the
# .desktop basename or the shell shows a generic icon.
set(APPLICATION_ID "dev.arsfeld.stash-player")
```

`apps/flutter/linux/runner/my_application.cc`: replace both `"Stash Player Flutter"` literals with `"Stash Player"`.

`apps/flutter/windows/runner/Runner.rc`: replace the three `"Stash Player Flutter"` values (FileDescription, InternalName, ProductName) with `"Stash Player"`.

`justfile` line 21:

```just
linux_bundle := flutter_dir / "build/linux" / linux_arch / "debug/bundle/stash-player"
```

- [ ] **Step 4: Run the tests and the Linux build**

```bash
just flutter-check
just flutter-build
ls apps/flutter/build/linux/x64/debug/bundle/stash-player
```

Expected: all checks pass, and the binary exists.

- [ ] **Step 5: Smoke-launch against the mock**

```bash
just mock &   # background; kill it afterwards
just flutter-launch
```

Expected: the window title reads "Stash Player", and the library loads from the mock. On GNOME, `Alt+F2 → lg → Windows` shows wmclass `dev.arsfeld.stash-player`. Close the app and stop the mock.

- [ ] **Step 6: Commit**

```bash
git add apps/flutter/linux apps/flutter/lib/app/app.dart apps/flutter/test/app/app_smoke_test.dart apps/flutter/windows/runner/Runner.rc justfile
git commit -m "feat(flutter): take over the Stash Player identity on Linux"
```

---

### Task 2: Flatpak manifest (spike, then keep)

This task is the risk spike from the spec. If Step 3 can't be made to pass after a focused effort (roughly half a day), stop and report back. The fallback is `flatpak-flutter` offline sources, which needs a new plan.

**Files:**
- Rewrite: `build-aux/dev.arsfeld.stash-player.yml`

**Interfaces:**
- Consumes: the `stash-player` binary name and the `dev.arsfeld.stash-player` app ID from Task 1.
- Produces: a manifest that `nix run .#flatpak` and `flatpak.yml` build unchanged.

- [ ] **Step 1: Write the manifest**

Replace `build-aux/dev.arsfeld.stash-player.yml` entirely:

```yaml
app-id: dev.arsfeld.stash-player
runtime: org.gnome.Platform
runtime-version: '50'
sdk: org.gnome.Sdk
sdk-extensions:
  # Flutter's Linux build drives CMake with clang/clang++.
  - org.freedesktop.Sdk.Extension.llvm21
command: stash-player

finish-args:
  # Display
  - --socket=wayland
  - --socket=fallback-x11
  - --share=ipc
  # Network — talks to Stash over HTTP(S).
  - --share=network
  # Audio
  - --socket=pulseaudio
  # Hardware video acceleration (VA-API via libmpv)
  - --device=dri
  # libsecret / GNOME keyring for the Stash API key
  - --talk-name=org.freedesktop.secrets
  # Read-only: the one-time import of the connection the legacy GTK client
  # saved to the host's ~/.config/stash-player/config.toml.
  - --filesystem=xdg-config/stash-player:ro

# The freedesktop 25.08 runtime (which GNOME 50 is built on) ships FFmpeg
# without the patent-encumbered decoders. libmpv below links the runtime's
# libavcodec; codecs-extra shadows it at run time with the full build so
# H.264 / H.265 / AAC / AC-3 / etc. play.
add-extensions:
  org.freedesktop.Platform.codecs-extra:
    version: '25.08-extra'
    directory: lib/codecs-extra
    add-ld-path: lib
    no-autodownload: false
    autodelete: true

cleanup:
  - /include
  - /lib/pkgconfig
  - /share/doc
  - '*.a'
  - '*.la'

modules:
  # mpv's subtitle renderer; not in the GNOME runtime.
  - name: libass
    buildsystem: autotools
    config-opts:
      - --disable-static
      # Avoids a nasm build dependency; the SIMD paths only speed up
      # subtitle blending.
      - --disable-asm
    sources:
      - type: git
        url: https://github.com/libass/libass.git
        tag: 0.17.5
        commit: 4a05d8127f525943ebf45fdc6497c9e665947f0d

  # mpv's GPU renderer; not in the GNOME runtime. OpenGL only — media_kit
  # drives libmpv through the OpenGL render API, so Vulkan and the shader
  # compilers it needs are dead weight here.
  - name: libplacebo
    buildsystem: meson
    config-opts:
      - -Dvulkan=disabled
      - -Dshaderc=disabled
      - -Dglslang=disabled
      - -Dopengl=enabled
      - -Ddemos=false
      - -Dtests=false
    sources:
      # git (not a tarball) so flatpak-builder pulls the bundled jinja /
      # glad / fast_float submodules the meson build needs.
      - type: git
        url: https://code.videolan.org/videolan/libplacebo.git
        tag: v7.360.1
        commit: cee9b076f2c63104ccfd497fa79c39a867293ec4

  - name: libmpv
    buildsystem: meson
    config-opts:
      - -Dlibmpv=true
      - -Dcplayer=false
      - -Dlua=disabled
      - -Djavascript=disabled
      - -Dmanpage-build=disabled
      - -Dvulkan=disabled
    sources:
      - type: git
        url: https://github.com/mpv-player/mpv.git
        tag: v0.41.0
        commit: 41f6a645068483470267271e1d09966ca3b9f413

  - name: stash-player
    buildsystem: simple
    build-options:
      append-path: /usr/lib/sdk/llvm21/bin
      prepend-ld-library-path: /usr/lib/sdk/llvm21/lib
      build-args:
        # The Flutter tool downloads its engine artifacts on first run, and
        # `pub get` fetches packages. Fine for personal/CI builds; Flathub
        # would need offline sources (flatpak-flutter).
        - --share=network
      env:
        HOME: /run/build/stash-player/home
        PUB_CACHE: /run/build/stash-player/pub-cache
        CI: 'true'
        FLUTTER_SUPPRESS_ANALYTICS: 'true'
    build-commands:
      # The SDK archive is a git checkout the Flutter tool shells out to
      # (for its own version); the build sandbox's uid doesn't own it.
      - git config --global --add safe.directory '*'
      - flutter/bin/flutter config --no-analytics --no-cli-animations
      - cd app && ../flutter/bin/flutter pub get --enforce-lockfile
      - cd app && ../flutter/bin/flutter build linux --release
      - mkdir -p /app/stash-player
      - cp -a app/build/linux/$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')/release/bundle/.
        /app/stash-player/
      # glibc resolves $ORIGIN (the bundle's `lib/` rpath) and Flutter
      # resolves its `data/` dir through /proc/self/exe, so a symlink is
      # enough — no wrapper script.
      - install -dm755 /app/bin
      - ln -s ../stash-player/stash-player /app/bin/stash-player
      # Mountpoint for the codecs-extra extension declared at the top level.
      # Must exist at install time or flatpak refuses to mount the extension.
      - install -dm755 /app/lib/codecs-extra
      - install -Dm644 data/dev.arsfeld.stash-player.desktop
        /app/share/applications/dev.arsfeld.stash-player.desktop
      - install -Dm644 data/dev.arsfeld.stash-player.metainfo.xml
        /app/share/metainfo/dev.arsfeld.stash-player.metainfo.xml
      - install -Dm644 data/icons/hicolor/scalable/apps/dev.arsfeld.stash-player.svg
        /app/share/icons/hicolor/scalable/apps/dev.arsfeld.stash-player.svg
      - install -Dm644 data/icons/hicolor/symbolic/apps/dev.arsfeld.stash-player-symbolic.svg
        /app/share/icons/hicolor/symbolic/apps/dev.arsfeld.stash-player-symbolic.svg
    sources:
      - type: archive
        url: https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.41.6-stable.tar.xz
        sha256: 503b3e6b7d352fca5d21b6474eca95ad544d8fc3b053782eab63a360c7fc7569
        dest: flutter
      - type: dir
        path: ../apps/flutter
        dest: app
        skip:
          - build
          - .dart_tool
          - linux/flutter/ephemeral
          - macos/Pods
          - macos/Flutter/ephemeral
      - type: dir
        path: ../data
        dest: data
```

- [ ] **Step 2: Build and install locally**

```bash
flatpak install --user -y flathub org.freedesktop.Sdk.Extension.llvm21//25.08
nix run .#flatpak
```

Expected: every module builds and the app installs as a user Flatpak. If a module fails, fix it here:
- **libass** needs something the runtime lacks: add it as a module above libass, pinned by commit.
- **libplacebo** rejects an option: check `meson_options.txt` at that tag and adjust.
- **The Flutter tool** fails on its SDK checkout (e.g. `Unable to determine Flutter version`): add `FLUTTER_GIT_URL: https://github.com/flutter/flutter.git` to `env`, or run `git -C flutter status` as a first build-command to see the error.

Record each fix in the manifest with a comment saying why.

- [ ] **Step 3: Prove it plays video**

```bash
just stash-up        # real Stash in Docker with sample clips
flatpak run --env=STASH_URL=http://127.0.0.1:9999 dev.arsfeld.stash-player
```

Expected:
- The library loads.
- Opening a scene plays video with sound.
- `flatpak run --command=sh dev.arsfeld.stash-player -c 'ldd /app/stash-player/lib/libmedia_kit_video_plugin.so | grep mpv'` shows `/app/lib/libmpv.so.2`.
- The dock/overview shows the Stash Player icon, not a generic one.

Tear down with `just stash-down`.

- [ ] **Step 4: Commit**

```bash
git add build-aux/dev.arsfeld.stash-player.yml
git commit -m "feat(flatpak): package the Flutter client with a from-source libmpv"
```

---

### Task 3: Flatpak CI

**Files:**
- Modify: `.github/workflows/flatpak.yml`

**Interfaces:**
- Consumes: the manifest from Task 2.
- Produces: the `stash-player-x86_64.flatpak` artifact (unchanged name), attached to `v*` releases.

- [ ] **Step 1: Update the cache key and add a path filter**

In `.github/workflows/flatpak.yml`, change the `cache-key` line:

```yaml
          cache-key: flatpak-builder-${{ hashFiles('apps/flutter/pubspec.lock', 'build-aux/dev.arsfeld.stash-player.yml') }}
```

Leave the triggers, container, bundle name, and `release` job unchanged.

- [ ] **Step 2: Push and watch CI**

```bash
git add .github/workflows/flatpak.yml
git commit -m "ci(flatpak): key the builder cache on the Flutter inputs"
git push origin flutter
gh run watch "$(gh run list --branch flutter --workflow Flatpak --limit 1 --json databaseId -q '.[0].databaseId')"
```

Expected: `Build Flatpak bundle` succeeds. If it fails because `org.freedesktop.Sdk.Extension.llvm21` isn't installed in the container, the flatpak-builder action isn't installing SDK extensions. Add a step before `Build`:

```yaml
      - name: Install LLVM SDK extension
        run: flatpak install --user -y --noninteractive flathub org.freedesktop.Sdk.Extension.llvm21//25.08
```

Then amend the commit, push again, and re-watch.

- [ ] **Step 3: Download and sanity-check the artifact**

```bash
gh run download --name stash-player-x86_64.flatpak --dir /tmp/claude-flatpak-artifact
flatpak install --user -y --bundle /tmp/claude-flatpak-artifact/stash-player.flatpak
flatpak run dev.arsfeld.stash-player
```

Expected: the app launches to the connection screen, or to the library if a connection exists.

---

### Task 4: macOS identity, entitlements, deployment target, keychain mode

**Files:**
- Modify: `apps/flutter/macos/Runner/Configs/AppInfo.xcconfig`
- Modify: `apps/flutter/macos/Runner/Configs/Release.xcconfig`
- Modify: `apps/flutter/macos/Runner/Info.plist`
- Modify: `apps/flutter/macos/Runner/Release.entitlements`, `DebugProfile.entitlements`
- Modify: `apps/flutter/macos/Runner/Base.lproj/MainMenu.xib`
- Modify: `apps/flutter/macos/Runner.xcodeproj/project.pbxproj` (deployment target only)
- Modify: `apps/flutter/macos/Podfile:1`
- Modify: `apps/flutter/macos/Runner/MainFlutterWindow.swift` (drop the now-dead macOS 11 check)
- Replace: `apps/flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png`
- Modify: `apps/flutter/lib/services/platform_connection_store.dart` (`create()`)
- Modify: `justfile:19,192`

**Interfaces:**
- Produces:
  - Release builds land at `…/Build/Products/Release/StashPlayer.app` with bundle ID `dev.arsfeld.stash-player`.
  - `Release.entitlements` is an empty dict.
  - `ENABLE_HARDENED_RUNTIME = YES` is set project-wide.
  - Tasks 5 and 6 rely on all of these.

- [ ] **Step 1: Identity**

`apps/flutter/macos/Runner/Configs/AppInfo.xcconfig`:

```
// The bundle's on-disk name (StashPlayer.app) and executable name. Kept
// identical to the SwiftUI client this replaces so Sparkle's in-place
// update, the appcast job, and the release asset name don't change. The
// user-visible name is CFBundleName / CFBundleDisplayName in Info.plist.
PRODUCT_NAME = StashPlayer

// Shared with the SwiftUI client this replaces: Sparkle only installs an
// update whose bundle ID matches the running app's.
PRODUCT_BUNDLE_IDENTIFIER = dev.arsfeld.stash-player

// The copyright displayed in application information
PRODUCT_COPYRIGHT = Copyright © 2026 Alexandre Rosenfeld. All rights reserved.
```

In `apps/flutter/macos/Runner/Info.plist`, replace the `CFBundleName` value and add `CFBundleDisplayName` right after it:

```xml
	<key>CFBundleName</key>
	<string>Stash Player</string>
	<key>CFBundleDisplayName</key>
	<string>Stash Player</string>
```

In `apps/flutter/macos/Runner/Base.lproj/MainMenu.xib`, replace every `APP_NAME` with `Stash Player`:

```bash
sed -i 's/APP_NAME/Stash Player/g' apps/flutter/macos/Runner/Base.lproj/MainMenu.xib
```

Icons: copy the SwiftUI app's icon set over the Flutter defaults. The file names differ; the sizes match.

```bash
for s in 16 32 64 128 256 512 1024; do
  cp apps/macos/StashPlayer/Assets.xcassets/AppIcon.appiconset/icon_$s.png \
     apps/flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$s.png
done
```

`justfile`:
- line 19: `app_bundle := flutter_dir / "build/macos/Build/Products/Debug/StashPlayer.app"`
- line 192: `"{{ app_bundle }}/Contents/MacOS/StashPlayer"`

- [ ] **Step 2: Entitlements and hardened runtime**

`apps/flutter/macos/Runner/Release.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<!-- Deliberately empty. Distributed with Developer ID, not the Mac App
     Store, so there is no App Sandbox: Sparkle's installer and the legacy
     keychain import both need to run unsandboxed. The file must still exist
     and be passed explicitly — without it xcodebuild injects
     com.apple.security.get-task-allow, which notarization rejects. -->
<dict/>
</plist>
```

`apps/flutter/macos/Runner/DebugProfile.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<!-- Unsandboxed like Release (see Release.entitlements). JIT is what the
     Dart VM needs for debug/profile hot reload under the hardened runtime. -->
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
</dict>
</plist>
```

Append to `apps/flutter/macos/Runner/Configs/Release.xcconfig`:

```
// Required for notarization.
ENABLE_HARDENED_RUNTIME = YES
```

- [ ] **Step 3: Deployment target 14.0**

```bash
sed -i 's/MACOSX_DEPLOYMENT_TARGET = 10.15;/MACOSX_DEPLOYMENT_TARGET = 14.0;/' apps/flutter/macos/Runner.xcodeproj/project.pbxproj
sed -i "s/^platform :osx, '10.15'/platform :osx, '14.0'/" apps/flutter/macos/Podfile
grep -c "MACOSX_DEPLOYMENT_TARGET = 14.0;" apps/flutter/macos/Runner.xcodeproj/project.pbxproj
```

Expected: `3`.

In `apps/flutter/macos/Runner/MainFlutterWindow.swift`, the `if #available(macOS 11.0, *)` block is now always true. Replace the block and the comment lines about 10.15 above it with the unconditional body. Keep the comment that explains why the toolbar exists, and delete the sentences about the 10.15 deployment target:

```swift
    // An empty toolbar in the unified style is what makes AppKit treat the
    // titlebar as a taller band and re-centre the traffic lights inside it.
    // Without it the lights sit in a 28pt titlebar, which leaves the app's
    // own strip no room for padding above its controls without falling off
    // the lights' centre line. Nothing is ever added to this toolbar; the
    // Flutter view draws every control.
    let toolbar = NSToolbar(identifier: "stash-player-titlebar-spacer")
    self.toolbar = toolbar
    self.toolbarStyle = .unified
```

- [ ] **Step 4: Use the file-based keychain**

flutter_secure_storage 11 defaults to the data-protection keychain on macOS. That keychain needs a `keychain-access-groups` entitlement, which is why the macOS smoke test in `flutter.yml` fails. The file-based login keychain needs no entitlement and is where the legacy client stored its key.

In `apps/flutter/lib/services/platform_connection_store.dart`, change `create()`:

```dart
  static Future<PlatformConnectionStore> create() async =>
      PlatformConnectionStore(
        preferences: SharedPreferencesAsync(),
        // The file-based login keychain rather than the data-protection
        // one (the plugin's default): the latter needs a
        // keychain-access-groups entitlement tied to a provisioning
        // profile, which a Developer ID build doesn't have.
        secureStorage: const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        ),
      );
```

- [ ] **Step 5: Verify**

```bash
just flutter-check
git add apps/flutter/macos apps/flutter/lib/services/platform_connection_store.dart justfile
git commit -m "feat(flutter): take over the Stash Player identity on macOS and drop the sandbox"
git push origin flutter
gh run watch "$(gh run list --branch flutter --workflow Flutter --limit 1 --json databaseId -q '.[0].databaseId')"
```

Expected:
- `just flutter-check` passes.
- In the `Flutter` workflow, the `Flutter macOS` job's debug build succeeds.
- Note whether the `Connection/library smoke` step now passes; Task 10 uses this.
- On a Mac: `just flutter-run` launches an app titled "Stash Player" in the menu bar, and saving a connection then relaunching keeps it.

---

### Task 5: Sparkle in the macOS Runner

**Files:**
- Modify: `apps/flutter/macos/Podfile` (inside `target 'Runner'`)
- Modify: `apps/flutter/macos/Runner/AppDelegate.swift`
- Modify: `apps/flutter/macos/Runner/Base.lproj/MainMenu.xib` (one menu item)
- Modify: `apps/flutter/macos/Runner/Info.plist` (three keys)
- Modify: `apps/flutter/macos/Podfile.lock` (regenerated on a Mac or in CI; see Step 5)

**Interfaces:**
- Consumes: Task 4's unsandboxed Runner.
- Produces: `Contents/Frameworks/Sparkle.framework` inside `StashPlayer.app`. Task 6's re-sign step expects it there.

- [ ] **Step 1: Add the pod**

In `apps/flutter/macos/Podfile`, inside `target 'Runner' do`, after `use_frameworks!`:

```ruby
  # Auto-update channel shared with the SwiftUI client this replaces; the
  # feed URL and EdDSA key live in Runner/Info.plist.
  pod 'Sparkle', '~> 2.9'
```

- [ ] **Step 2: Own the updater in AppDelegate**

Replace `apps/flutter/macos/Runner/AppDelegate.swift`:

```swift
import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  // Starts the updater immediately: scheduled background checks follow
  // SUEnableAutomaticChecks in Info.plist (then the user's choice in
  // Sparkle's own dialog), and the menu item below triggers a manual check.
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  // Target of the "Check for Updates…" item in MainMenu.xib, which sends
  // this action to the first responder; the app delegate is on that chain.
  @IBAction func checkForUpdates(_ sender: Any?) {
    updaterController.checkForUpdates(sender)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
```

- [ ] **Step 3: Add the menu item**

In `apps/flutter/macos/Runner/Base.lproj/MainMenu.xib`, insert this directly after the `About Stash Player` `</menuItem>` (the item with id `5kV-Vb-QxS`), before the separator `VOq-y0-SEH`:

```xml
                            <menuItem title="Check for Updates…" id="sPk-Up-Chk">
                                <modifierMask key="keyEquivalentModifierMask"/>
                                <connections>
                                    <action selector="checkForUpdates:" target="-1" id="sPk-Up-Act"/>
                                </connections>
                            </menuItem>
```

- [ ] **Step 4: Info.plist keys**

In `apps/flutter/macos/Runner/Info.plist`, before `</dict>`:

```xml
	<!-- Same feed and EdDSA public key as the SwiftUI client this replaces,
	     so its users are updated into this app and keep updating. The
	     private half lives in the SPARKLE_ED_PRIVATE_KEY Actions secret. -->
	<key>SUFeedURL</key>
	<string>https://arsfeld.github.io/stash-player/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>Fx+Cc8kj5pSdtx3i/E+AhMmLUgefc8EXD1CxFh2VO5A=</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
```

- [ ] **Step 5: Regenerate Podfile.lock and verify**

On a Mac (`just flutter-build` runs `pod install`), or let CI do it and copy the lock from the job log. Commit `Podfile.lock` together with the Podfile.

```bash
just flutter-check
git add apps/flutter/macos
git commit -m "feat(flutter): embed Sparkle on macOS and continue the existing update channel"
git push origin flutter
```

Expected:
- The `Flutter macOS` debug build succeeds.
- On a Mac: the app menu shows "Check for Updates…". Clicking it on a `0.0.0` build shows Sparkle's "update available" dialog for the current production release. That proves the feed and key are wired; cancel it.

---

### Task 6: Rewrite `macos.yml` around Flutter

**Files:**
- Rewrite: `.github/workflows/macos.yml`

**Interfaces:**
- Consumes: Tasks 4–5 (bundle name, entitlements, Sparkle).
- Produces: `StashPlayer-macos-arm64.zip`, signed and (on tags) notarized, attached to releases, plus the gh-pages appcast. The asset name is unchanged.

- [ ] **Step 1: Replace the `build` job; keep `release` and `appcast`**

Keep the file header (`name`, `on`, `concurrency`, `permissions`). Delete the `env:` block (`CARGO_TERM_COLOR`, `MACOSX_DEPLOYMENT_TARGET`). Replace the whole `build:` job with the following. Leave the `release:` and `appcast:` jobs byte-for-byte as they are; they only handle the zip by name.

```yaml
jobs:
  build:
    name: Build StashPlayer.app
    runs-on: macos-15
    env:
      DERIVED_DATA: apps/flutter/build/macos-derived
      APP_PATH: apps/flutter/build/macos-derived/Build/Products/Release/StashPlayer.app
      ZIP_PATH: StashPlayer-macos-arm64.zip
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # Same pin as flutter.yml and the Flatpak manifest; bump all three
      # together with flake.lock.
      - name: Install Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: 3.41.6
          channel: stable
          cache: true

      # Fork PRs can't read repo secrets, so fall back to ad-hoc signing
      # there instead of failing the job. Same-repo pushes/PRs and tag
      # builds get the real Developer ID identity.
      - name: Determine signing mode
        id: signing
        env:
          MACOS_CERTIFICATE: ${{ secrets.MACOS_CERTIFICATE }}
        run: |
          if [ -n "$MACOS_CERTIFICATE" ]; then
            echo "mode=developer-id" >> "$GITHUB_OUTPUT"
            echo "Signing mode: developer-id"
          else
            echo "mode=ad-hoc" >> "$GITHUB_OUTPUT"
            echo "Signing mode: ad-hoc (no MACOS_CERTIFICATE secret)"
          fi

      - name: Import Developer ID certificate
        if: steps.signing.outputs.mode == 'developer-id'
        uses: apple-actions/import-codesign-certs@v3
        with:
          p12-file-base64: ${{ secrets.MACOS_CERTIFICATE }}
          p12-password: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}

      # Generates macos/Flutter/ephemeral (FLUTTER_ROOT etc.) and the plugin
      # registrant without building, so xcodebuild below owns signing.
      - name: Prepare Flutter macOS project
        working-directory: apps/flutter
        run: |
          flutter pub get
          flutter build macos --release --config-only
          cd macos && pod install

      - name: Build StashPlayer.app (Release)
        env:
          SIGN_MODE: ${{ steps.signing.outputs.mode }}
          DEVELOPMENT_TEAM_ID: ${{ secrets.MACOS_DEVELOPMENT_TEAM }}
        run: |
          set -euo pipefail

          # v1.2.3 → 1.2.3; non-tag builds get 0.0.0, which Sparkle never
          # prefers over a published appcast item.
          VERSION="${GITHUB_REF_NAME#v}"
          if [[ -z "$VERSION" || "$VERSION" == "$GITHUB_REF_NAME" ]]; then
            VERSION="0.0.0"
          fi
          echo "Building bundle version: $VERSION"

          if [ "$SIGN_MODE" = "developer-id" ]; then
            SIGN_IDENTITY="Developer ID Application"
            TEAM_ID="$DEVELOPMENT_TEAM_ID"
            EXTRA_FLAGS="--timestamp"
          else
            SIGN_IDENTITY="-"
            TEAM_ID=""
            EXTRA_FLAGS=""
          fi

          # FLUTTER_BUILD_NAME / FLUTTER_BUILD_NUMBER feed Info.plist's
          # CFBundleShortVersionString / CFBundleVersion. Both get the dotted
          # version: Sparkle compares CFBundleVersion, and the SwiftUI
          # releases already in the feed carry dotted values there.
          # Entitlements and the hardened runtime come from the Runner's
          # Release configuration (Release.entitlements, Release.xcconfig).
          xcodebuild \
            -workspace apps/flutter/macos/Runner.xcworkspace \
            -scheme Runner \
            -configuration Release \
            -derivedDataPath "$DERIVED_DATA" \
            -destination 'generic/platform=macOS' \
            ARCHS=arm64 \
            ONLY_ACTIVE_ARCH=NO \
            FLUTTER_BUILD_NAME="$VERSION" \
            FLUTTER_BUILD_NUMBER="$VERSION" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            OTHER_CODE_SIGN_FLAGS="$EXTRA_FLAGS" \
            build

      - name: Verify Info.plist identity and version
        run: |
          set -euo pipefail
          PLIST="$APP_PATH/Contents/Info.plist"
          test "$(plutil -extract CFBundleIdentifier raw "$PLIST")" = "dev.arsfeld.stash-player"
          test "$(plutil -extract SUFeedURL raw "$PLIST")" = "https://arsfeld.github.io/stash-player/appcast.xml"
          if [[ "$GITHUB_REF" == refs/tags/v* ]]; then
            EXPECTED="${GITHUB_REF_NAME#v}"
            for key in CFBundleShortVersionString CFBundleVersion; do
              ACTUAL=$(plutil -extract "$key" raw "$PLIST")
              if [ "$ACTUAL" != "$EXPECTED" ]; then
                echo "Info.plist $key=$ACTUAL does not match tag $EXPECTED" >&2
                exit 1
              fi
            done
          fi
          echo "Info.plist OK"

      - name: Re-sign nested code
        if: steps.signing.outputs.mode == 'developer-id'
        # Sparkle ships its helpers (Updater.app, Autoupdate, XPC services)
        # signed by the Sparkle project without a secure timestamp, and
        # the embed phase doesn't recurse into them; the notary service
        # rejects the result. Re-sign deepest-first: Sparkle's helpers,
        # then every embedded framework (Sparkle, media_kit's libmpv
        # frameworks, plugin frameworks), then the outer app so its seal
        # covers the new signatures.
        run: |
          set -euo pipefail
          SIGN_IDENTITY="Developer ID Application"
          ENTITLEMENTS="$PWD/apps/flutter/macos/Runner/Release.entitlements"
          FRAMEWORKS="$APP_PATH/Contents/Frameworks"
          SPARKLE_FW="$FRAMEWORKS/Sparkle.framework"

          for item in \
            "Versions/B/XPCServices/Downloader.xpc" \
            "Versions/B/XPCServices/Installer.xpc" \
            "Versions/B/Autoupdate" \
            "Versions/B/Updater.app"; do
            if [ -e "$SPARKLE_FW/$item" ]; then
              echo "==> Re-signing Sparkle $item"
              codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$SPARKLE_FW/$item"
            fi
          done

          find "$FRAMEWORKS" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0 |
            while IFS= read -r -d '' fw; do
              echo "==> Re-signing $(basename "$fw")"
              codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$fw"
            done

          echo "==> Re-signing StashPlayer.app"
          codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
            --entitlements "$ENTITLEMENTS" "$APP_PATH"

      - name: Verify signature
        if: steps.signing.outputs.mode == 'developer-id'
        run: |
          codesign -dv --verbose=4 "$APP_PATH"
          codesign --verify --deep --strict --verbose=2 "$APP_PATH"
          # No sandbox and no get-task-allow may reach a shipped bundle.
          ENTS=$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null || true)
          echo "$ENTS"
          if echo "$ENTS" | grep -qE "app-sandbox|get-task-allow"; then
            echo "unexpected entitlement in release bundle" >&2
            exit 1
          fi

      - name: Package .app into zip
        run: |
          test -d "$APP_PATH" || { echo "no .app at $APP_PATH" >&2; exit 1; }
          ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
          ls -lh "$ZIP_PATH"

      # Notarize only on `v*` tags — pushes/PRs are signed but skip the
      # 1–5 min round-trip to Apple's notary service.
      - name: Notarize and staple
        if: startsWith(github.ref, 'refs/tags/v') && steps.signing.outputs.mode == 'developer-id'
        env:
          NOTARY_KEY: ${{ secrets.MACOS_NOTARY_KEY }}
          NOTARY_KEY_ID: ${{ secrets.MACOS_NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.MACOS_NOTARY_ISSUER_ID }}
        run: |
          KEY_PATH="$RUNNER_TEMP/AuthKey.p8"
          echo "$NOTARY_KEY" | base64 --decode > "$KEY_PATH"
          trap 'rm -f "$KEY_PATH"' EXIT

          set +e
          SUBMIT_OUT=$(xcrun notarytool submit "$ZIP_PATH" \
            --key "$KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" \
            --wait \
            --output-format json)
          RESULT=$?
          set -e
          echo "$SUBMIT_OUT"

          SUBMISSION_ID=$(echo "$SUBMIT_OUT" | jq -r '.id // empty')
          if [ -n "$SUBMISSION_ID" ]; then
            echo "==> Notarization log for $SUBMISSION_ID"
            xcrun notarytool log "$SUBMISSION_ID" \
              --key "$KEY_PATH" \
              --key-id "$NOTARY_KEY_ID" \
              --issuer "$NOTARY_ISSUER_ID" || true
          fi

          if [ "$RESULT" -ne 0 ]; then
            exit "$RESULT"
          fi

          xcrun stapler staple "$APP_PATH"
          xcrun stapler validate "$APP_PATH"
          rm -f "$ZIP_PATH"
          ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
          spctl --assess --type execute --verbose "$APP_PATH"

      - name: Upload .app artifact
        uses: actions/upload-artifact@v4
        with:
          name: StashPlayer-macos-arm64
          path: ${{ env.ZIP_PATH }}
          if-no-files-found: error
```

Also add a `workflow_dispatch` input so a release candidate can be notarized without tagging. Change the `on:` block's `workflow_dispatch:` to:

```yaml
  workflow_dispatch:
    inputs:
      notarize:
        description: "Notarize this build (release-candidate testing)"
        type: boolean
        default: false
```

Change the notarize step's `if:` to:

```yaml
        if: steps.signing.outputs.mode == 'developer-id' && (startsWith(github.ref, 'refs/tags/v') || inputs.notarize)
```

- [ ] **Step 2: Push and watch**

```bash
git add .github/workflows/macos.yml
git commit -m "ci(macos): build, sign, and notarize the Flutter client"
git push origin flutter
gh run watch "$(gh run list --branch flutter --workflow macOS --limit 1 --json databaseId -q '.[0].databaseId')"
```

Expected: `Build StashPlayer.app` succeeds through `Verify signature` and `Upload .app artifact`.

If `codesign --verify --deep --strict` fails on a media_kit framework's nested dylib, extend the `find` to `-maxdepth 3 -name '*.dylib'` inside each framework and sign those first. Commit that as a follow-up.

- [ ] **Step 3: Notarize a release candidate**

```bash
gh workflow run macOS --ref flutter -f notarize=true
gh run watch "$(gh run list --branch flutter --workflow macOS --limit 1 --json databaseId -q '.[0].databaseId')"
gh run download --name StashPlayer-macos-arm64 --dir /tmp/claude-macos-rc
```

Expected: `Notarize and staple` reports `status: Accepted`, and `spctl` says `accepted source=Notarized Developer ID`.

If notarization rejects libmpv under the hardened runtime ("library validation"), that's the spec's contingency. Add to `Release.entitlements`:

```xml
<dict>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
```

Update its comment to say why, The `Verify signature` check only rejects `app-sandbox` and `get-task-allow`, so it needs no change. Only do this if notarization or launch actually fails.

---

### Task 7: Legacy config reader (TDD)

**Files:**
- Modify: `apps/flutter/pubspec.yaml` (add `toml`)
- Create: `apps/flutter/lib/services/legacy_config.dart`
- Create: `apps/flutter/test/services/legacy_config_test.dart`

**Interfaces:**
- Produces:
  - `class LegacyConfig { const LegacyConfig({required String serverUrl, required String socksProxy}); final String serverUrl; final String socksProxy; }`
  - `List<String> legacyConfigCandidates({required bool isMacOS, required Map<String, String> environment})`
  - `LegacyConfig? parseLegacyConfig(String source)`
  - `String socksAddressFromProxyUrl(String proxyUrl)`

- [ ] **Step 1: Add the dependency**

```bash
nix develop .#flutter --command bash -c 'cd apps/flutter && flutter pub add toml'
```

Expected: `toml` appears under `dependencies:` in `pubspec.yaml`, and `pubspec.lock` updates.

- [ ] **Step 2: Write the failing tests**

`apps/flutter/test/services/legacy_config_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/legacy_config.dart';

void main() {
  group('legacyConfigCandidates', () {
    test('macOS reads the directories-crate ProjectDirs path', () {
      expect(
        legacyConfigCandidates(
          isMacOS: true,
          environment: const {'HOME': '/Users/me'},
        ),
        [
          '/Users/me/Library/Application Support/one.arsfeld.stash-player/config.toml',
        ],
      );
    });

    test('Linux tries XDG_CONFIG_HOME first, then the host ~/.config', () {
      expect(
        legacyConfigCandidates(
          isMacOS: false,
          environment: const {
            'HOME': '/home/me',
            'XDG_CONFIG_HOME': '/home/me/.var/app/dev.arsfeld.stash-player/config',
          },
        ),
        [
          '/home/me/.var/app/dev.arsfeld.stash-player/config/stash-player/config.toml',
          '/home/me/.config/stash-player/config.toml',
        ],
      );
    });

    test('Linux without XDG_CONFIG_HOME lists ~/.config once', () {
      expect(
        legacyConfigCandidates(
          isMacOS: false,
          environment: const {'HOME': '/home/me'},
        ),
        ['/home/me/.config/stash-player/config.toml'],
      );
    });

    test('no HOME means no candidates', () {
      expect(
        legacyConfigCandidates(isMacOS: false, environment: const {}),
        isEmpty,
      );
    });
  });

  group('parseLegacyConfig', () {
    test('reads the URL and a SOCKS proxy', () {
      final config = parseLegacyConfig('''
stash_url = "https://stash.example.ts.net"
autoplay = true
volume = 0.5
proxy_url = "socks5h://127.0.0.1:1055"
''');
      expect(config?.serverUrl, 'https://stash.example.ts.net');
      expect(config?.socksProxy, '127.0.0.1:1055');
    });

    test('a config without proxy_url has no proxy', () {
      final config = parseLegacyConfig('stash_url = "http://nas:9999"');
      expect(config?.serverUrl, 'http://nas:9999');
      expect(config?.socksProxy, '');
    });

    test('an empty URL means nothing to import', () {
      expect(parseLegacyConfig('stash_url = ""'), isNull);
    });

    test('malformed TOML means nothing to import', () {
      expect(parseLegacyConfig('stash_url = "unterminated'), isNull);
    });

    test('a non-string URL means nothing to import', () {
      expect(parseLegacyConfig('stash_url = 42'), isNull);
    });
  });

  group('socksAddressFromProxyUrl', () {
    test('strips socks5 and socks5h schemes and a trailing slash', () {
      expect(socksAddressFromProxyUrl('socks5h://127.0.0.1:1055'), '127.0.0.1:1055');
      expect(socksAddressFromProxyUrl('SOCKS5://proxy.lan:1080/'), 'proxy.lan:1080');
    });

    test('drops HTTP proxies, which the Flutter client cannot use', () {
      expect(socksAddressFromProxyUrl('http://proxy.lan:3128'), '');
    });

    test('drops proxies with credentials, which the SOCKS setting cannot hold', () {
      expect(socksAddressFromProxyUrl('socks5h://user:pw@127.0.0.1:1055'), '');
    });

    test('drops an empty or schemeless value', () {
      expect(socksAddressFromProxyUrl(''), '');
      expect(socksAddressFromProxyUrl('127.0.0.1:1055'), '');
    });
  });
}
```

- [ ] **Step 3: Run the tests to make sure they fail**

Run: `nix develop .#flutter --command bash -c 'cd apps/flutter && flutter test test/services/legacy_config_test.dart'`
Expected: FAIL, with a compilation error that `package:stash_player_flutter/services/legacy_config.dart` doesn't exist.

- [ ] **Step 4: Implement**

`apps/flutter/lib/services/legacy_config.dart`:

```dart
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

/// The connection fields the legacy GTK and SwiftUI clients persisted in
/// their `config.toml` (written by the Rust `stash-player-core` crate).
class LegacyConfig {
  const LegacyConfig({required this.serverUrl, required this.socksProxy});

  final String serverUrl;

  /// `host:port`, or empty. See [socksAddressFromProxyUrl].
  final String socksProxy;
}

/// Where the legacy clients' `config.toml` may be, most likely first.
///
/// The Rust clients used the `directories` crate's
/// `ProjectDirs::from("one", "arsfeld", "stash-player")`. On Linux that
/// resolves through `XDG_CONFIG_HOME` — inside the Flatpak, the per-app
/// `~/.var/app/…/config` — with the host `~/.config` as the non-Flatpak
/// location (also exposed read-only to the Flatpak by its manifest).
List<String> legacyConfigCandidates({
  required bool isMacOS,
  required Map<String, String> environment,
}) {
  final home = environment['HOME'];
  if (home == null || home.isEmpty) return const [];
  if (isMacOS) {
    return [
      p.join(
        home,
        'Library',
        'Application Support',
        'one.arsfeld.stash-player',
        'config.toml',
      ),
    ];
  }
  final xdg = environment['XDG_CONFIG_HOME'];
  final roots = <String>{
    if (xdg != null && xdg.isNotEmpty) xdg,
    p.join(home, '.config'),
  };
  return [for (final root in roots) p.join(root, 'stash-player', 'config.toml')];
}

/// Parses a legacy `config.toml`, or returns null when it holds no usable
/// server URL (including when it isn't valid TOML at all).
LegacyConfig? parseLegacyConfig(String source) {
  final Map<String, dynamic> values;
  try {
    values = TomlDocument.parse(source).toMap();
  } on Object {
    return null;
  }
  final url = values['stash_url'];
  if (url is! String || url.trim().isEmpty) return null;
  final proxy = values['proxy_url'];
  return LegacyConfig(
    serverUrl: url.trim(),
    socksProxy: proxy is String ? socksAddressFromProxyUrl(proxy) : '',
  );
}

final _socksUrl = RegExp(r'^socks5h?://([^/@]+)/?$', caseSensitive: false);

/// Converts the legacy clients' `proxy_url` (a `socks5h://host:port` or
/// `http://…` URL) to the Flutter client's SOCKS setting (`host:port`).
///
/// Anything the Flutter client can't honour — HTTP proxies, credentials —
/// maps to empty (a direct connection), so the user sees a connection
/// failure they can fix on the connection screen, not a silently wrong
/// route.
String socksAddressFromProxyUrl(String proxyUrl) =>
    _socksUrl.firstMatch(proxyUrl.trim())?.group(1) ?? '';
```

- [ ] **Step 5: Run the tests to make sure they pass**

Run: `nix develop .#flutter --command bash -c 'cd apps/flutter && flutter test test/services/legacy_config_test.dart'`
Expected: all 13 tests PASS. If `TomlDocument.parse` accepts `stash_url = "unterminated` without throwing, the test is right and the implementation needs to check the parsed map; it should throw `TomlParserException`.

- [ ] **Step 6: Full gate and commit**

```bash
just flutter-check
git add apps/flutter/pubspec.yaml apps/flutter/pubspec.lock apps/flutter/lib/services/legacy_config.dart apps/flutter/test/services/legacy_config_test.dart
git commit -m "feat(flutter): read the legacy clients' config.toml"
```

---

### Task 8: Legacy secret reader (Dart channel + Linux libsecret + macOS Keychain)

**Files:**
- Create: `apps/flutter/lib/services/legacy_secret_reader.dart`
- Create: `apps/flutter/test/services/legacy_secret_reader_test.dart`
- Modify: `apps/flutter/linux/runner/my_application.cc`
- Modify: `apps/flutter/linux/runner/CMakeLists.txt`
- Modify: `apps/flutter/macos/Runner/MainFlutterWindow.swift`

**Interfaces:**
- Produces:
  - `abstract interface class LegacySecretReader { Future<String?> readApiKey(); }`
  - `class MethodChannelLegacySecretReader implements LegacySecretReader { const MethodChannelLegacySecretReader([MethodChannel channel = legacySecretChannel]); }`
  - `const legacySecretChannel = MethodChannel('stash_player/legacy_secret');`
  - Channel contract: method `readApiKey`, no arguments. Returns a `String`, or `null` when there is no legacy item. Throws `PlatformException(code: 'lookup-failed')` on a backend error. Platforms without the handler raise `MissingPluginException`, which the Dart side maps to `null`.

- [ ] **Step 1: Write the failing tests**

`apps/flutter/test/services/legacy_secret_reader_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/legacy_secret_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(legacySecretChannel, null));

  test('returns the key the platform found', () async {
    messenger.setMockMethodCallHandler(legacySecretChannel, (call) async {
      expect(call.method, 'readApiKey');
      return 'legacy-key';
    });
    expect(await const MethodChannelLegacySecretReader().readApiKey(), 'legacy-key');
  });

  test('returns null when the platform has no legacy item', () async {
    messenger.setMockMethodCallHandler(legacySecretChannel, (call) async => null);
    expect(await const MethodChannelLegacySecretReader().readApiKey(), isNull);
  });

  test('returns null on a platform without the handler', () async {
    // No mock handler registered → MissingPluginException.
    expect(await const MethodChannelLegacySecretReader().readApiKey(), isNull);
  });

  test('propagates a backend failure', () async {
    messenger.setMockMethodCallHandler(legacySecretChannel, (call) async {
      throw PlatformException(code: 'lookup-failed', message: 'locked');
    });
    expect(
      const MethodChannelLegacySecretReader().readApiKey(),
      throwsA(isA<PlatformException>()),
    );
  });
}
```

- [ ] **Step 2: Run the tests to make sure they fail**

Run: `nix develop .#flutter --command bash -c 'cd apps/flutter && flutter test test/services/legacy_secret_reader_test.dart'`
Expected: FAIL (the import doesn't exist).

- [ ] **Step 3: Implement the Dart side**

`apps/flutter/lib/services/legacy_secret_reader.dart`:

```dart
import 'package:flutter/services.dart';

/// Reads the API key the legacy GTK / SwiftUI clients stored, which lives
/// outside flutter_secure_storage's namespace: a Secret Service item with
/// attributes `application=stash-player`, `key=stash-api-key` on Linux, a
/// Keychain generic password (service `stash-player`, account
/// `stash-api-key`) on macOS.
abstract interface class LegacySecretReader {
  /// The stored key, or null when there is none.
  Future<String?> readApiKey();
}

/// Implemented natively in `linux/runner/my_application.cc` and
/// `macos/Runner/MainFlutterWindow.swift`.
const legacySecretChannel = MethodChannel('stash_player/legacy_secret');

class MethodChannelLegacySecretReader implements LegacySecretReader {
  const MethodChannelLegacySecretReader([this._channel = legacySecretChannel]);

  final MethodChannel _channel;

  @override
  Future<String?> readApiKey() async {
    try {
      return await _channel.invokeMethod<String>('readApiKey');
    } on MissingPluginException {
      // Windows, or a test host: there was never a legacy client there.
      return null;
    }
  }
}
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `nix develop .#flutter --command bash -c 'cd apps/flutter && flutter test test/services/legacy_secret_reader_test.dart'`
Expected: 4 tests PASS.

- [ ] **Step 5: Linux native handler**

`apps/flutter/linux/runner/CMakeLists.txt`: after the existing `target_link_libraries(... PkgConfig::GTK)` line, add:

```cmake
# Legacy-client API key import (see my_application.cc). Already a
# transitive requirement of flutter_secure_storage_linux.
pkg_check_modules(LIBSECRET REQUIRED IMPORTED_TARGET libsecret-1)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::LIBSECRET)
```

`apps/flutter/linux/runner/my_application.cc`:

Add the include after `#include <flutter_linux/flutter_linux.h>`:

```cpp
#include <libsecret/secret.h>
```

Add a field to the struct:

```cpp
struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* legacy_secret_channel;
};
```

Add these functions above `my_application_activate`:

```cpp
// The Secret Service item the legacy GTK client (Rust `secret-service`
// crate) wrote. That crate sets no `xdg:schema` attribute, so the lookup
// must not match on the schema name.
static const SecretSchema* legacy_secret_schema() {
  static const SecretSchema schema = {
      "dev.arsfeld.stash-player.Legacy",
      SECRET_SCHEMA_DONT_MATCH_NAME,
      {
          {"application", SECRET_SCHEMA_ATTRIBUTE_STRING},
          {"key", SECRET_SCHEMA_ATTRIBUTE_STRING},
          {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING},
      }};
  return &schema;
}

// Handles `readApiKey` on `stash_player/legacy_secret`: the stored key, null
// when there is none, or a `lookup-failed` error. Synchronous because it
// runs at most once per install (see PlatformConnectionStore) and the
// connection screen can't render meaningfully before it answers anyway.
static void legacy_secret_method_cb(FlMethodChannel* channel,
                                    FlMethodCall* method_call,
                                    gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(method_call), "readApiKey") == 0) {
    g_autoptr(GError) error = nullptr;
    gchar* secret = secret_password_lookup_sync(
        legacy_secret_schema(), nullptr, &error, "application", "stash-player",
        "key", "stash-api-key", nullptr);
    if (error != nullptr) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("lookup-failed", error->message, nullptr));
    } else {
      g_autoptr(FlValue) value = secret != nullptr ? fl_value_new_string(secret)
                                                   : fl_value_new_null();
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
    }
    secret_password_free(secret);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}
```

In `my_application_activate`, after `fl_register_plugins(FL_PLUGIN_REGISTRY(view));`:

```cpp
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->legacy_secret_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "stash_player/legacy_secret", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->legacy_secret_channel, legacy_secret_method_cb, nullptr, nullptr);
```

In `my_application_dispose`, before the parent call:

```cpp
  g_clear_object(&self->legacy_secret_channel);
```

- [ ] **Step 6: Verify the Linux handler against a real legacy item**

```bash
secret-tool store --label="stash-player API key" application stash-player key stash-api-key <<< "legacy-test-key"
just flutter-build
```

Temporarily add `debugPrint('legacy key: ${await const MethodChannelLegacySecretReader().readApiKey()}');` to `main()` after `PlatformConnectionStore.create()`, then run `just flutter-launch`.

Expected output: `legacy key: legacy-test-key`. Remove the debug line afterwards (`git diff apps/flutter/lib/main.dart` must be empty), and delete the test item with `secret-tool clear application stash-player key stash-api-key`.

- [ ] **Step 7: macOS native handler**

`apps/flutter/macos/Runner/MainFlutterWindow.swift`: after `RegisterGeneratedPlugins(registry: flutterViewController)`, add:

```swift
    LegacySecretChannel.register(with: flutterViewController.engine.binaryMessenger)
```

Append this at the end of the file. It lives in this file rather than its own so the Xcode project needs no new file reference.

```swift
/// Handles `readApiKey` on `stash_player/legacy_secret`: the API key the
/// SwiftUI client stored (a generic password, service `stash-player`,
/// account `stash-api-key`, in the file-based login keychain), nil when
/// there is none, or a `lookup-failed` error. Same bundle ID and team as
/// that client, so the item's access list admits this app without a prompt.
enum LegacySecretChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "stash_player/legacy_secret",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "readApiKey" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "stash-player",
        kSecAttrAccount as String: "stash-api-key",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      switch status {
      case errSecSuccess:
        result((item as? Data).flatMap { String(data: $0, encoding: .utf8) })
      case errSecItemNotFound:
        result(nil)
      default:
        result(FlutterError(
          code: "lookup-failed",
          message: "SecItemCopyMatching returned \(status)",
          details: nil
        ))
      }
    }
  }
}
```

- [ ] **Step 8: Gate, commit, push**

```bash
just flutter-check
git add apps/flutter/lib/services/legacy_secret_reader.dart apps/flutter/test/services/legacy_secret_reader_test.dart apps/flutter/linux/runner apps/flutter/macos/Runner/MainFlutterWindow.swift
git commit -m "feat(flutter): read the legacy clients' stored API key"
git push origin flutter
```

Expected: the `Flutter` workflow's Linux and macOS builds both succeed (the Swift compiles).

---

### Task 9: One-time import wired into the connection store (TDD)

**Files:**
- Create: `apps/flutter/lib/services/legacy_connection_importer.dart`
- Create: `apps/flutter/test/services/legacy_connection_importer_test.dart`
- Modify: `apps/flutter/lib/services/platform_connection_store.dart`
- Modify: `apps/flutter/test/services/platform_connection_store_test.dart`

**Interfaces:**
- Consumes: `parseLegacyConfig`, `legacyConfigCandidates` (Task 7); `LegacySecretReader`, `MethodChannelLegacySecretReader` (Task 8); `ConnectionConfig` (`lib/domain/connection.dart`).
- Produces:
  - `class LegacyConnectionImporter { LegacyConnectionImporter({required List<String> configPaths, required LegacySecretReader secrets}); Future<ConnectionConfig?> importConnection(); }`
  - `const legacyImportAttemptedPreferenceKey = 'dev.arsfeld.stashplayer.flutter.legacy_import_attempted';`
  - `PlatformConnectionStore({required SharedPreferencesAsync preferences, required FlutterSecureStorage secureStorage, LegacyConnectionImporter? legacyImporter})`

- [ ] **Step 1: Write the failing importer tests**

`apps/flutter/test/services/legacy_connection_importer_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stash_player_flutter/domain/connection.dart';
import 'package:stash_player_flutter/services/legacy_connection_importer.dart';
import 'package:stash_player_flutter/services/legacy_secret_reader.dart';

class FakeLegacySecretReader implements LegacySecretReader {
  FakeLegacySecretReader([this.key]);

  final String? key;
  int reads = 0;

  @override
  Future<String?> readApiKey() async {
    reads++;
    return key;
  }
}

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('legacy-import'));
  tearDown(() => dir.delete(recursive: true));

  String writeConfig(String name, String contents) {
    final file = File(p.join(dir.path, name))..writeAsStringSync(contents);
    return file.path;
  }

  test('imports URL, key, and SOCKS proxy', () async {
    final path = writeConfig(
      'config.toml',
      'stash_url = "https://stash.lan"\nproxy_url = "socks5h://127.0.0.1:1055"\n',
    );
    final importer = LegacyConnectionImporter(
      configPaths: [path],
      secrets: FakeLegacySecretReader('legacy-key'),
    );

    expect(
      await importer.importConnection(),
      const ConnectionConfig(
        serverUrl: 'https://stash.lan',
        apiKey: 'legacy-key',
        socksProxy: '127.0.0.1:1055',
      ),
    );
  });

  test('a missing key imports as empty (auth-less servers)', () async {
    final path = writeConfig('config.toml', 'stash_url = "http://nas:9999"');
    final importer = LegacyConnectionImporter(
      configPaths: [path],
      secrets: FakeLegacySecretReader(),
    );

    expect(
      await importer.importConnection(),
      const ConnectionConfig(serverUrl: 'http://nas:9999'),
    );
  });

  test('skips missing and unusable candidates in order', () async {
    final unusable = writeConfig('bad.toml', 'stash_url = ""');
    final good = writeConfig('good.toml', 'stash_url = "http://second"');
    final importer = LegacyConnectionImporter(
      configPaths: [p.join(dir.path, 'absent.toml'), unusable, good],
      secrets: FakeLegacySecretReader(),
    );

    expect((await importer.importConnection())?.serverUrl, 'http://second');
  });

  test('no config means no import, and the keyring is never touched', () async {
    final secrets = FakeLegacySecretReader('legacy-key');
    final importer = LegacyConnectionImporter(
      configPaths: [p.join(dir.path, 'absent.toml')],
      secrets: secrets,
    );

    expect(await importer.importConnection(), isNull);
    expect(secrets.reads, 0);
  });
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `nix develop .#flutter --command bash -c 'cd apps/flutter && flutter test test/services/legacy_connection_importer_test.dart'`
Expected: FAIL (the import doesn't exist).

- [ ] **Step 3: Implement the importer**

`apps/flutter/lib/services/legacy_connection_importer.dart`:

```dart
import 'dart:io';

import '../domain/connection.dart';
import 'legacy_config.dart';
import 'legacy_secret_reader.dart';

/// Rebuilds the connection a legacy (GTK / SwiftUI) Stash Player saved, so
/// a user upgraded into this client lands in their library rather than on
/// an empty connection screen. Only reads; the legacy data is left in
/// place so rolling back still works.
class LegacyConnectionImporter {
  LegacyConnectionImporter({
    required List<String> configPaths,
    required LegacySecretReader secrets,
  }) : _configPaths = configPaths,
       _secrets = secrets;

  final List<String> _configPaths;
  final LegacySecretReader _secrets;

  /// The first usable legacy connection, or null when there is none.
  /// Errors from the keyring propagate; the caller decides what a failed
  /// import means.
  Future<ConnectionConfig?> importConnection() async {
    for (final path in _configPaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      final legacy = parseLegacyConfig(await file.readAsString());
      if (legacy == null) continue;
      return ConnectionConfig(
        serverUrl: legacy.serverUrl,
        apiKey: await _secrets.readApiKey() ?? '',
        socksProxy: legacy.socksProxy,
      );
    }
    return null;
  }
}
```

- [ ] **Step 4: Run the importer tests**

Run: `nix develop .#flutter --command bash -c 'cd apps/flutter && flutter test test/services/legacy_connection_importer_test.dart'`
Expected: 4 tests PASS.

- [ ] **Step 5: Write the failing store tests**

Append these to `main()` in `apps/flutter/test/services/platform_connection_store_test.dart`. Add these imports at the top: `dart:io`, `package:path/path.dart as p`, `package:flutter/services.dart`, `package:stash_player_flutter/services/legacy_connection_importer.dart`, `package:stash_player_flutter/services/legacy_secret_reader.dart`.

```dart
  group('legacy import', () {
    late Directory dir;
    late String legacyConfigPath;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('legacy-store');
      legacyConfigPath = p.join(dir.path, 'config.toml');
      File(legacyConfigPath).writeAsStringSync(
        'stash_url = "https://legacy.lan"\nproxy_url = "socks5h://127.0.0.1:1055"\n',
      );
    });
    tearDown(() => dir.delete(recursive: true));

    PlatformConnectionStore buildImportingStore(LegacySecretReader secrets) =>
        PlatformConnectionStore(
          preferences: SharedPreferencesAsync(),
          secureStorage: const FlutterSecureStorage(),
          legacyImporter: LegacyConnectionImporter(
            configPaths: [legacyConfigPath],
            secrets: secrets,
          ),
        );

    test('imports and persists the legacy connection when none is stored', () async {
      final store = buildImportingStore(_StubSecrets('legacy-key'));
      const expected = ConnectionConfig(
        serverUrl: 'https://legacy.lan',
        apiKey: 'legacy-key',
        socksProxy: '127.0.0.1:1055',
      );

      expect(await store.load(const {}), expected);
      // Persisted: a store without an importer now sees it too.
      expect(await buildStore().load(const {}), expected);
    });

    test('never imports over an existing connection', () async {
      await buildStore().save(const ConnectionConfig(serverUrl: 'https://mine'));

      final loaded = await buildImportingStore(_StubSecrets('legacy-key')).load(const {});

      expect(loaded.serverUrl, 'https://mine');
    });

    test('runs at most once, even when the user later clears the URL', () async {
      final store = buildImportingStore(_StubSecrets('legacy-key'));
      await store.load(const {});
      await store.save(const ConnectionConfig());

      expect((await store.load(const {})).serverUrl, '');
    });

    test('a failed import falls through to an empty connection, once', () async {
      final failing = _StubSecrets.failing();
      final store = buildImportingStore(failing);

      expect((await store.load(const {})).serverUrl, '');
      expect((await store.load(const {})).serverUrl, '');
      expect(failing.reads, 1);
    });

    test('environment overrides still win over an imported connection', () async {
      final store = buildImportingStore(_StubSecrets('legacy-key'));

      final loaded = await store.load(const {'STASH_URL': 'http://env'});

      expect(loaded.serverUrl, 'http://env');
      expect(loaded.apiKey, 'legacy-key');
    });
  });
```

And at the end of the file, outside `main()`:

```dart
class _StubSecrets implements LegacySecretReader {
  _StubSecrets(this._key) : _fail = false;
  _StubSecrets.failing() : _key = null, _fail = true;

  final String? _key;
  final bool _fail;
  int reads = 0;

  @override
  Future<String?> readApiKey() async {
    reads++;
    if (_fail) throw PlatformException(code: 'lookup-failed');
    return _key;
  }
}
```

- [ ] **Step 6: Run them to make sure they fail**

Run: `nix develop .#flutter --command bash -c 'cd apps/flutter && flutter test test/services/platform_connection_store_test.dart'`
Expected: FAIL, because there is no named parameter `legacyImporter`.

- [ ] **Step 7: Wire the importer into the store**

In `apps/flutter/lib/services/platform_connection_store.dart`, add these imports:

```dart
import 'dart:io';

import '../shared/diagnostics.dart';
import 'legacy_config.dart';
import 'legacy_connection_importer.dart';
import 'legacy_secret_reader.dart';
```

Add the key constant after `socksProxyPreferenceKey`:

```dart
/// Set once the one-time import from the legacy GTK / SwiftUI client has
/// been attempted, whatever its outcome, so a user who later clears their
/// connection doesn't get the legacy one back.
const legacyImportAttemptedPreferenceKey =
    'dev.arsfeld.stashplayer.flutter.legacy_import_attempted';
```

Replace the constructor, `create()`, and `loadStored()`:

```dart
class PlatformConnectionStore implements ConnectionStore {
  PlatformConnectionStore({
    required SharedPreferencesAsync preferences,
    required FlutterSecureStorage secureStorage,
    LegacyConnectionImporter? legacyImporter,
  }) : _preferences = preferences,
       _secureStorage = secureStorage,
       _legacyImporter = legacyImporter;

  final SharedPreferencesAsync _preferences;
  final FlutterSecureStorage _secureStorage;
  final LegacyConnectionImporter? _legacyImporter;

  static Future<PlatformConnectionStore> create() async =>
      PlatformConnectionStore(
        preferences: SharedPreferencesAsync(),
        // The file-based login keychain rather than the data-protection
        // one (the plugin's default): the latter needs a
        // keychain-access-groups entitlement tied to a provisioning
        // profile, which a Developer ID build doesn't have.
        secureStorage: const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        ),
        // The legacy clients only ever shipped on Linux and macOS.
        legacyImporter: Platform.isLinux || Platform.isMacOS
            ? LegacyConnectionImporter(
                configPaths: legacyConfigCandidates(
                  isMacOS: Platform.isMacOS,
                  environment: Platform.environment,
                ),
                secrets: const MethodChannelLegacySecretReader(),
              )
            : null,
      );

  @override
  Future<ConnectionConfig> load(Map<String, String> environment) =>
      loadEffective(environment);

  Future<ConnectionConfig> loadStored() async {
    final stored = await _readStored();
    if (stored.serverUrl.isNotEmpty) return stored;
    return await _importLegacy() ?? stored;
  }

  Future<ConnectionConfig> _readStored() async {
    final values = await Future.wait<Object?>([
      _preferences.getString(serverUrlPreferenceKey),
      _secureStorage.read(key: apiKeySecureStorageKey),
      _preferences.getString(socksProxyPreferenceKey),
    ]);
    return ConnectionConfig(
      serverUrl: values[0] as String? ?? '',
      apiKey: values[1] as String? ?? '',
      socksProxy: values[2] as String? ?? '',
    );
  }

  /// The one-time import described at [legacyImportAttemptedPreferenceKey].
  /// Never throws: any failure leaves the user on the connection screen,
  /// exactly as if there had been nothing to import.
  Future<ConnectionConfig?> _importLegacy() async {
    final importer = _legacyImporter;
    if (importer == null) return null;
    if (await _preferences.getBool(legacyImportAttemptedPreferenceKey) ?? false) {
      return null;
    }
    await _preferences.setBool(legacyImportAttemptedPreferenceKey, true);
    try {
      final imported = await importer.importConnection();
      if (imported != null) {
        await save(imported);
        logDiagnostic('connection', 'Imported the legacy client connection');
      }
      return imported;
    } on Object catch (error) {
      logDiagnostic('connection', 'Legacy connection import failed: $error');
      return null;
    }
  }
```

`loadEffective` and `save` stay as they are.

- [ ] **Step 8: Run all service tests, then the full gate**

```bash
nix develop .#flutter --command bash -c 'cd apps/flutter && flutter test test/services/'
just flutter-check
```

Expected: all PASS, including the two pre-existing store tests. The pre-existing tests use `buildStore()` without an importer, so they're unaffected.

- [ ] **Step 9: End-to-end check on Linux**

```bash
mkdir -p ~/.config/stash-player
printf 'stash_url = "http://127.0.0.1:9999"\n' > ~/.config/stash-player/config.toml
rm -f ~/.local/share/dev.arsfeld.stash-player/shared_preferences.json   # fresh Flutter-side state
just mock &
just flutter-build
nix develop .#flutter --command apps/flutter/build/linux/x64/debug/bundle/stash-player
```

Launch the binary directly, not through `just flutter-launch`, which injects `STASH_URL`. If `~/.config/stash-player/config.toml` already exists from a real legacy install, back it up first and restore it afterwards.

Expected: the app opens straight into the mock's library, and the console shows `[connection …] Imported the legacy client connection`. Relaunch and confirm the line does not appear again. Stop the mock and remove the test config.

- [ ] **Step 10: Commit**

```bash
git add apps/flutter/lib/services apps/flutter/test/services
git commit -m "feat(flutter): import the legacy client's connection once on first launch"
```

---

### Task 10: CI triggers and legacy scope

**Files:**
- Modify: `.github/workflows/flutter.yml`
- Modify: `.github/workflows/tests.yml`

- [ ] **Step 1: Narrow `tests.yml` to the frozen Rust crates**

Replace its `on:` block:

```yaml
# The Rust crates back the legacy GTK / SwiftUI clients, which are frozen
# (kept building and linted, no longer released). Only run when they or
# the workspace manifests change.
on:
  push:
    branches: [main, master]
    paths:
      - "crates/**"
      - "Cargo.toml"
      - "Cargo.lock"
      - "clippy.toml"
      - ".github/workflows/tests.yml"
  pull_request:
    branches: [main, master]
    paths:
      - "crates/**"
      - "Cargo.toml"
      - "Cargo.lock"
      - "clippy.toml"
      - ".github/workflows/tests.yml"
  workflow_dispatch:
```

- [ ] **Step 2: Retire the `flutter` branch trigger**

In `.github/workflows/flutter.yml`, change `branches: [main, master, flutter]` to `branches: [main, master]`. Delete the comment above it about the `flutter` branch getting three-platform CI.

- [ ] **Step 3: macOS smoke step, only if it now passes**

Check the most recent `Flutter` run on the PR:

```bash
gh run view "$(gh run list --branch flutter --workflow Flutter --limit 1 --json databaseId -q '.[0].databaseId')" --json jobs \
  -q '.jobs[] | select(.name=="Flutter macOS") | .steps[] | select(.name|startswith("Connection/library smoke")) | .conclusion'
```

If it prints `success`, delete `continue-on-error: true` from the macOS job's smoke step. Replace that step's "KNOWN NOT GREEN" comment paragraph with:

```yaml
      # Mock-only — see the Linux job's own step (above) for what "smoke"
      # means here. Green on a stock runner since the app dropped the App
      # Sandbox and moved to the file-based login keychain.
```

If it prints `failure`, leave the step as it is. It's out of scope.

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/flutter.yml .github/workflows/tests.yml
git commit -m "ci: scope Rust CI to the frozen crates and retire the flutter branch trigger"
git push origin flutter
```

Expected: the PR's checks show `Flutter`, `Flatpak`, and `macOS` green. `Tests` runs only if this PR touches `crates/` (it does, via the Task 0 merge), and is green.

---

### Task 11: Docs, AppStream, and dev recipes

**Files:**
- Modify: `README.md`, `apps/flutter/README.md`, `CLAUDE.md`, `PLAN.md`
- Modify: `data/dev.arsfeld.stash-player.metainfo.xml`
- Add: `docs/screenshots/flutter-library.png` (captured in Step 1)

- [ ] **Step 1: AppStream metainfo**

In `data/dev.arsfeld.stash-player.metainfo.xml`:
- `<summary>`: `Desktop client for the Stash media server`.
- Replace the `<description>` with:

```xml
  <description>
    <p>
      Stash Player is a desktop client for the Stash media server. Browse
      and filter your library, then play scenes locally with
      hardware-accelerated video.
    </p>
    <p>Features:</p>
    <ul>
      <li>Library grid with search, sorting, rating and tracking filters</li>
      <li>Local playback via libmpv with VA-API where available</li>
      <li>Resume position, play count, rating and O-counter synced back to Stash</li>
      <li>Optional SOCKS proxy for servers reachable only over a tailnet</li>
    </ul>
  </description>
```

- Add a screenshot. Capture the Flutter library window running against `just stash-up` and save it as `docs/screenshots/flutter-library.png`. Then add:

```xml
  <screenshots>
    <screenshot type="default">
      <image>https://raw.githubusercontent.com/arsfeld/stash-player/main/docs/screenshots/flutter-library.png</image>
      <caption>Library</caption>
    </screenshot>
  </screenshots>
```

  If a `<screenshots>` element already exists, replace it.

- Prepend to `<releases>`, using the real tag date when tagging:

```xml
    <release version="1.0.0" date="2026-10-01">
      <description>
        <p>
          Stash Player has a new, rebuilt client. Your saved server
          connection is imported automatically on first launch.
        </p>
      </description>
    </release>
```

Validate:

```bash
flatpak run --command=appstreamcli org.gnome.Sdk//50 validate --no-net data/dev.arsfeld.stash-player.metainfo.xml
```

Expected: `Validation was successful` (pedantic hints are OK).

- [ ] **Step 2: Root README**

Restructure `README.md`:
1. The intro describes Stash Player as the Flutter desktop app for Linux and macOS.
2. "Install" section:
   - Linux: download `stash-player.flatpak` from the latest GitHub release, then `flatpak install --user stash-player.flatpak`.
   - macOS: download `StashPlayer-macos-arm64.zip`, unzip, and move to /Applications. It's notarized and updates itself through "Check for Updates…".
3. "Development" points to `apps/flutter/README.md` and the `just flutter-*` recipes.
4. Keep the existing "Local development backend" section.
5. New closing section "Legacy clients (frozen, not released)": one paragraph saying `crates/stash-player-ui` (GTK) and `apps/macos` (SwiftUI) remain buildable but no longer ship. Move their existing build/run instructions under it, shortened to the commands.

- [ ] **Step 3: `apps/flutter/README.md`**

- Replace the "experimental" intro with: "The Stash Player desktop app for Linux and macOS. Released as a Flatpak and a notarized macOS app from `v1.0.0` on."
- In the identifiers table, update the application-id row to `dev.arsfeld.stash-player` and the display-name row to `Stash Player`. Add a row: `Legacy import flag (shared_preferences) | dev.arsfeld.stashplayer.flutter.legacy_import_attempted`.
- Add a "Releasing" section:
  - Tag `vX.Y.Z` on `main`.
  - `flatpak.yml` attaches `stash-player.flatpak`.
  - `macos.yml` builds, signs, notarizes, attaches `StashPlayer-macos-arm64.zip`, and publishes the Sparkle appcast.
  - Bump the Flutter pin in `flutter.yml`, `macos.yml`, and the Flatpak manifest together.
- Add an "Upgrading from the legacy clients" section. It describes the one-time import (what is read and from where, per the spec's table), and that the legacy data is never modified.

- [ ] **Step 4: `CLAUDE.md`**

- **Intro and "Build & run":** lead with the Flutter app (`nix develop .#flutter`, `just flutter-run`, `just flutter-check`, `nix run .#flatpak`).
- **"Architecture":** add a Flutter section first, covering:
  - `lib/app` (controller, router, providers)
  - `lib/domain`
  - `lib/features/{connection,library,player}`
  - `lib/services` (`http_stash_api`, `platform_connection_store` + legacy import, `socks_forward_proxy`, `media_kit_playback_engine`, thumbnails)
  - the native runners (the legacy-secret channel, Sparkle in `AppDelegate`)
  - the Flatpak manifest's libmpv stack
- **Legacy:** move the existing `stash-api` / `stash-player-core` / `stash-player-ui` / `stash-player-ffi` / macOS app sections under a "Legacy clients (frozen)" heading, and trim them. Keep the lint rules (CI still enforces clippy on `crates/`).
- **"Tests":** list `just flutter-check` first, then the Rust commands.
- **"Flatpak notes":** update to the new manifest (llvm21 extension, from-source libass/libplacebo/libmpv, network during build, codecs-extra).

- [ ] **Step 5: `PLAN.md`**

Insert at the very top:

```markdown
> **Legacy document.** This plan describes the GTK4/relm4 client in
> `crates/stash-player-ui`, which is frozen and no longer released. The
> shipped app is the Flutter client in `apps/flutter/` — see
> `docs/superpowers/specs/2026-09-23-flutter-first-class-release-design.md`.
```

- [ ] **Step 6: Commit**

```bash
git add README.md apps/flutter/README.md CLAUDE.md PLAN.md data/dev.arsfeld.stash-player.metainfo.xml
git add -f docs/screenshots/flutter-library.png
git commit -m "docs: present the Flutter client as Stash Player and mark the legacy clients frozen"
git push origin flutter
```

---

### Task 12: Release gates, merge, tag

This task is manual and needs a Mac plus a Linux desktop. Do not tag until steps 1–3 pass.

- [ ] **Step 1: macOS upgrade gate (SwiftUI 0.5.0 → Flutter RC through Sparkle)**

1. On the Mac, install `StashPlayer-macos-arm64.zip` from the `v0.5.0` GitHub release. Launch it, connect to a real Stash, then quit.
2. Build a notarized RC stamped `1.0.0`. Push a throwaway tag `v1.0.0-rc.1`. The `appcast` job skips hyphenated tags, so production users are unaffected.
   - The `Verify Info.plist` step expects the version to equal the tag minus `v`, so the RC bundle reports `1.0.0-rc.1`.
   - Sparkle orders `1.0.0-rc.1` above `0.5.0`, which is enough for this gate.

   ```bash
   git tag v1.0.0-rc.1 && git push origin v1.0.0-rc.1
   gh run watch "$(gh run list --workflow macOS --limit 1 --json databaseId -q '.[0].databaseId')"
   ```

   Expected: notarized. The `release` job attaches the zip to a `v1.0.0-rc.1` GitHub release.
3. Generate a local appcast for it with Sparkle's `generate_appcast`. Use the maintainer's EdDSA key from the login Keychain, which `generate_appcast` reads by default.

   ```bash
   mkdir -p /tmp/rc-feed && cd /tmp/rc-feed
   gh release download v1.0.0-rc.1 --repo arsfeld/stash-player --pattern 'StashPlayer-macos-arm64.zip'
   <sparkle-2.9.2>/bin/generate_appcast --download-url-prefix http://127.0.0.1:8765/ .
   python3 -m http.server 8765 &
   defaults write dev.arsfeld.stash-player SUFeedURL http://127.0.0.1:8765/appcast.xml
   ```

4. Launch the 0.5.0 app and choose "Check for Updates…". Expected:
   - It offers 1.0.0-rc.1, installs it, and relaunches.
   - The relaunched app is the Flutter client: About shows "Stash Player", and the library UI is the Flutter one.
   - It opens straight into the library, because the connection was imported. macOS may show a single keychain access prompt; "Always Allow" is acceptable.
   - A scene plays.
   - "Check for Updates…" is in the app menu.
5. Clean up with `defaults delete dev.arsfeld.stash-player SUFeedURL`. Stop the server.
6. Delete the RC release and tag:

   ```bash
   gh release delete v1.0.0-rc.1 --yes --cleanup-tag
   ```

- [ ] **Step 2: Linux upgrade gate (GTK Flatpak 0.5.0 → Flutter Flatpak)**

1. Install the 0.5.0 bundle:

   ```bash
   gh release download v0.5.0 --pattern stash-player.flatpak --dir /tmp/v050
   flatpak install --user -y --bundle /tmp/v050/stash-player.flatpak
   ```

   Launch it, connect to a real Stash (the key goes to the keyring), then quit.
2. Install the RC bundle from the PR's latest `Flatpak` run artifact over it:

   ```bash
   flatpak install --user -y --bundle <rc>/stash-player.flatpak
   ```

3. Run `flatpak run dev.arsfeld.stash-player`. Expected:
   - It opens straight into the library.
   - A scene plays.
   - Hardware decoding is active: `LIBVA_MESSAGING_LEVEL=2 flatpak run dev.arsfeld.stash-player` logs `vaInitialize` succeeding when a scene starts.

- [ ] **Step 3: Merge**

```bash
gh pr ready
gh pr checks --watch
gh pr merge --merge
```

Expected: all checks green, and the PR is merged with a merge commit.

- [ ] **Step 4: Tag v1.0.0**

Set the metainfo `1.0.0` release date to today in a commit on `main` first, if it differs. Then:

```bash
git checkout main && git pull
git tag v1.0.0 && git push origin v1.0.0
```

Expected:
- `Flatpak` attaches `stash-player.flatpak`.
- `macOS` attaches the notarized `StashPlayer-macos-arm64.zip`, and `appcast` publishes a gh-pages commit `appcast: v1.0.0`.
- Edit the GitHub release notes to explain the switch to the new client and the automatic connection import. The appcast's release-notes HTML is generated from this body, so edit it before the `appcast` job runs, or re-run that job afterwards.
