{
  description = "stash-player — native Linux desktop client for Stash";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };
      rustToolchain = pkgs.rust-bin.stable.latest.default.override {
        extensions = [ "rust-src" "rust-analyzer" "clippy" "rustfmt" ];
      };

      manifest = "build-aux/one.arsfeld.stash-player.yml";
      buildDir = "build-aux/build-dir";
      repoDir  = "build-aux/repo";

      # `nix run .#flatpak -- [extra flatpak-builder args]` performs a clean
      # build, exports to build-aux/repo, and installs into the user
      # installation. appstreamcli must be on PATH for the metainfo step.
      flatpakBuild = pkgs.writeShellApplication {
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
    in {
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          rustToolchain
          pkg-config
          # Flatpak packaging tools, so `flatpak-builder build-aux/...` works
          # straight from the dev shell. appstream provides appstreamcli, which
          # flatpak-builder shells out to during metainfo composition.
          flatpak-builder
          appstream
        ];

        buildInputs = with pkgs; [
          # GUI
          glib
          gtk4
          libadwaita
          graphene
          cairo
          pango
          gdk-pixbuf

          # Video pipeline (milestone 3)
          gst_all_1.gstreamer
          gst_all_1.gst-plugins-base
          gst_all_1.gst-plugins-good
          gst_all_1.gst-plugins-bad
          gst_all_1.gst-plugins-ugly
          gst_all_1.gst-libav
          # gtk4paintablesink lives in gst-plugins-rs
          gst_all_1.gst-plugins-rs

          # Networking + secrets
          openssl
          dbus
          libsecret

          # Helpful at runtime
          desktop-file-utils
          shared-mime-info
        ];

        shellHook = ''
          # gst_all_1.gstreamer is multi-output: its default attr is the bin
          # output (CLI tools, no lib/gstreamer-1.0/). Core plugins
          # (typefind, multiqueue, queue, tee, fakesink, ...) live in .out, so
          # we must reference it explicitly -- otherwise playbin3 fails to
          # construct with "gst_bin_add: GST_IS_ELEMENT failed".
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

      apps.${system}.flatpak = {
        type = "app";
        program = "${flatpakBuild}/bin/stash-player-flatpak";
      };

      packages.${system}.flatpak-build = flatpakBuild;
    };
}
