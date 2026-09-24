# Flutter as the primary, released client — design

**Date:** 2026-09-23
**Branch:** `flutter` → merged into `main`
**First release:** `v1.0.0`

## Goal

Make the Flutter app (`apps/flutter/`) the one released Stash Player on
Linux and macOS: a Flatpak bundle and a Developer ID–signed, notarized,
Sparkle-updating macOS app. It takes over the existing app identities and
update channel so current users are upgraded into it automatically. The
GTK (Rust) and SwiftUI clients stay in the repo, frozen and unreleased.

## Decisions

| Topic | Decision |
|---|---|
| Positioning | Flutter is primary; GTK and SwiftUI are frozen (kept in place, not released) |
| Identity | Take over `dev.arsfeld.stash-player` on both platforms, plus the Sparkle feed |
| Migration | One-time import of URL, API key, and SOCKS proxy from the legacy stores |
| Platforms | Linux Flatpak (x86_64) and macOS arm64. Windows stays CI-compile-only |
| Legacy CI | Rust tests + clippy kept; the SwiftUI app is no longer built |
| Feature parity | The current Flutter feature set is accepted; no parity audit gates the merge |

Out of scope: Flathub submission, Windows releases, universal (Intel)
macOS builds, and importing non-connection settings (volume, autoplay,
etc.).

## 1. Branch integration and identity

**Branch flow**

1. On `flutter`, merge `main` in first. Expected conflicts: `CLAUDE.md`,
   `README.md`, `PLAN.md`, `.gitignore`, `.github/workflows/{macos,tests}.yml`.
   `main`'s Rust/Swift proxy work doesn't touch `apps/flutter/`.
2. Do all the work below on `flutter`, with CI green at each step.
3. Open a PR from `flutter` to `main` and merge it with a merge commit, so
   the branch history survives.
4. Tag `v1.0.0` after the manual gates in §6 pass.

**Identity**

- **Linux** (`apps/flutter/linux/CMakeLists.txt`): `APPLICATION_ID =
  dev.arsfeld.stash-player` and `BINARY_NAME = stash-player`, so the
  Wayland app-id and the X11 WM class match the existing `.desktop` file.
  The window title is "Stash Player".
- **macOS** (`apps/flutter/macos/Runner/Configs/AppInfo.xcconfig`):
  `PRODUCT_BUNDLE_IDENTIFIER = dev.arsfeld.stash-player`. The bundle
  filename stays `StashPlayer.app`, the same as the SwiftUI app, so
  Sparkle's in-place replace, the appcast job, and the
  `StashPlayer-macos-arm64.zip` asset name don't change.
  `CFBundleName`/`CFBundleDisplayName` = "Stash Player". The Flutter
  default icon set is replaced with the existing app icon.
- **Shared assets:** the desktop file, icons, and metainfo in `data/` are
  reused. The metainfo gets a `1.0.0` `<release>` entry and Flutter
  screenshots.
- **Unchanged:** the `apps/flutter/` directory, the Dart package name
  `stash_player_flutter`, and the existing `dev.arsfeld.stashplayer.flutter.*`
  preference keys. None of these are user-visible. Every user-visible
  "Flutter" or "experimental" string goes.

## 2. Linux Flatpak

`media_kit_libs_linux` links libmpv when the Flutter app is built, so the
Flutter bundle must be built inside flatpak-builder's sandbox, after
libmpv.

**Manifest** (`build-aux/dev.arsfeld.stash-player.yml`, rewritten):

