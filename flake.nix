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
    in {
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          rustToolchain
          pkg-config
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
    };
}
