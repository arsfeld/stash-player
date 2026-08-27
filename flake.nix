{
  description = "stash-player — native desktop client for Stash (Linux + macOS)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      linuxSystems  = [ "x86_64-linux" "aarch64-linux" ];
      darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];
      allSystems    = linuxSystems ++ darwinSystems;

      forAllSystems = f: nixpkgs.lib.genAttrs allSystems (system: f system);
      forLinux      = f: nixpkgs.lib.genAttrs linuxSystems  (system: f system);
      forDarwin     = f: nixpkgs.lib.genAttrs darwinSystems (system: f system);

      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };

      rustFor = system:
        (pkgsFor system).rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" "clippy" "rustfmt" ];
        };

      # ------------------------------------------------------------------
      # Linux: existing GTK dev shell + Flatpak builder app.
      # ------------------------------------------------------------------

      manifest = "build-aux/dev.arsfeld.stash-player.yml";
      buildDir = "build-aux/build-dir";
      repoDir  = "build-aux/repo";

      flatpakBuildFor = system:
        let pkgs = pkgsFor system; in
        pkgs.writeShellApplication {
          name = "stash-player-flatpak";
          runtimeInputs = with pkgs; [ flatpak-builder appstream flatpak ];
          text = ''
            set -euo pipefail
            cd "$(git rev-parse --show-toplevel)"
            exec flatpak-builder \
              --user --install-deps-from=flathub \
              --force-clean --install \
              --repo=${repoDir} \
              "$@" \
              ${buildDir} ${manifest}
          '';
        };

      linuxDevShell = system:
        let
          pkgs = pkgsFor system;
          rustToolchain = rustFor system;
          # media_kit links libmpv dynamically. Nixpkgs' mpv.pc retains its
          # full static link closure in Requires.private, so give CMake a
          # dynamic-link metadata file rather than pulling every mpv build
          # dependency into the interactive shell.
          mpvPkgConfig = pkgs.writeTextDir "lib/pkgconfig/mpv.pc" ''
            Name: mpv
            Description: mpv media player client library
            Version: ${pkgs.mpv.version}
            Libs: -L${pkgs.mpv}/lib -lmpv
            Cflags: -I${pkgs.lib.getDev pkgs.mpv}/include
          '';
        in
        pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            rustToolchain
            pkg-config
            flutter
            cmake
            ninja
            clang
            flatpak-builder
            appstream
          ];

          buildInputs = with pkgs; [
            glib
            gtk4
            libadwaita
            graphene
            cairo
            pango
            gdk-pixbuf

            gst_all_1.gstreamer
            gst_all_1.gst-plugins-base
            gst_all_1.gst-plugins-good
            gst_all_1.gst-plugins-bad
            gst_all_1.gst-plugins-ugly
            gst_all_1.gst-libav
            gst_all_1.gst-plugins-rs

            openssl
            dbus
            libsecret
            libglvnd
            mpv
            mpvPkgConfig

            desktop-file-utils
            shared-mime-info
          ];

          shellHook = ''
            flutter --version
            export PKG_CONFIG_PATH="${mpvPkgConfig}/lib/pkgconfig:$PKG_CONFIG_PATH"
            export GST_PLUGIN_SYSTEM_PATH_1_0="${pkgs.lib.makeSearchPath "lib/gstreamer-1.0" [
              pkgs.gst_all_1.gstreamer.out
              pkgs.gst_all_1.gst-plugins-base
              pkgs.gst_all_1.gst-plugins-good
              pkgs.gst_all_1.gst-plugins-bad
              pkgs.gst_all_1.gst-plugins-ugly
              pkgs.gst_all_1.gst-libav
              pkgs.gst_all_1.gst-plugins-rs
            ]}"
            export XDG_DATA_DIRS="${pkgs.gtk4}/share:${pkgs.libadwaita}/share:${pkgs.shared-mime-info}/share:$XDG_DATA_DIRS"
          '';
        };

      # ------------------------------------------------------------------
      # macOS: SwiftUI app driven by stash-player-ffi.
      #
      # Xcode itself isn't in nixpkgs — `xcodebuild`, `xcrun`, `lipo`, and
      # `open` come from Xcode / Command Line Tools on the host. Nix
      # provides Rust + xcodegen; the user-PATH (preserved by
      # writeShellApplication) supplies the Apple toolchain.
      # ------------------------------------------------------------------

      darwinDevShell = system:
        let
          pkgs = pkgsFor system;
          rustToolchain = rustFor system;
        in
        pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            rustToolchain
            pkg-config
            flutter
            cmake
            ninja
            clang
            cocoapods
            xcodegen
          ];
          shellHook = ''
            flutter --version
            # Pin the Rust staticlib's deployment floor to match the Swift
            # target so the Apple linker doesn't warn on every object.
            export MACOSX_DEPLOYMENT_TARGET=14.0
          '';
        };

      macosBuildFor = system:
        let
          pkgs = pkgsFor system;
          rustToolchain = rustFor system;
        in
        pkgs.writeShellApplication {
          name = "stash-player-macos-build";
          runtimeInputs = [ rustToolchain pkgs.xcodegen ];
          text = ''
            set -euo pipefail
            cd "$(git rev-parse --show-toplevel)"
            export MACOSX_DEPLOYMENT_TARGET=14.0
            ./build-aux/build-macos-xcframework.sh
            ( cd apps/macos && xcodegen generate )
            echo
            echo "Open with: nix run .#macos    (or: open apps/macos/StashPlayer.xcodeproj)"
          '';
        };

      macosRunFor = system:
        let
          pkgs = pkgsFor system;
          rustToolchain = rustFor system;
        in
        pkgs.writeShellApplication {
          name = "stash-player-macos";
          runtimeInputs = [ rustToolchain pkgs.xcodegen ];
          text = ''
            set -euo pipefail
            cd "$(git rev-parse --show-toplevel)"
            export MACOSX_DEPLOYMENT_TARGET=14.0

            ./build-aux/build-macos-xcframework.sh
            ( cd apps/macos && xcodegen generate )

            DERIVED="$PWD/build-aux/macos-derived"
            # xcodebuild must not see nixpkgs' clang-wrapper on PATH —
            # its `ld` shadows Xcode's and chokes on `-Xlinker` flags
            # the swift driver passes. Run with a clean Apple-only PATH.
            APPLE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
            env -i HOME="$HOME" \
                  PATH="$APPLE_PATH" \
                  DEVELOPER_DIR="''${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
                  MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
              xcodebuild \
                -project apps/macos/StashPlayer.xcodeproj \
                -scheme StashPlayer \
                -configuration Debug \
                -derivedDataPath "$DERIVED" \
                build >/dev/null

            APP="$DERIVED/Build/Products/Debug/StashPlayer.app"
            echo "Launching $APP"
            open -a "$APP"
          '';
        };
    in
    {
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in
        if pkgs.stdenv.isDarwin
        then { default = darwinDevShell system; }
        else { default = linuxDevShell  system; }
      );

      apps =
        (forLinux (system: {
          flatpak = {
            type = "app";
            program = "${flatpakBuildFor system}/bin/stash-player-flatpak";
          };
        }))
        //
        (forDarwin (system: {
          # `nix run .#macos` — full build-and-launch loop.
          macos = {
            type = "app";
            program = "${macosRunFor system}/bin/stash-player-macos";
          };
          # `nix run .#macos-build` — rebuild xcframework + regenerate xcodeproj.
          macos-build = {
            type = "app";
            program = "${macosBuildFor system}/bin/stash-player-macos-build";
          };
        }));

      packages =
        (forLinux (system: {
          flatpak-build = flatpakBuildFor system;
        }))
        //
        (forDarwin (system: {
          macos-build = macosBuildFor system;
          macos-run   = macosRunFor   system;
        }));
    };
}
