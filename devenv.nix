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

  # Isolate Stash's state under .devenv/state/stash/.
  #
  # Stash 0.29 has several leak vectors that fight isolation:
  #   - It ignores $HOME on macOS (resolves home via user.Current() /
  #     passwd lookup), so HOME-redirect doesn't contain it.
  #   - `--config` silently falls back to ~/.stash/config.yml when the
  #     file doesn't exist yet.
  #   - The `setup()` GraphQL mutation -- the recommended first-run
  #     entry point -- writes config + DB to the *default* ~/.stash/
  #     location even when --config points elsewhere, leaving split
  #     state across two directories.
  #
  # Workaround: pre-bake the full config.yml with the library path
  # already populated. Stash sees a complete config on first boot, the
  # migration runs against the configured DB path, and setup() never
  # needs to run -- so the home-dir leak vector never triggers.
  #
  # Reset = `rm -rf .devenv/state/stash`. Nothing lands in ~/.stash/.
  processes.stash.exec = ''
    set -euo pipefail
    STATE="$DEVENV_STATE/stash"
    LIBRARY="$DEVENV_ROOT/tools/dev-stash/media"
    mkdir -p "$STATE"/{generated,cache,blobs} "$LIBRARY"
    if [ ! -f "$STATE/config.yml" ]; then
      cat > "$STATE/config.yml" <<EOF
host: 127.0.0.1
port: 9999
nobrowser: true
database: $STATE/stash-go.sqlite
generated: $STATE/generated
cache: $STATE/cache
blobs_path: $STATE/blobs
blobs_storage: FILESYSTEM
stash:
  - path: $LIBRARY
    excludeVideo: false
    excludeImage: true
EOF
    fi
    exec stash --config "$STATE/config.yml"
  '';
}
