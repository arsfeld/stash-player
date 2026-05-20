# Native dev backend for stash-player.
#
# Boots a real `stash` binary on http://127.0.0.1:9999 with its state
# dirs under .devenv/state/stash/ and its library pointed at
# `tools/dev-stash/media/` (the same gitignored dir compose.yml
# bind-mounts). Pair with `tools/dev-stash/populate.sh` exactly like
# the compose path.
#
# This is the peer to `compose.yml` for macOS / Linux contributors who
# already use Nix and prefer a native binary over Docker. The compose
# path stays for everyone else.
#
# Quickstart:
#   devenv up                              # boots stash on :9999
#   # in another shell, with devenv active:
#   tools/dev-stash/populate.sh            # downloads clips + scans
#   STASH_URL=http://127.0.0.1:9999 cargo run -p stash-player-ui
#
# Reset: stop `devenv up`, then `rm -rf .devenv/state/stash`. Clips in
# tools/dev-stash/media/ survive (gitignored, host-visible).
{ pkgs, lib, config, ... }:

{
  packages = [
    pkgs.stash
    pkgs.ffmpeg
    pkgs.jq
    pkgs.curl
  ];

  # populate.sh reads this to pick the library path for Stash's
  # first-run setup mutation. compose.yml's bind mount lands on /data;
  # here we point at the host directory directly.
  env.DEV_STASH_LIBRARY = "${config.env.DEVENV_ROOT}/tools/dev-stash/media";

  enterShell = ''
    mkdir -p "$DEVENV_ROOT/tools/dev-stash/media"
  '';

  # Run stash with all state under .devenv/state/stash/ so `rm -rf`
  # gives a clean reset and the host's ~/.stash dir stays untouched.
  # STASH_GENERATED / STASH_METADATA / STASH_CACHE / STASH_BLOBS steer
  # Stash's generated content; --config pins the config file path so
  # first-run setup() lands inside the devenv state dir.
  processes.stash.exec = ''
    set -euo pipefail
    STATE="$DEVENV_STATE/stash"
    mkdir -p "$STATE"/{generated,metadata,cache,blobs}
    export STASH_GENERATED="$STATE/generated"
    export STASH_METADATA="$STATE/metadata"
    export STASH_CACHE="$STATE/cache"
    export STASH_BLOBS="$STATE/blobs"
    exec stash \
      --nobrowser \
      --host 127.0.0.1 \
      --port 9999 \
      --config "$STATE/config.yml"
  '';
}
