#!/usr/bin/env bash
# Writes the remote definition (stash-player.flatpakrepo) and the one-click
# install file (dev.arsfeld.stash-player.flatpakref) into OUT_DIR, embedding
# PUBKEY (a binary `gpg --export`) as GPGKey=.
# Usage: render-remote-files.sh PUBKEY OUT_DIR
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh disable=SC1091
source "$here/common.sh"

pubkey=$1
out=$2
key_b64=$(base64 <"$pubkey" | tr -d '\n')
mkdir -p "$out"

cat >"$out/$REMOTE_NAME.flatpakrepo" <<EOF
[Flatpak Repo]
Title=$REPO_TITLE
Url=$REPO_URL
Homepage=$HOMEPAGE
GPGKey=$key_b64
EOF

cat >"$out/$APP_ID.flatpakref" <<EOF
[Flatpak Ref]
Title=$REPO_TITLE
Name=$APP_ID
Branch=$BRANCH
Url=$REPO_URL
Homepage=$HOMEPAGE
IsRuntime=false
SuggestRemoteName=$REMOTE_NAME
RuntimeRepo=$RUNTIME_REPO
GPGKey=$key_b64
EOF