- **Runtime:** `org.gnome.Platform`/`Sdk` 50, plus the SDK's LLVM
  extension (Flutter's Linux build uses clang).
- **`codecs-extra`:** kept with the same mount point and the same reason:
  mpv links the runtime FFmpeg, and codecs-extra supplies the encumbered
  decoders.
- **Module `libmpv`:** mpv built with meson (`-Dlibmpv=true
  -Dcplayer=false`, lua and javascript disabled), plus the dependencies the
  runtime lacks. libplacebo is likely needed; check libass against the
  runtime. Every source is pinned by sha256.
- **Module `stash-player`:**
  - **Sources:** the Flutter SDK archive pinned by sha256 (same version as
    CI, 3.41.6), and `apps/flutter` as a `dir` source.
  - **Build options:** `--share=network` in `build-args` so `flutter pub
    get` can run. That's the same allowance the Rust build uses for cargo.
  - **Commands:** `flutter pub get`, then `flutter build linux --release`.
    Install the bundle to `/app/stash-player/` and symlink
    `/app/bin/stash-player` to it. Install the desktop file, metainfo,
    and icons from `data/` as today.
- **finish-args:** Wayland/fallback-X11, IPC, network, PulseAudio,
  `--device=dri`, and `org.freedesktop.secrets`, as before. The legacy
  `xdg-config/stash-player` permission becomes `:ro` (it's only read, for
  the import), and `xdg-cache/stash-player` is dropped.

**Tooling:** `.github/workflows/flatpak.yml` keeps the same container,
action, and `stash-player.flatpak` release asset. Its cache key moves to
`hashFiles('apps/flutter/pubspec.lock', 'build-aux/dev.arsfeld.stash-player.yml')`.
`nix run .#flatpak` keeps working unchanged.

**Risk and fallback:** flutter_tools makes assumptions about its SDK
checkout (git metadata, a writable cache) that sandboxed builds can break.
**The first implementation task is a spike** that proves this manifest
builds and that the installed Flatpak connects and plays a real video. If
the build can't be made reliable, the fallback is `flatpak-flutter`
offline sources, the Flathub path.

## 3. macOS: signed, notarized release with Sparkle

**App changes**

- **`Release.entitlements`:** drop `app-sandbox`, `network.client`, and
  `network.server`. The file stays explicit (and effectively empty)
  because notarization needs it, as today. Enable the hardened runtime.
  Add `com.apple.security.cs.disable-library-validation` only if the
  spike shows media_kit's dylibs fail to load under the hardened runtime
  even when signed with our team ID.
- **`DebugProfile.entitlements`:** keeps `allow-jit`. The sandbox is
  dropped here too, so debug and release behave the same.
- **Deployment target:** 14.0, matching the SwiftUI app. Release builds
  are arm64-only via `ARCHS=arm64` on the CI `xcodebuild` command line, as the SwiftUI build did.
- **Keychain mode:** `flutter_secure_storage` uses the file-based login
  keychain (`MacOsOptions(usesDataProtectionKeychain: false)`). The
  data-protection keychain it defaults to needs a `keychain-access-groups`
  entitlement that a Developer ID build without a provisioning profile
  doesn't have.
- **Sparkle 2** (added via the Podfile):
  - `AppDelegate` owns an `SPUStandardUpdaterController`.
  - `MainMenu.xib` gets a "Check for Updates…" app-menu item wired to
    `checkForUpdates:`.
  - Info.plist carries the existing values: `SUFeedURL =
    https://arsfeld.github.io/stash-player/appcast.xml`, `SUPublicEDKey =
    Fx+Cc8kj5pSdtx3i/E+AhMmLUgefc8EXD1CxFh2VO5A=`,
    `SUEnableAutomaticChecks = true`.
  - There is no Dart-side code and no settings toggle; Sparkle's own UI
    covers preferences.
- **Versioning:** `CFBundleShortVersionString` and `CFBundleVersion` are
  both the tag version (e.g. `1.0.0`). Sparkle compares `CFBundleVersion`,
  and the SwiftUI app shipped dotted versions there. Non-tag builds use
  `0.0.0`.

**`.github/workflows/macos.yml`, rewritten around Flutter:**

1. Install Flutter with `subosito/flutter-action`, pinned at 3.41.6.
2. `flutter pub get`, then `flutter build macos --config-only`.
3. Keep the existing signing-mode detection: Developer ID when
   `MACOS_CERTIFICATE` is present, otherwise ad-hoc (fork PRs), plus the
   certificate import.
4. `xcodebuild -workspace apps/flutter/macos/Runner.xcworkspace -scheme
   Runner -configuration Release` with the same manual-signing flags as
   today: identity, team, `--timestamp`, explicit entitlements,
   `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, and the version variables.
5. Keep the rest: the Info.plist version check (tag builds), zip with
   `ditto`, `notarytool submit --wait`, staple, re-zip, attach
   `StashPlayer-macos-arm64.zip` to the release.
6. The `appcast` job (gh-pages, EdDSA signing, last 10 releases) is
   unchanged except for any path that names the old build output.

**Bridge:** SwiftUI 0.5.0 sees 1.0.0 in the appcast, verifies the EdDSA
signature and the matching Developer ID team, and installs the Flutter
bundle over itself. After that, updates come from the Flutter app's
embedded Sparkle.

## 4. One-time connection import

**Imported:** the Stash URL, the API key, and the SOCKS proxy. Nothing
else.

**Legacy locations**

| | URL + proxy (`config.toml`: `stash_url`, `proxy_url`) | API key |
|---|---|---|
| Linux | `$XDG_CONFIG_HOME/stash-player/config.toml` (the Flatpak's per-app path), then the host's `~/.config/stash-player/config.toml`, which the manifest exposes read-only | Secret Service item, attributes `application=stash-player`, `key=stash-api-key` |
| macOS | `~/Library/Application Support/one.arsfeld.stash-player/config.toml` | Keychain generic password, service `stash-player`, account `stash-api-key` |

**Components** (in `apps/flutter/lib/services/`)

- **`LegacyConfigReader`:** resolves the platform path and parses it with
  the `toml` package. Returns `stash_url` and `proxy_url`. It strips the
  scheme from `proxy_url` (`socks5h://host:port` → `host:port`) to match
  the Flutter proxy setting. HTTP proxies and proxies with credentials map
  to no proxy, because the Flutter client can't honour them. A
  `stash_url` equal to the Rust `Config::default()` placeholder
  (`https://stash.example.com`) counts as no URL, as the Rust
  `has_custom_stash_url` does.
- **`LegacySecretReader`:** a Dart interface over the method channel
  `stash_player/legacy_secret`, method `readApiKey` → `String?`.
  - **Linux runner (C):** `secret_password_lookup_sync` with a schema
    over `application` and `key`, flagged `SECRET_SCHEMA_DONT_MATCH_NAME`
    because the Rust `secret-service` crate wrote the item without an
    `xdg:schema` attribute.
  - **macOS Runner (Swift):** `SecItemCopyMatching` on the service and
    account above. The bundle ID and team match, so the read is expected
    to be silent; at worst macOS shows a single access prompt.
- **`LegacyConnectionImporter`:** combines the two readers and returns a
  `ConnectionConfig?`. It returns null when no URL is found. The API key
  may be empty, since some servers have auth disabled.

**Flow**

- `PlatformConnectionStore.loadStored` calls the importer only when no
  URL is stored and the preference `legacy_import_attempted` is unset.
- The flag is set before the importer's result is used, so the import runs
  at most once, whatever the outcome.
- On success, the result is persisted through the normal `save()` path.
- A keyring failure costs only the key: it is logged, and the URL and
  proxy still import with an empty key, so the user lands on a
  connection that needs just the key re-entered.
- Any other exception (reading the config, persisting the result) is
  logged and swallowed, which leaves the user on the connection screen,
  as today.
- Environment overrides (`STASH_URL`/`STASH_API_KEY`) still win.
- Legacy data is never modified or deleted, so rolling back to 0.5.0
  keeps working.

**Tests** (unit, with fakes and temp-dir TOML fixtures):

- a full import
- a missing config file
- a missing key → empty key
- a keyring failure → URL and proxy with an empty key
- proxy scheme stripping
- malformed TOML → null
- the run-once flag, including after a failure
- an existing Flutter-side URL skips the import

The native channel code is covered by the manual gates in §6.

## 5. CI, legacy freeze, docs

- **`flutter.yml`:** keeps the format, analyze, and test gates on Linux
  and macOS, plus the Windows debug build. After the merge, its triggers
  drop the `flutter` branch. The macOS integration smoke step's
  `continue-on-error` comes out if dropping the sandbox makes it pass.
  That's opportunistic, not required.
- **`flatpak.yml` and `macos.yml`:** build only the Flutter app (§2, §3).
  PRs build it; only `v*` tags publish.
- **`tests.yml`:** keeps `cargo test` and `cargo clippy -D warnings`, with
  its path filter narrowed to `crates/**` and `Cargo.*`. CI no longer
  builds the SwiftUI app.
- **Legacy code:** `crates/` and `apps/macos/` stay in place. The flake's
  `.#macos`/`.#macos-build` apps stay, labelled legacy. No new features go
  into them.
- **Docs:**
  - The root `README.md` leads with the Flutter app and how to install it
    (the Flatpak bundle, or the notarized self-updating zip), followed by
    a short "Legacy clients (frozen, not released)" section.
  - `apps/flutter/README.md` drops the experimental framing and the
    "not a replacement" wording.
  - In `CLAUDE.md`, the Flutter architecture becomes the primary section;
    the Rust and Swift sections are condensed under "Legacy".
  - `PLAN.md` gets a header note that it describes the legacy GTK client.

## 6. Release gates for v1.0.0

1. The PR from `flutter` to `main` is green: `flutter.yml`, `flatpak.yml`,
   `macos.yml` (Developer ID signing and notarization succeed), and
   `tests.yml`.
2. Merge to `main`.
3. **macOS upgrade gate:**
   - Install SwiftUI 0.5.0 with a saved connection.
   - Point it at a locally served appcast containing a signed, notarized
     1.0.0 release candidate (via `defaults write
     dev.arsfeld.stash-player SUFeedURL …`).
   - Confirm it updates, relaunches as the Flutter app, imports the
     connection, plays a scene, and that "Check for Updates…" works.
4. **Linux upgrade gate:**
   - Install the 0.5.0 Flatpak with a saved connection.
   - Install the 1.0.0 release-candidate bundle over it.
   - Confirm it imports the connection and plays a scene with hardware
     decoding.
5. Tag `v1.0.0`. The release notes explain the switch to the new client
   and that saved connections are imported automatically.
